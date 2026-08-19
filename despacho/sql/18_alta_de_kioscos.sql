-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Un kiosco se da de alta solo
--  Ejecutar DESPUES de 17_codigos_de_barra.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  LA TENSION QUE RESUELVE
--  "Que se registren solos, sin que yo los habilite" y "acceso libre a
--  aprobar" son cosas opuestas si la aprobacion la hace una persona.
--
--  La salida es que la puerta no la abra nadie a mano: que la abra el
--  kiosco completando lo suyo. Se registra y entra al instante; empieza
--  a recibir pedidos cuando tiene lo minimo para poder cumplirlos.
--
--  QUE ES "LO MINIMO"
--    · direccion que se pudo ubicar en el mapa
--        sin coordenadas la asignacion por cercania no puede funcionar
--    · horario cargado
--        sin horario nunca esta abierto, asi que no serviria de nada
--    · al menos 10 productos confirmados con precio
--        es la prueba de que hay alguien atras que se tomo el trabajo.
--        Un registro trucho no carga 10 precios.
--
--  Nada de eso lo hace K24: lo hace el kiosco. Y todo es reversible desde
--  la consola si algo huele mal, pero nada espera a que alguien mire.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════

insert into parametros_negocio (clave, valor, nota) values
  ('kiosco_minimo_productos', 10, 'Productos confirmados con precio para empezar a recibir pedidos.')
on conflict (clave) do nothing;

alter table puntos_preparacion add column if not exists foto_url    text;
alter table puntos_preparacion add column if not exists alta_propia boolean not null default false;
alter table puntos_preparacion add column if not exists suspendido  boolean not null default false;

comment on column puntos_preparacion.suspendido is
  'Freno manual. Solo se usa si algo anduvo mal: por defecto nadie toca nada.';


-- ─────────────────────────────────────────────────────────────────────
--  ¿ESTE PUNTO YA PUEDE RECIBIR PEDIDOS?
-- ─────────────────────────────────────────────────────────────────────
create or replace function punto_listo(p_punto_id uuid)
returns boolean
language sql stable as $$
  select
    p.activo
    and not p.suspendido
    and p.lat is not null and p.lng is not null
    and exists (select 1 from punto_horarios h where h.punto_id = p.id)
    and (
      p.tipo = 'mami'                         -- los propios no rinden examen
      or (select count(*) from punto_precios pp where pp.punto_id = p.id)
         >= param('kiosco_minimo_productos', 10)
    )
  from puntos_preparacion p
  where p.id = p_punto_id;
$$;

comment on function punto_listo(uuid) is
  'La puerta la abre el kiosco completando lo suyo, no una aprobacion manual.';


-- Lo que le falta, en palabras, para poder decirselo en la pantalla.
create or replace function que_le_falta(p_punto_id uuid)
returns table (listo boolean, faltan text[], productos integer, minimo integer)
language sql stable as $$
  with p as (select * from puntos_preparacion where id = p_punto_id),
  d as (
    select
      (select count(*) from punto_precios pp where pp.punto_id = p.id)::integer as n,
      param('kiosco_minimo_productos', 10)::integer                             as min,
      (p.lat is null or p.lng is null)                                          as sin_mapa,
      not exists (select 1 from punto_horarios h where h.punto_id = p.id)        as sin_horario,
      p.suspendido
    from p
  )
  select
    punto_listo(p_punto_id),
    array_remove(array[
      case when d.sin_mapa    then 'No pudimos ubicar tu dirección en el mapa' end,
      case when d.sin_horario then 'Falta cargar tu horario' end,
      case when d.n < d.min   then 'Confirmá al menos ' || d.min || ' productos con precio (llevás ' || d.n || ')' end,
      case when d.suspendido  then 'Tu cuenta está suspendida, escribinos' end
    ], null),
    d.n, d.min
  from d;
$$;


-- ─────────────────────────────────────────────────────────────────────
--  EL ALTA
-- ─────────────────────────────────────────────────────────────────────
create or replace function registrar_kiosco(
  p_nombre    text,
  p_direccion text,
  p_lat       double precision,
  p_lng       double precision,
  p_usuario   text,
  p_pin       text,
  p_telefono  text default null,
  p_radio_km  numeric default 5.0
)
returns table (ok boolean, punto_id uuid, motivo text)
language plpgsql as $$
declare
  u     text := lower(trim(coalesce(p_usuario, '')));
  nom   text := trim(coalesce(p_nombre, ''));
  dir   text := trim(coalesce(p_direccion, ''));
  nuevo uuid;
