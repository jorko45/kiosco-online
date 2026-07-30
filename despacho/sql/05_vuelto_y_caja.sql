-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Vuelto, domicilio verificado y caja del repartidor
--  Ejecutar DESPUES de 04_actor_y_geo.sql
-- ═══════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────
--  1. CON CUANTO PAGA EL CLIENTE
-- ─────────────────────────────────────────────────────────────────────
-- El cliente lo elige en la caja. Si el repartidor sale con el cambio
-- justo, se ahorra el viaje de vuelta al kiosco a buscar monedas — que
-- es tiempo perdido en el unico recurso que no escala: la moto.
alter table pedidos add column if not exists paga_con integer;

comment on column pedidos.paga_con is
  'Billete con el que el cliente dice que va a pagar. El vuelto se calcula contra el total.';

alter table pedidos drop constraint if exists paga_con_coherente;
alter table pedidos add constraint paga_con_coherente
  check (paga_con is null or paga_con >= total);


-- ─────────────────────────────────────────────────────────────────────
--  2. DOMICILIO VERIFICADO
-- ─────────────────────────────────────────────────────────────────────
-- "Verificado" = ya recibimos al menos una entrega concretada en esa
-- direccion, con ese telefono. Le sirve al repartidor para saber si va a
-- un lugar conocido o a uno nuevo, que es informacion de seguridad real
-- cuando reparte de madrugada.
--
-- Se compara por telefono + direccion normalizada: el mismo cliente
-- escribe "Rondeau 165" y "rondeau 165 " y tiene que contar igual.
create or replace function entregas_previas(p_telefono text, p_direccion text)
returns integer language sql stable as $$
  select count(*)::integer
    from pedidos
   where estado = 'entregado'
     and cliente_telefono is not null
     and regexp_replace(cliente_telefono, '\D', '', 'g') = regexp_replace(coalesce(p_telefono,''), '\D', '', 'g')
     and normalizar_direccion(direccion) = normalizar_direccion(coalesce(p_direccion,''));
$$;

revoke all on function entregas_previas(text, text) from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  3. CAJA DEL REPARTIDOR
-- ─────────────────────────────────────────────────────────────────────
-- Al cerrar el turno, el repartidor tiene que rendir efectivo. Esta
-- funcion le dice exactamente cuanto: lo que cobro en mano, separado de
-- los pedidos que ya venian pagados y no toco.
--
-- Sin esto, la rendicion se hace de memoria y las diferencias aparecen
-- recien cuando alguien suma los pedidos del dia.
create or replace function caja_repartidor(p_repartidor_id uuid, p_desde timestamptz default null)
returns table (
  entregados        integer,
  cobrado_efectivo  integer,
  ya_pagados        integer,
  monto_ya_pagado   integer,
  a_rendir          integer
)
language sql stable as $$
  with hoy as (
    select *
      from pedidos
     where repartidor_id = p_repartidor_id
       and estado = 'entregado'
       and entregado_at >= coalesce(
             p_desde,
             date_trunc('day', now() at time zone 'America/Argentina/Cordoba')
               at time zone 'America/Argentina/Cordoba')
  )
  select
    count(*)::integer,
    coalesce(sum(total) filter (where metodo_pago = 'efectivo'), 0)::integer,
    count(*) filter (where metodo_pago <> 'efectivo')::integer,
    coalesce(sum(total) filter (where metodo_pago <> 'efectivo'), 0)::integer,
    -- Lo que tiene que entregar es solo el efectivo: el resto ya entro
    -- por MercadoPago o transferencia y el repartidor nunca lo toco.
    coalesce(sum(total) filter (where metodo_pago = 'efectivo'), 0)::integer
  from hoy;
$$;

revoke all on function caja_repartidor(uuid, timestamptz) from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  4. La cola del panel suma el vuelto
-- ─────────────────────────────────────────────────────────────────────
drop view if exists v_cola_despacho;

create view v_cola_despacho
with (security_invoker = true) as
select
  p.id, p.codigo, p.estado, p.cliente_nombre, p.cliente_telefono,
  p.direccion, p.direccion_notas, p.lat, p.lng,
  p.items, p.subtotal, p.envio, p.total, p.metodo_pago, p.pagado, p.paga_con,
  p.repartidor_id, r.nombre as repartidor_nombre,
  p.punto_id, pp.nombre as punto_nombre, pp.tipo as punto_tipo,
  pp.direccion as punto_direccion, pp.telefono as punto_telefono,
  (p.lat is null or p.lng is null) as sin_ubicar,
  entregas_previas(p.cliente_telefono, p.direccion) as entregas_previas,
  p.creado_at, p.asignado_at, p.retirado_at,
  extract(epoch from (now() - p.creado_at))::int as segundos_desde_creado
from pedidos p
left join repartidores r        on r.id  = p.repartidor_id
left join puntos_preparacion pp on pp.id = p.punto_id
where p.estado not in ('entregado','cancelado')
order by p.creado_at asc;

revoke all on v_cola_despacho from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  5. La vista del nodo ahora incluye precios
-- ─────────────────────────────────────────────────────────────────────
-- Decision de Joe: el kiosco necesita ver el precio de cada item para
-- poder facturar. Sigue SIN ver el envio, ni el total que paga el
-- cliente, ni un solo dato personal.
--
-- ⚠ Tener presente: esto le muestra el precio de venta a un comercio que
-- le vende a los mismos vecinos. Para el Mami es irrelevante; para un
-- kiosco adherido, le estas mostrando tu margen. Si en algun momento se
-- registra cuanto se le paga a cada nodo, conviene mostrar ESE numero.
drop view if exists v_pedidos_para_nodo;

create view v_pedidos_para_nodo
with (security_invoker = true) as
select
  p.codigo,
  p.punto_id,
  p.estado,
  p.items,
  p.subtotal as total_productos,   -- sin envio, a proposito
  p.creado_at,
  extract(epoch from (now() - p.creado_at))::int as segundos_esperando
from pedidos p
where p.estado in ('confirmado','preparando','asignado')
  and p.punto_id is not null;

revoke all on v_pedidos_para_nodo from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  Consultas utiles
-- ─────────────────────────────────────────────────────────────────────
-- Rendicion de un repartidor hoy:
--   select * from caja_repartidor('<uuid>');
--
-- Clientes que ya compraron antes (domicilios verificados):
--   select cliente_telefono, direccion, count(*) as entregas
--     from pedidos where estado='entregado'
--    group by 1,2 having count(*) > 1 order by 3 desc;
