-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Mantenimiento
--  Ejecutar DESPUES de 01_esquema.sql
-- ═══════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────
--  Por que esto importa
-- ─────────────────────────────────────────────────────────────────────
-- Un repartidor en turno reporta posicion cada 15 segundos = 240 filas/hora.
-- Con 3 repartidores y 12 horas de turno son ~8.600 filas por dia,
-- 260.000 por mes, 3,1 millones al ano. El plan gratis de Supabase da 500 MB.
--
-- El rastro viejo no sirve para nada operativo: una vez entregado el pedido,
-- solo interesa el recorrido durante unos dias por si hay un reclamo.
-- Esta limpieza mantiene la tabla en un tamano razonable para siempre.

create or replace function limpiar_posiciones()
returns table (borradas_entregados bigint, borradas_viejas bigint)
language plpgsql security definer as $$
declare
  n1 bigint;
  n2 bigint;
begin
  -- 1) Rastro de pedidos ya cerrados hace mas de 7 dias
  with borradas as (
    delete from posiciones p
     using pedidos ped
     where p.pedido_id = ped.id
       and ped.estado in ('entregado','cancelado')
       and ped.actualizado_at < now() - interval '7 days'
    returning p.id
  ) select count(*) into n1 from borradas;

  -- 2) Posiciones sueltas (sin pedido) de mas de 2 dias:
  --    son las que manda la app mientras el repartidor esta en turno sin viaje
  with borradas as (
    delete from posiciones
     where pedido_id is null
       and creado_at < now() - interval '2 days'
    returning id
  ) select count(*) into n2 from borradas;

  return query select n1, n2;
end $$;

revoke all on function limpiar_posiciones() from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
--  Programarla con pg_cron (recomendado)
-- ─────────────────────────────────────────────────────────────────────
-- En Supabase: Database → Extensions → activar "pg_cron".
-- Despues descomentar y ejecutar esto una sola vez:
--
--   select cron.schedule(
--     'limpiar-posiciones-k24',
--     '0 4 * * *',                    -- todos los dias a las 4 AM
--     $$ select limpiar_posiciones() $$
--   );
--
-- Para verificar que quedo programada:  select * from cron.job;
-- Para sacarla:                          select cron.unschedule('limpiar-posiciones-k24');
--
-- Si preferis no usar pg_cron, la funcion tambien se puede llamar desde
-- el cron de Vercel. Ver despacho/api/cron-limpieza.js


-- ─────────────────────────────────────────────────────────────────────
--  Cierre de turnos colgados
-- ─────────────────────────────────────────────────────────────────────
-- Si un repartidor cierra el navegador sin marcar fin de turno, queda
-- "en_turno = true" para siempre y el panel lo muestra como disponible.
-- Esto lo baja solo despues de 2 horas sin reportar posicion.

create or replace function cerrar_turnos_colgados()
returns integer language plpgsql security definer as $$
declare n integer;
begin
  update repartidores
     set en_turno = false
   where en_turno = true
     and (ultima_pos_at is null or ultima_pos_at < now() - interval '2 hours');
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function cerrar_turnos_colgados() from anon, authenticated;

-- Programar junto con la limpieza:
--   select cron.schedule('cerrar-turnos-k24', '*/30 * * * *',
--     $$ select cerrar_turnos_colgados() $$);


-- ─────────────────────────────────────────────────────────────────────
--  Consultas utiles para el dia a dia
-- ─────────────────────────────────────────────────────────────────────

-- Como viene hoy
--   select * from v_metricas_dia limit 7;

-- Que hay en la calle ahora
--   select codigo, estado, repartidor_nombre, segundos_desde_creado/60 as min
--     from v_cola_despacho;

-- Historia completa de un pedido (para responder un reclamo)
--   select e.creado_at, e.estado_de, e.estado_a, e.actor, e.nota
--     from pedido_eventos e join pedidos p on p.id = e.pedido_id
--    where p.codigo = 'K24-000123' order by e.creado_at;

-- Cuanto tarda cada repartidor, ultimos 30 dias
--   select r.nombre,
--          count(*) as entregas,
--          round(avg(extract(epoch from (p.entregado_at - p.retirado_at))/60)::numeric,1) as min_promedio
--     from pedidos p join repartidores r on r.id = p.repartidor_id
--    where p.estado = 'entregado' and p.entregado_at > now() - interval '30 days'
--    group by r.nombre order by min_promedio;

-- Tamano de las tablas (para vigilar el plan gratis)
--   select relname as tabla, pg_size_pretty(pg_total_relation_size(relid)) as tamano
--     from pg_catalog.pg_statio_user_tables order by pg_total_relation_size(relid) desc;
