-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Ofertas al kiosco, solo donde de verdad convenimos
--  Ejecutar DESPUES de 22_arreglo_alta_kiosco.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  POR QUE ESTO ES CHICO A PROPOSITO
--
--  La comparativa contra Maxiconsumo dio un resultado incomodo pero util:
--  K24 gana en Coca, Fernet y Quilmes, y en cigarrillos ni compiten. Pero
--  PIERDE por 13 a 20% en licores y whiskies.
--
--  O sea que K24 no puede ser un mayorista general. Si le ofrece de todo a
--  un kiosquero, el kiosquero va a comparar, va a encontrar tres cosas mas
--  caras, y va a dejar de mirar las ofertas para siempre. Se pierde la
--  credibilidad en la primera lista.
--
--  Ofreciendo solo donde gana, cada oferta que ve es una que le conviene.
--  Eso se puede sostener.
--
--  LA REGLA QUE HACE QUE ESTO NO SE PUDRA
--  Una oferta solo se muestra si el kiosco HOY la esta comprando mas cara.
--  No se muestran "ofertas" que no le ahorran nada: eso es publicidad, y
--  la publicidad adentro de la herramienta de trabajo de alguien es la
--  forma mas rapida de que deje de abrirla.
--
--  CONFLICTO DE INTERES, DICHO DE FRENTE
--  K24 le cobra 15% de comision al kiosco Y le quiere vender mercaderia.
--  Eso puede sentirse como apretar dos veces. Por eso: la oferta se ve
--  solo si le ahorra plata, se muestra cuanto ahorra, y no hay ninguna
--  obligacion de comprar. Si un kiosco nunca compra, no cambia nada de su
--  relacion con la red.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════

insert into parametros_negocio (clave, valor, nota) values
  ('oferta_ahorro_minimo_pct', 3,
   'Ahorro minimo para mostrar una oferta. Debajo de esto no vale la molestia.')
on conflict (clave) do nothing;


-- ─────────────────────────────────────────────────────────────────────
--  LO QUE K24 LE PUEDE VENDER
-- ─────────────────────────────────────────────────────────────────────
-- Se carga a mano y es corto por diseño. Si la lista crece a 400 items,
-- alguien se olvido de por que existe este archivo.
create table if not exists ofertas_kiosco (
  id           bigint generated always as identity primary key,
  producto_id  text,
  nombre       text not null,
  -- Familia: sirve para agrupar y para acordarse de que esto esta acotado
  familia      text not null,
  precio       integer not null,
  unidad       text default 'unidad',
  minimo       integer not null default 1,
  nota         text,
  activa       boolean not null default true,
  actualizado_at timestamptz not null default now(),

  constraint familia_permitida check (familia in (
    'cigarrillos',   -- Maxiconsumo no los tiene
    'coca',          -- le ganamos
    'fernet',        -- le ganamos
    'quilmes'        -- le ganamos
  )),
  constraint precio_positivo check (precio > 0)
);

create index if not exists idx_oferta_activa on ofertas_kiosco(activa) where activa;

comment on table ofertas_kiosco is
  'Corta a proposito: solo las familias donde K24 le gana a los distribuidores. Ofrecer de todo quema la credibilidad en la primera lista.';

alter table ofertas_kiosco enable row level security;
revoke all on ofertas_kiosco from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  QUE LE CONVIENE A ESTE KIOSCO
-- ─────────────────────────────────────────────────────────────────────
-- Cruza lo que el kiosco cargo como precio propio contra lo que K24 le
-- puede vender. Solo devuelve donde ahorra.
create or replace function ofertas_para(p_punto_id uuid)
returns table (
  oferta_id   bigint,
  nombre      text,
  familia     text,
  precio_k24  integer,
  precio_suyo integer,
  ahorro      integer,
  ahorro_pct  numeric,
  minimo      integer,
  unidad      text,
  nota        text
)
language sql stable as $$
  with suyos as (
    select
      lower(trim(pp.nombre)) as clave,
      min(pp.precio)         as precio
    from punto_precios pp
    where pp.punto_id = p_punto_id
    group by lower(trim(pp.nombre))
  )
  select
    o.id, o.nombre, o.familia, o.precio, s.precio,
    (s.precio - o.precio)::integer,
    round(100.0 * (s.precio - o.precio) / nullif(s.precio, 0), 1),
    o.minimo, o.unidad, o.nota
  from ofertas_kiosco o
  join suyos s
    -- Se cruza por nombre normalizado, igual que v_precios_red. No es
    -- perfecto, pero el catalogo no tiene un id compartido con lo que
    -- carga cada kiosco en su lista.
    on s.clave = lower(trim(o.nombre))
  where o.activa
    -- La regla: solo si le ahorra de verdad. Sin esto, la solapa se
    -- llenaria de cosas que no le sirven y dejaria de abrirla.
    and s.precio > o.precio
    and 100.0 * (s.precio - o.precio) / nullif(s.precio, 0)
        >= param('oferta_ahorro_minimo_pct', 3)
  order by (s.precio - o.precio) desc;
