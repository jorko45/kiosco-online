-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Códigos de barra
--  Ejecutar DESPUES de 16_lista_por_lote.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  EL PROBLEMA
--  El catalogo no tiene codigos de barra: los ids son internos del Mami
--  (3080013) y de la Distribuidora (d-xxxx). Escanear una Coca devuelve
--  7790895000997 y no hay con que asociarlo.
--
--  LA SALIDA
--  Que la red arme esa base entre todos. El primer kiosco que escanea un
--  producto lo vincula una vez; de ahi en adelante cualquier otro escanea
--  y resuelve solo. Cada kiosco que entra encuentra mas trabajo hecho que
--  el anterior, y el que lo hizo no lo hizo al pedo.
--
--  Un EAN es un dato publico impreso en el envase. Compartirlo entre
--  kioscos no expone nada de nadie: no es como la lista de clientes.
--
--  POR QUE SE CUENTAN LAS CONFIRMACIONES
--  Alguien puede escanear mal, o vincular el codigo al producto
--  equivocado. En vez de confiar en el primero que lo cargo, se cuenta
--  cuantos kioscos distintos llegaron a la misma conclusion. Un vinculo
--  con tres confirmaciones vale mas que uno con una.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════

create table if not exists codigos_barra (
  ean          text primary key,
  producto_id  text not null,
  nombre       text,
  -- Cuantos puntos distintos vincularon este codigo a este producto.
  confirmado   integer not null default 1,
  primero_por  uuid references puntos_preparacion(id) on delete set null,
  creado_at    timestamptz not null default now(),
  visto_at     timestamptz not null default now(),

  constraint ean_valido check (ean ~ '^[0-9]{8,14}$')
);

create index if not exists idx_barra_producto on codigos_barra(producto_id);

comment on table codigos_barra is
  'EAN -> producto del catalogo. Lo arma la red escaneando, y lo usan todos.';


-- Cada vinculo que propone un kiosco. Se guarda aparte para poder contar
-- cuantos coincidieron sin dejar que uno solo defina la verdad.
create table if not exists codigo_votos (
  ean         text not null,
  punto_id    uuid not null references puntos_preparacion(id) on delete cascade,
  producto_id text not null,
  creado_at   timestamptz not null default now(),
  primary key (ean, punto_id)
);


-- ─────────────────────────────────────────────────────────────────────
--  BUSCAR
-- ─────────────────────────────────────────────────────────────────────
create or replace function buscar_ean(p_ean text)
returns table (ean text, producto_id text, nombre text, confirmado integer)
language sql stable as $$
  select c.ean, c.producto_id, c.nombre, c.confirmado
    from codigos_barra c
   where c.ean = regexp_replace(coalesce(p_ean,''), '\D', '', 'g');
$$;


-- ─────────────────────────────────────────────────────────────────────
--  VINCULAR
-- ─────────────────────────────────────────────────────────────────────
create or replace function vincular_ean(
  p_ean         text,
  p_producto_id text,
  p_nombre      text,
  p_punto_id    uuid
)
returns table (ok boolean, confirmado integer, motivo text)
language plpgsql as $$
declare
  e     text := regexp_replace(coalesce(p_ean,''), '\D', '', 'g');
  prod  text := trim(coalesce(p_producto_id, ''));
  actual record;
  n     integer;
begin
  if e !~ '^[0-9]{8,14}$' then
    return query select false, 0, 'Ese código no parece un código de barras'::text; return;
  end if;
  if prod = '' then
    return query select false, 0, 'Falta el producto'::text; return;
  end if;

  -- El voto de cada punto es uno solo: si cambia de opinion, se reemplaza.
  insert into codigo_votos (ean, punto_id, producto_id)
  values (e, p_punto_id, prod)
  on conflict (ean, punto_id) do update set producto_id = excluded.producto_id,
                                            creado_at = now();

  -- Gana el producto mas votado para ese codigo.
  select producto_id, count(*)::integer as votos into actual
    from codigo_votos where ean = e
   group by producto_id order by count(*) desc, min(creado_at) limit 1;

  insert into codigos_barra (ean, producto_id, nombre, confirmado, primero_por)
  values (e, actual.producto_id, left(coalesce(p_nombre,''), 200), actual.votos, p_punto_id)
  on conflict (ean) do update
    set producto_id = excluded.producto_id,
        nombre      = coalesce(nullif(excluded.nombre,''), codigos_barra.nombre),
        confirmado  = excluded.confirmado,
        visto_at    = now();

  return query select true, actual.votos, 'Vinculado'::text;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  CUANTO LLEVA ARMADA LA RED
-- ─────────────────────────────────────────────────────────────────────
create or replace view v_codigos
with (security_invoker = true) as
select
  c.ean, c.producto_id, c.nombre, c.confirmado, c.creado_at,
  p.nombre as cargado_por,
  (select count(distinct v.producto_id) from codigo_votos v where v.ean = c.ean) as opiniones_distintas
from codigos_barra c
left join puntos_preparacion p on p.id = c.primero_por
order by c.confirmado desc, c.creado_at desc;

revoke all on v_codigos from anon, authenticated;


alter table codigos_barra enable row level security;
alter table codigo_votos  enable row level security;
revoke all on codigos_barra from anon, authenticated;
revoke all on codigo_votos  from anon, authenticated;
revoke all on function buscar_ean(text)                       from anon, authenticated;
revoke all on function vincular_ean(text, text, text, uuid)   from anon, authenticated;


select
  (select count(*) from information_schema.tables
    where table_name in ('codigos_barra','codigo_votos'))       as tablas,
  (select count(*) from pg_proc
    where proname in ('buscar_ean','vincular_ean'))             as funciones,
  (select count(*) from information_schema.views
    where table_name = 'v_codigos')                             as vista;
-- Esperado: 2, 2, 1
