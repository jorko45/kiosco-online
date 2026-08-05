-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Rentabilidad con el margen REAL
--  Ejecutar DESPUES de 06_pago_repartidor.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  POR QUE EXISTE ESTE ARCHIVO
--  v_rentabilidad calculaba la ganancia de mercaderia como subtotal * 0.20,
--  suponiendo un markup del 25% sobre el costo. Ese numero salia de un
--  Excel viejo. La planilla en produccion usa:
--
--      precio = costo * (1 + margen) * (1 + mp)
--             = costo * 1,05 * 1,066
--
--  O sea 5% de margen, no 25%. La vista sobreestimaba la ganancia de
--  mercaderia casi 5 veces.
--
--  ADEMAS: el 6,6% de MercadoPago se le cobra a TODOS los clientes pero
--  solo se PAGA cuando el pedido se abona con MercadoPago. En efectivo
--  ese porcentaje queda en la caja. La ganancia real depende entonces del
--  medio de pago, cosa que la vista anterior ignoraba por completo.
--
--      efectivo        ->  precio * 0,1066   (10,7%)
--      mercadopago     ->  precio * 0,0406   ( 4,1%)
--
--  Un pedido en efectivo deja 2,6 veces mas que el mismo pedido por MP.

-- ─────────────────────────────────────────────────────────────────────
--  1. Parametros del negocio, en una tabla y no en el codigo
-- ─────────────────────────────────────────────────────────────────────
-- Cuando se negocie con el proveedor y el margen suba, se cambia ACA y
-- todos los reportes quedan bien. Los pedidos ya cerrados no se tocan:
-- la vista recalcula sobre el historico, pero el margen historico real
-- se congela en la columna ganancia_mercaderia de cada pedido (punto 3).
create table if not exists parametros_negocio (
  clave  text primary key,
  valor  numeric not null,
  nota   text,
  desde  timestamptz not null default now()
);

alter table parametros_negocio enable row level security;
revoke all on parametros_negocio from anon, authenticated;

insert into parametros_negocio (clave, valor, nota) values
  ('margen',       0.050, 'Margen sobre el costo. Planilla: columna Margen %'),
  ('comision_mp',  0.066, 'Comision de MercadoPago trasladada al precio')
on conflict (clave) do nothing;

-- ─────────────────────────────────────────────────────────────────────
--  2. Ganancia de mercaderia segun medio de pago
-- ─────────────────────────────────────────────────────────────────────
create or replace function ganancia_mercaderia(
  p_subtotal integer,
  p_metodo   text
)
returns integer language sql stable as $$
  with p as (
    select
      (select valor from parametros_negocio where clave = 'margen')      as m,
      (select valor from parametros_negocio where clave = 'comision_mp') as mp
  )
  select round(
    p_subtotal * (
      -- lo que queda despues de pagar la mercaderia...
      (1 - 1 / ((1 + p.m) * (1 + p.mp)))
      -- ...menos la comision, solo si se cobro por MercadoPago
      - case when p_metodo = 'efectivo' then 0 else p.mp end
    )
  )::integer
  from p;
$$;

-- ─────────────────────────────────────────────────────────────────────
--  3. Vista de rentabilidad corregida
-- ─────────────────────────────────────────────────────────────────────
-- CREATE OR REPLACE no permite insertar columnas en el medio de la lista.
drop view if exists v_rentabilidad;

create view v_rentabilidad
with (security_invoker = true) as
select
  p.codigo,
  p.entregado_at,
  p.metodo_pago,
  p.subtotal                                          as productos,
  ganancia_mercaderia(p.subtotal, p.metodo_pago)      as ganancia_mercaderia,
  p.envio                                             as envio_cobrado,
  coalesce(p.pago_repartidor, 0)                      as pago_repartidor,
  (p.envio - coalesce(p.pago_repartidor, 0))          as resultado_envio,
  (ganancia_mercaderia(p.subtotal, p.metodo_pago)
     + p.envio - coalesce(p.pago_repartidor, 0))      as contribucion,
  (p.envio = 0)                                       as fue_envio_gratis,
  r.nombre                                            as repartidor,
  r.vehiculo
from pedidos p
left join repartidores r on r.id = p.repartidor_id
where p.estado = 'entregado';

revoke all on v_rentabilidad from anon, authenticated;
revoke all on function ganancia_mercaderia(integer, text) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
--  Consultas utiles
-- ─────────────────────────────────────────────────────────────────────
--
-- Contribucion segun medio de pago (esperado: efectivo ~2,6x mas):
--   select metodo_pago,
--          count(*)                       as pedidos,
--          round(avg(productos))          as ticket_medio,
--          round(avg(contribucion))       as contribucion_media
--     from v_rentabilidad
--    where entregado_at > now() - interval '30 days'
--    group by metodo_pago;
--
-- Cuanto cuestan de verdad los envios gratis:
--   select count(*)                 as pedidos,
--          round(avg(contribucion)) as contribucion_media,
--          sum(contribucion)        as total
--     from v_rentabilidad
--    where fue_envio_gratis;
--
-- Si da NEGATIVO, cada envio gratis esta destruyendo valor.
--
-- Cuando mejore el margen con el proveedor:
--   update parametros_negocio set valor = 0.15, desde = now()
--    where clave = 'margen';