$$;

comment on function ofertas_para(uuid) is
  'Solo devuelve ofertas que le ahorran plata. Mostrar el resto es publicidad adentro de su herramienta de trabajo.';


-- ─────────────────────────────────────────────────────────────────────
--  CUANTO AHORRARIA EN TOTAL
-- ─────────────────────────────────────────────────────────────────────
-- Un numero solo, para que la solapa diga algo concreto en vez de
-- "tenemos ofertas".
create or replace function ahorro_posible(p_punto_id uuid)
returns table (items integer, ahorro_total integer)
language sql stable as $$
  select count(*)::integer, coalesce(sum(ahorro), 0)::integer
    from ofertas_para(p_punto_id);
$$;


-- ─────────────────────────────────────────────────────────────────────
--  CUANDO PIDE
-- ─────────────────────────────────────────────────────────────────────
create table if not exists pedidos_mayoristas (
  id         bigint generated always as identity primary key,
  punto_id   uuid not null references puntos_preparacion(id) on delete cascade,
  items      jsonb not null,
  total      integer not null default 0,
  estado     text not null default 'nuevo',
  nota       text,
  creado_at  timestamptz not null default now(),

  constraint estado_mayorista check (estado in ('nuevo','preparando','entregado','cancelado'))
);

alter table pedidos_mayoristas enable row level security;
revoke all on pedidos_mayoristas from anon, authenticated;


create or replace function pedir_mercaderia(
  p_punto_id uuid,
  p_items    jsonb,
  p_nota     text default null
)
returns table (ok boolean, pedido_id bigint, motivo text)
language plpgsql as $$
declare
  tot   integer;
  nuevo bigint;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    return query select false, null::bigint, 'No elegiste nada'::text; return;
  end if;

  -- El total lo calcula la base leyendo ofertas_kiosco, no lo que manda el
  -- navegador. Si el precio viniera de afuera, cualquiera podria pedir
  -- diez cajas a un peso.
  select coalesce(sum(o.precio * greatest(1, (e->>'cantidad')::integer)), 0)
    into tot
    from jsonb_array_elements(p_items) e
    join ofertas_kiosco o on o.id = (e->>'oferta_id')::bigint and o.activa;

  if tot <= 0 then
    return query select false, null::bigint, 'No pudimos leer lo que pediste'::text; return;
  end if;

  insert into pedidos_mayoristas (punto_id, items, total, nota)
  values (p_punto_id, p_items, tot, left(coalesce(p_nota, ''), 500))
  returning id into nuevo;

  return query select true, nuevo, 'Pedido tomado, te contactamos'::text;
end $$;


create or replace view v_pedidos_mayoristas
with (security_invoker = true) as
select
  pm.id, pm.estado, pm.total, pm.items, pm.nota, pm.creado_at,
  p.nombre as kiosco, p.telefono, p.direccion
from pedidos_mayoristas pm
join puntos_preparacion p on p.id = pm.punto_id
order by pm.creado_at desc;

revoke all on v_pedidos_mayoristas from anon, authenticated;

revoke all on function ofertas_para(uuid)                      from anon, authenticated;
revoke all on function ahorro_posible(uuid)                    from anon, authenticated;
revoke all on function pedir_mercaderia(uuid, jsonb, text)     from anon, authenticated;


select
  (select count(*) from information_schema.tables
    where table_name in ('ofertas_kiosco','pedidos_mayoristas'))       as tablas,
  (select count(*) from pg_proc
    where proname in ('ofertas_para','ahorro_posible','pedir_mercaderia')) as funciones,
  (select count(*) from information_schema.views
    where table_name = 'v_pedidos_mayoristas')                         as vista;
-- Esperado: 2, 3, 1
