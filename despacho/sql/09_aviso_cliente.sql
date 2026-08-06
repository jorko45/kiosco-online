-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Exponer el token de seguimiento en la cola del panel
--  Ejecutar DESPUES de 08_referidos.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  POR QUE
--  El panel tiene un boton "Avisar" que le manda al cliente un WhatsApp
--  con el link de seguimiento de SU pedido. Para armar ese link hace
--  falta el token, que hasta ahora la vista no devolvia.
--
--  El token es lo unico que protege el seguimiento: quien lo tiene, ve
--  ese pedido. Por eso el link se arma en el panel (detras de login) y
--  no en ningun lado publico. La vista sigue con security_invoker, asi
--  que solo la lee quien ya podia leer los pedidos.
--
--  De paso se suma paga_con, para poder decirle en el mismo mensaje con
--  cuanto va a pagar y que el repartidor lleva el vuelto.

drop view if exists v_cola_despacho;

create view v_cola_despacho
with (security_invoker = true) as
select
  p.id, p.codigo, p.estado, p.cliente_nombre, p.cliente_telefono,
  p.token_seguimiento,
  p.direccion, p.direccion_notas, p.lat, p.lng,
  p.items, p.subtotal, p.envio, p.descuento, p.total,
  p.metodo_pago, p.pagado, p.paga_con,
  p.repartidor_id, r.nombre as repartidor_nombre,
  p.creado_at, p.asignado_at, p.retirado_at,
  extract(epoch from (now() - p.creado_at))::int as segundos_desde_creado
from pedidos p
left join repartidores r on r.id = p.repartidor_id
where p.estado not in ('entregado','cancelado')
order by p.creado_at asc;

revoke all on v_cola_despacho from anon, authenticated;

-- Comprobacion: deberia listar token_seguimiento y paga_con.
select column_name
  from information_schema.columns
 where table_name = 'v_cola_despacho'
   and column_name in ('token_seguimiento', 'paga_con', 'descuento')
 order by column_name;