begin
  if length(nom) < 3 then
    return query select false, null::uuid, 'Poné el nombre de tu kiosco'::text; return;
  end if;
  if length(dir) < 6 then
    return query select false, null::uuid, 'Poné la dirección completa'::text; return;
  end if;
  if u !~ '^[a-z0-9_.\-]{3,30}$' then
    return query select false, null::uuid,
      'El usuario va sin espacios ni acentos, de 3 a 30 caracteres'::text; return;
  end if;
  if length(coalesce(p_pin, '')) < 4 then
    return query select false, null::uuid, 'El PIN necesita al menos 4 dígitos'::text; return;
  end if;
  if exists (select 1 from puntos_preparacion where lower(usuario) = u) then
    return query select false, null::uuid, 'Ese usuario ya está tomado'::text; return;
  end if;

  -- Dos kioscos en la misma esquina son casi siempre el mismo cargado dos
  -- veces. Se avisa en vez de crear un duplicado que despues compite
  -- consigo mismo por los pedidos.
  if p_lat is not null and exists (
    select 1 from puntos_preparacion
     where lat is not null and distancia_km(lat, lng, p_lat, p_lng) < 0.05
  ) then
    return query select false, null::uuid,
      'Ya hay un kiosco registrado en esa dirección. Si es tuyo, entrá con tu usuario.'::text;
    return;
  end if;

  insert into puntos_preparacion
    (nombre, tipo, direccion, lat, lng, telefono, radio_km, activo, online, alta_propia)
  values
    (left(nom, 120), 'kiosco_adherido', left(dir, 300), p_lat, p_lng,
     left(coalesce(p_telefono, ''), 40), greatest(coalesce(p_radio_km, 5), 1), true, false, true)
  returning id into nuevo;

  perform poner_pin_punto(nuevo, u, p_pin);

  -- Horario abierto por defecto: es lo que un kiosco 24hs espera, y de
  -- todos modos no recibe nada hasta que prende el interruptor.
  insert into punto_horarios (punto_id, dia_semana, desde, hasta)
  select nuevo, d, '00:00'::time, '23:59'::time from generate_series(0, 6) d;

  return query select true, nuevo, 'Listo'::text;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  LA CASCADA SOLO MIRA A LOS QUE ESTAN LISTOS
-- ─────────────────────────────────────────────────────────────────────
drop function if exists candidatos_para_pedido(bigint);

create or replace function candidatos_para_pedido(p_pedido_id bigint)
returns table (
  punto_id    uuid,
  nombre      text,
  tipo        text,
  km          numeric,
  confirmados integer,
  orden       integer
)
language sql stable as $$
  with ped as (select id, lat, lng, items from pedidos where id = p_pedido_id),
  aptos as (
    select
      p.id, p.nombre, p.tipo,
      round(distancia_km(p.lat, p.lng, ped.lat, ped.lng)::numeric, 2) as km,
      punto_confirma(p.id, ped.items)                                 as confirmados,
      p.prioridad
    from puntos_preparacion p, ped
    where punto_listo(p.id)
      and ped.lat is not null and ped.lng is not null
      and punto_abierto(p.id)
      and punto_tiene_todo(p.id, ped.items)
      and (p.tipo = 'mami' or punto_conectado(p.id))
      and distancia_km(p.lat, p.lng, ped.lat, ped.lng) <= p.radio_km
      and not exists (
        select 1 from pedido_ofertas o
         where o.pedido_id = p_pedido_id and o.punto_id = p.id
      )
  )
  select id, nombre, tipo, km, confirmados,
         (row_number() over (
            order by
              case when tipo = 'mami' then 1 else 0 end,
              confirmados desc,
              km - prioridad,
              nombre
         ))::integer
  from aptos;
$$;

revoke all on function candidatos_para_pedido(bigint) from anon, authenticated;
revoke all on function punto_listo(uuid)               from anon, authenticated;
revoke all on function que_le_falta(uuid)              from anon, authenticated;
revoke all on function registrar_kiosco(text, text, double precision, double precision, text, text, text, numeric)
  from anon, authenticated;


-- Para tu consola: quien se dio de alta y en que estado quedo.
create or replace view v_altas
with (security_invoker = true) as
select
  p.id, p.nombre, p.direccion, p.telefono, p.usuario,
  p.alta_propia, p.suspendido, p.creado_at,
  punto_listo(p.id)                                                        as recibe_pedidos,
  (select count(*) from punto_precios pp where pp.punto_id = p.id)         as productos,
  (select count(*) from pedidos pe where pe.punto_id = p.id)               as pedidos_tomados
from puntos_preparacion p
where p.tipo = 'kiosco_adherido'
order by p.creado_at desc;

revoke all on v_altas from anon, authenticated;


select
  (select count(*) from pg_proc
    where proname in ('registrar_kiosco','punto_listo','que_le_falta'))   as funciones,
  (select count(*) from information_schema.views where table_name='v_altas') as vista,
  (select count(*) from information_schema.columns where table_name='puntos_preparacion'
     and column_name in ('foto_url','alta_propia','suspendido'))          as columnas;
-- Esperado: 3, 1, 3
