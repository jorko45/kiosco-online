-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Las promos cuentan cuando entró la plata
--  Ejecutar DESPUES de 12_stock_mixto_y_cierre.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  DE DONDE VIENE ESTO
--  El premio de quien recomienda ya esperaba a que el pedido estuviera
--  entregado. Eso estaba bien pensado: si se regalara al confirmar,
--  alcanzaba con pedir y cancelar para fabricar descuentos.
--
--  Pero "entregado" no es "cobrado". Un pedido que se entrega y no se
--  cobra igual generaba el premio. Ahora hace falta que la venta este
--  cerrada, que es lo mismo que decir que la plata entro.
--
--  Y LO QUE FALTABA DE VERDAD
--  Si un pedido con codigo de referido se cancela, el canje quedaba
--  consumido igual: el cliente perdia su descuento de primera compra sin
--  haber comprado nunca. Eso no es una regla antifraude, es un error, y
--  el que lo sufre es justo el cliente nuevo que estabamos tratando de
--  ganar. Ahora al cancelar se libera y lo puede volver a usar.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────
--  1. EL PREMIO ESPERA A QUE ENTRE LA PLATA
-- ─────────────────────────────────────────────────────────────────────
--  Se toma como validas tambien las entregas viejas, anteriores a que
--  existiera cerrado_at. Si no, alguien que ya se habia ganado su premio
--  lo perderia de un dia para el otro sin entender por que.
create or replace function premios_de(p_telefono text)
returns integer language sql stable as $$
  select count(*)::integer
    from referido_canjes c
    join pedidos p on p.id = c.pedido_id
   where c.telefono_dueno = tel_norm(p_telefono)
     and not c.premio_usado
     and (
       p.cerrado_at is not null                      -- entregado y cobrado
       or (p.estado = 'entregado' and p.cobrado is null)  -- entregas de antes de este cambio
     );
$$;

revoke all on function premios_de(text) from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  2. SI SE CANCELA, EL CODIGO VUELVE
-- ─────────────────────────────────────────────────────────────────────
create or replace function liberar_canje_cancelado()
returns trigger language plpgsql as $$
begin
  if new.estado = 'cancelado' and coalesce(old.estado, '') <> 'cancelado' then
    -- El canje se borra: el cliente nunca compro, asi que su codigo de
    -- primera compra sigue disponible.
    delete from referido_canjes where pedido_id = new.id;

    -- Y si en ese pedido se habia gastado un premio, se devuelve.
    update referido_canjes
       set premio_usado = false, premio_pedido_id = null
     where premio_pedido_id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists trg_liberar_canje on pedidos;
create trigger trg_liberar_canje
  after update of estado on pedidos
  for each row execute function liberar_canje_cancelado();


-- ─────────────────────────────────────────────────────────────────────
--  3. QUE PROMOS SE GANARON DE VERDAD
-- ─────────────────────────────────────────────────────────────────────
create or replace view v_promos
with (security_invoker = true) as
select
  c.codigo,
  c.telefono_dueno,
  c.telefono_referido,
  c.descuento_referido,
  c.descuento_dueno,
  p.codigo                                     as pedido,
  p.estado,
  p.cerrado_at,
  case
    when p.cerrado_at is not null then 'ganada'
    when p.estado = 'cancelado'   then 'se cayo'
    else 'esperando que se cobre'
  end                                          as situacion,
  c.premio_usado
from referido_canjes c
join pedidos p on p.id = c.pedido_id
order by p.creado_at desc;

revoke all on v_promos from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  4. COMPROBACION
-- ─────────────────────────────────────────────────────────────────────
select
  (select count(*) from pg_trigger where tgname = 'trg_liberar_canje')        as trigger_liberar,
  (select count(*) from information_schema.views where table_name='v_promos') as vista_promos,
  (select count(*) from pg_proc where proname = 'premios_de')                 as funcion_premios;
-- Esperado: 1, 1, 1
