-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Auditoria con actor real + cache de geocodificacion
--  Ejecutar DESPUES de 03_puntos_preparacion.sql
-- ═══════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────
--  1. QUIEN HIZO CADA CAMBIO
-- ─────────────────────────────────────────────────────────────────────
-- Hasta ahora todos los eventos quedaban como "sistema", porque el trigger
-- leia current_setting('k24.actor'), que nadie seteaba. Resultado: la
-- auditoria no distingue si un pedido lo cancelo el panel o lo marco
-- entregado un repartidor — que es justo lo que hace falta saber cuando
-- un cliente reclama.
--
-- Solucion simple y a prueba de olvidos: una columna en el propio pedido.
-- La API la escribe en cada update y el trigger la lee. Si alguien toca
-- la tabla desde el SQL Editor sin setearla, queda "sql-directo", que
-- tambien es informacion util.

alter table pedidos add column if not exists ultimo_actor text;

create or replace function registrar_evento_pedido()
returns trigger language plpgsql as $$
declare
  v_actor text;
begin
  if tg_op = 'INSERT' then
    insert into pedido_eventos (pedido_id, estado_de, estado_a, actor)
    values (new.id, null, new.estado, coalesce(new.ultimo_actor, 'cliente'));

  elsif new.estado is distinct from old.estado then
    -- Prioridad: lo que mando la API > la variable de sesion > sql directo
    v_actor := coalesce(
      nullif(new.ultimo_actor, ''),
      nullif(current_setting('k24.actor', true), ''),
      'sql-directo'
    );

    insert into pedido_eventos (pedido_id, estado_de, estado_a, actor, nota)
    values (new.id, old.estado, new.estado, v_actor,
            case when new.estado = 'cancelado' then new.cancelado_motivo else null end);
  end if;
  return new;
end $$;

comment on column pedidos.ultimo_actor is
  'Quien hizo el ultimo cambio: panel | repartidor:<uuid> | cliente | sistema. Lo escribe la API.';


-- ─────────────────────────────────────────────────────────────────────
--  2. CACHE DE GEOCODIFICACION
-- ─────────────────────────────────────────────────────────────────────
-- Muchos clientes escriben la direccion a mano y no comparten ubicacion,
-- asi que el pedido queda sin lat/lng y no se puede calcular cercania.
-- El servidor las convierte con OpenStreetMap (Nominatim), que es gratis
-- pero pide no abusar: maximo una consulta por segundo.
--
-- Esta tabla evita repetir consultas. Las direcciones se repiten mucho
-- (clientes que vuelven a comprar, calles frecuentes), asi que la mayoria
-- de los pedidos van a resolverse sin salir a internet.

create table if not exists geocodificaciones (
  direccion_norm text primary key,          -- direccion normalizada, en minuscula
  direccion_orig text not null,
  lat            double precision,
  lng            double precision,
  encontrada     boolean not null default false,
  fuente         text default 'nominatim',
  consultas      integer not null default 1,
  creado_at      timestamptz not null default now(),
  ultima_at      timestamptz not null default now()
);

comment on table geocodificaciones is
  'Cache de direccion -> coordenadas. Las no encontradas tambien se guardan, para no volver a preguntar lo mismo.';

create index if not exists idx_geo_encontradas on geocodificaciones(encontrada) where encontrada;

alter table geocodificaciones enable row level security;
revoke all on geocodificaciones from anon, authenticated;

-- Normalizador: misma direccion escrita distinto debe dar la misma clave.
-- "Av. Colon 1234 " y "AV COLON 1234" tienen que compartir cache.
create or replace function normalizar_direccion(p_dir text)
returns text language sql immutable as $$
  select regexp_replace(
           regexp_replace(lower(trim(coalesce(p_dir,''))), '[.,;]', '', 'g'),
           '\s+', ' ', 'g');
$$;

-- Busca en cache. Devuelve null si nunca se consulto.
create or replace function geo_buscar(p_dir text)
returns table (lat double precision, lng double precision, encontrada boolean)
language plpgsql as $$
declare v_key text;
begin
  v_key := normalizar_direccion(p_dir);
  update geocodificaciones
     set consultas = consultas + 1, ultima_at = now()
   where direccion_norm = v_key;
  return query
    select g.lat, g.lng, g.encontrada
      from geocodificaciones g
     where g.direccion_norm = v_key;
end $$;

-- Guarda el resultado (encontrado o no).
create or replace function geo_guardar(
  p_dir text, p_lat double precision, p_lng double precision
) returns void language plpgsql as $$
begin
  insert into geocodificaciones (direccion_norm, direccion_orig, lat, lng, encontrada)
  values (normalizar_direccion(p_dir), p_dir, p_lat, p_lng, p_lat is not null)
  on conflict (direccion_norm) do update
    set lat = excluded.lat,
        lng = excluded.lng,
        encontrada = excluded.encontrada,
        ultima_at = now();
end $$;

revoke all on function geo_buscar(text), geo_guardar(text, double precision, double precision),
                      normalizar_direccion(text)
  from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  3. Pedidos sin coordenadas — para verlos de un vistazo
-- ─────────────────────────────────────────────────────────────────────
-- Si esta vista crece, la asignacion automatica va a fallar seguido.
create or replace view v_pedidos_sin_ubicar
with (security_invoker = true) as
select codigo, estado, direccion, direccion_notas, creado_at
  from pedidos
 where (lat is null or lng is null)
   and estado not in ('entregado','cancelado')
 order by creado_at;

revoke all on v_pedidos_sin_ubicar from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
--  4. La cola del panel ahora muestra el punto de preparacion
-- ─────────────────────────────────────────────────────────────────────
-- OJO: va DROP y no CREATE OR REPLACE. Postgres solo deja agregar columnas
-- al final de una vista existente; como aca se insertan en el medio, hay
-- que recrearla. Es seguro: nada depende de esta vista, la API la consulta
-- directamente.
drop view if exists v_cola_despacho;

create view v_cola_despacho
with (security_invoker = true) as
select
  p.id, p.codigo, p.estado, p.cliente_nombre, p.cliente_telefono,
  p.direccion, p.direccion_notas, p.lat, p.lng,
  p.items, p.subtotal, p.envio, p.total, p.metodo_pago, p.pagado,
  p.repartidor_id, r.nombre as repartidor_nombre,
  p.punto_id, pp.nombre as punto_nombre, pp.tipo as punto_tipo,
  pp.direccion as punto_direccion, pp.telefono as punto_telefono,
  (p.lat is null or p.lng is null) as sin_ubicar,
  p.creado_at, p.asignado_at, p.retirado_at,
  extract(epoch from (now() - p.creado_at))::int as segundos_desde_creado
from pedidos p
left join repartidores r        on r.id  = p.repartidor_id
left join puntos_preparacion pp on pp.id = p.punto_id
where p.estado not in ('entregado','cancelado')
order by p.creado_at asc;

revoke all on v_cola_despacho from anon, authenticated;

-- Cuanto sirve el cache:
--   select count(*) as direcciones,
--          count(*) filter (where encontrada) as resueltas,
--          sum(consultas) as consultas_totales,
--          sum(consultas) - count(*) as llamadas_ahorradas
--     from geocodificaciones;
