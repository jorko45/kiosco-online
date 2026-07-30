-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Pago al repartidor por envío
--  Ejecutar DESPUES de 05_vuelto_y_caja.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  Se paga por envío entregado: moto $3.000, auto $4.000.
--
--  DECISION IMPORTANTE — la tarifa se congela en el pedido.
--  El pago no se calcula con la tarifa de hoy, sino con la que regia el
--  dia de la entrega, guardada en el propio pedido. En Argentina las
--  tarifas se actualizan seguido: si el pago se calculara al vuelo,
--  cada aumento reescribiria la historia y las liquidaciones viejas
--  dejarian de cuadrar con lo que realmente se pago.

-- ─────────────────────────────────────────────────────────────────────
--  1. Vehiculo y tarifa del repartidor
-- ─────────────────────────────────────────────────────────────────────
alter table repartidores add column if not exists vehiculo text not null default 'moto';
alter table repartidores add column if not exists tarifa_envio integer;

alter table repartidores drop constraint if exists vehiculo_valido;
alter table repartidores add constraint vehiculo_valido
  check (vehiculo in ('moto','auto','bici','otro'));

-- Tarifas vigentes. Cambiarlas aca actualiza a los repartidores que no
-- tengan una tarifa propia; los pedidos ya entregados no se tocan.
create table if not exists tarifas_envio (
  vehiculo   text primary key,
  monto      integer not null,
  desde      timestamptz not null default now(),
  constraint monto_positivo check (monto > 0)
);

alter table tarifas_envio enable row level security;
revoke all on tarifas_envio from anon, authenticated;

insert into tarifas_envio (vehiculo, monto) values
  ('moto', 3000), ('auto', 4000), ('bici', 2500), ('otro', 3000)
on conflict (vehiculo) do nothing;

-- Cuanto cobra un repartidor por envio: su tarifa propia si tiene una
-- negociada, si no la general de su vehiculo.
create or replace function tarifa_de(p_repartidor_id uuid)
returns integer language sql stable as $$
  select coalesce(
    r.tarifa_envio,
    (select t.monto from tarifas_envio t where t.vehiculo = r.vehiculo),
    3000
  )
  from repartidores r where r.id = p_repartidor_id;
$$;

-- ─────────────────────────────────────────────────────────────────────
--  2. El pedido guarda cuanto se le pago al repartidor
-- ─────────────────────────────────────────────────────────────────────
alter table pedidos add column if not exists pago_repartidor integer;

comment on column pedidos.pago_repartidor is
  'Lo que se le paga al repartidor por este envio. Se congela al entregar.';

-- Al pasar a entregado se sella la tarifa vigente en ese momento.
create or replace function sellar_pago_repartidor()
returns trigger language plpgsql as $$
begin
  if new.estado = 'entregado'
     and new.pago_repartidor is null
     and new.repartidor_id is not null then
    new.pago_repartidor := tarifa_de(new.repartidor_id);
  end if;
  return new;
end $$;

drop trigger if exists trg_pago_repartidor on pedidos;
create trigger trg_pago_repartidor
  before update on pedidos
  for each row execute function sellar_pago_repartidor();

-- ─────────────────────────────────────────────────────────────────────
--  3. Rentabilidad real por pedido
-- ─────────────────────────────────────────────────────────────────────
-- Con margen del 25% sobre el costo (= 20% sobre el precio de venta),
-- la ganancia de mercaderia es total_productos * 0.20.
--
-- La cuenta completa de un pedido es:
--     ganancia mercaderia + envio cobrado - pago al repartidor
--
-- Cuando el envio va gratis, esa resta queda entera contra el resultado:
-- ahi se ve cuanto cuesta de verdad la promo de los 10 envios gratis.
create or replace view v_rentabilidad
with (security_invoker = true) as
select
  p.codigo,
  p.entregado_at,
  p.subtotal                                     as productos,
  round(p.subtotal * 0.20)::integer              as ganancia_mercaderia,
  p.envio                                        as envio_cobrado,
  coalesce(p.pago_repartidor, 0)                 as pago_repartidor,
  (p.envio - coalesce(p.pago_repartidor, 0))     as resultado_envio,
  (round(p.subtotal * 0.20)::integer + p.envio - coalesce(p.pago_repartidor, 0)) as contribucion,
  (p.envio = 0)                                  as fue_envio_gratis,
  r.nombre                                       as repartidor,
  r.vehiculo
from pedidos p
left join repartidores r on r.id = p.repartidor_id
where p.estado = 'entregado';

revoke all on v_rentabilidad from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
--  4. Liquidacion del repartidor
-- ─────────────────────────────────────────────────────────────────────
-- Lo que hay que pagarle, contra lo que tiene que rendir en efectivo.
-- Si el efectivo cobrado supera lo que se le debe, la diferencia la
-- entrega; si no, se le paga la diferencia.
create or replace function liquidacion_repartidor(
  p_repartidor_id uuid,
  p_desde timestamptz default null,
  p_hasta timestamptz default null
)
returns table (
  entregas          integer,
  a_cobrar          integer,
  efectivo_en_mano  integer,
  saldo             integer
)
language sql stable as $$
  with e as (
    select *
      from pedidos
     where repartidor_id = p_repartidor_id
       and estado = 'entregado'
       and entregado_at >= coalesce(
             p_desde,
             date_trunc('day', now() at time zone 'America/Argentina/Cordoba')
               at time zone 'America/Argentina/Cordoba')
       and entregado_at <  coalesce(p_hasta, now() + interval '1 second')
  )
  select
    count(*)::integer,
    coalesce(sum(pago_repartidor), 0)::integer,
    coalesce(sum(total) filter (where metodo_pago = 'efectivo'), 0)::integer,
    -- Positivo: el repartidor tiene que entregar plata.
    -- Negativo: hay que pagarle la diferencia.
    (coalesce(sum(total) filter (where metodo_pago = 'efectivo'), 0)
     - coalesce(sum(pago_repartidor), 0))::integer
  from e;
$$;

revoke all on function liquidacion_repartidor(uuid, timestamptz, timestamptz) from anon, authenticated;
revoke all on function tarifa_de(uuid) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
--  Consultas utiles
-- ─────────────────────────────────────────────────────────────────────
--
-- Alta con vehiculo:
--   select crear_repartidor('Nombre','351...','1234');
--   update repartidores set vehiculo='auto' where telefono='351...';
--
-- Tarifa distinta para uno en particular:
--   update repartidores set tarifa_envio=3500 where telefono='351...';
--
-- Actualizar la tarifa general (no afecta pedidos ya entregados):
--   update tarifas_envio set monto=3500, desde=now() where vehiculo='moto';
--
-- Liquidacion de hoy:
--   select * from liquidacion_repartidor('<uuid>');
--
-- ¿Cuanto cuestan realmente los envios gratis?
--   select count(*) as envios_gratis,
--          sum(pago_repartidor) as costo_directo,
--          sum(5000 - pago_repartidor) as contribucion_resignada
--     from pedidos
--    where estado='entregado' and envio = 0;
--
-- Contribucion promedio por pedido, ultimos 30 dias:
--   select round(avg(contribucion)) as contribucion_media,
--          round(avg(contribucion) filter (where not fue_envio_gratis)) as con_envio_pago,
--          round(avg(contribucion) filter (where fue_envio_gratis))     as con_envio_gratis
--     from v_rentabilidad where entregado_at > now() - interval '30 days';
