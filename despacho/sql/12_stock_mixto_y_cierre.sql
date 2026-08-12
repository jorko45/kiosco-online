-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Etapa 1 · Stock mixto y cierre de la venta
--  Ejecutar DESPUES de 11_precios_del_kiosco.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  DOS COSAS, DE DOS PEDIDOS DISTINTOS
--
--  1. STOCK MIXTO
--     La lista de precios del kiosco pasa a valer como confirmacion de que
--     tiene el producto. Lo que no cargo, se asume que lo tiene, salvo que
--     lo haya marcado como faltante.
--
--     Entre dos kioscos que pueden tomar el pedido, gana el que tenga mas
--     items confirmados. No es un capricho: un kiosco que cargo el producto
--     y le puso precio es mucho mas probable que lo tenga de verdad que uno
--     del que solo sabemos que no dijo lo contrario.
--
--     Ojo con la contradiccion: si algo esta en su lista Y marcado como
--     faltante, gana el faltante y se le saca de la lista. El faltante es
--     un acto deliberado y reciente ("se me acabo"); la lista puede tener
--     meses.
--
--  2. LA VENTA SE CIERRA AL COBRAR
--     Entregado no es lo mismo que vendido. Un pedido entregado y no
--     cobrado no es una venta: es una perdida. Hasta ahora el sistema no
--     distinguia, y por lo tanto no habia forma de saber cuanto se vendio
--     de verdad.
--
--     Al cerrar se registra: cuanto se cobro, con que, cuanto vuelto se
--     dio, y queda marcado para agradecerle al cliente.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────
--  1. LA LISTA Y LOS FALTANTES NO SE CONTRADICEN
-- ─────────────────────────────────────────────────────────────────────
--  Marcar algo como faltante lo saca de la lista de precios. Si no, el
--  kiosco quedaria a la vez confirmando que lo tiene y avisando que no.
create or replace function faltante_manda_sobre_la_lista()
returns trigger language plpgsql as $$
begin
  delete from punto_precios
   where punto_id = new.punto_id
     and (producto_id = new.producto_id
          or lower(trim(nombre)) = lower(trim(coalesce(new.nombre, ''))));
  return new;
end $$;

drop trigger if exists trg_faltante_limpia_lista on punto_faltantes;
create trigger trg_faltante_limpia_lista
  after insert on punto_faltantes
  for each row execute function faltante_manda_sobre_la_lista();


-- ─────────────────────────────────────────────────────────────────────
--  2. CUANTO DE ESTE PEDIDO TIENE CONFIRMADO
-- ─────────────────────────────────────────────────────────────────────
create or replace function punto_confirma(p_punto_id uuid, p_items jsonb)
returns integer
language sql stable as $$
  select count(*)::integer
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) it
   where exists (
     select 1 from punto_precios pp
      where pp.punto_id = p_punto_id
        and (pp.producto_id = coalesce(it->>'id', it->>'key', '')
             or lower(trim(pp.nombre)) = lower(trim(coalesce(it->>'name', it->>'nombre', ''))))
   );
$$;

comment on function punto_confirma(uuid, jsonb) is
  'Cuantos items del pedido el kiosco tiene cargados con precio. Desempata la asignacion.';


-- ─────────────────────────────────────────────────────────────────────
--  3. A QUIEN LE TOCA, AHORA CON LA CONFIRMACION
-- ─────────────────────────────────────────────────────────────────────
--  Cambia el orden, no el filtro: los que quedan afuera son los mismos
--  de antes (faltantes, cerrado, desconectado, fuera de radio). Lo que
--  cambia es a cual de los que pueden se le ofrece primero.
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
  with ped as (
    select id, lat, lng, items from pedidos where id = p_pedido_id
  ),
  aptos as (
    select
      p.id, p.nombre, p.tipo,
      round(distancia_km(p.lat, p.lng, ped.lat, ped.lng)::numeric, 2) as km,
      punto_confirma(p.id, ped.items)                                 as confirmados,
      p.prioridad
    from puntos_preparacion p, ped
    where p.activo
      and p.lat is not null and p.lng is not null
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
              case when tipo = 'mami' then 1 else 0 end,  -- el Mami, ultimo
              confirmados desc,                            -- el que confirmo mas
              km - prioridad,                              -- despues, el mas cerca
              nombre
         ))::integer
  from aptos;
$$;

revoke all on function candidatos_para_pedido(bigint) from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  4. CERRAR LA VENTA
-- ─────────────────────────────────────────────────────────────────────
alter table pedidos add column if not exists cobrado        integer;
alter table pedidos add column if not exists vuelto_dado    integer;
alter table pedidos add column if not exists cerrado_at     timestamptz;
alter table pedidos add column if not exists agradecido_at  timestamptz;

comment on column pedidos.cobrado is
  'Lo que realmente entro. Puede no coincidir con total: pago parcial, redondeo, faltante.';


create or replace function cerrar_venta(
  p_pedido_id bigint,
  p_cobrado   integer default null,
  p_metodo    text    default null
)
returns table (ok boolean, motivo text, cobrado integer, vuelto integer, diferencia integer)
language plpgsql as $$
declare
  ped   record;
  cobro integer;
  vuelto integer := 0;
begin
  select * into ped from pedidos where id = p_pedido_id;
  if ped.id is null then
    return query select false, 'No existe ese pedido'::text, 0, 0, 0; return;
  end if;
  if ped.cerrado_at is not null then
    -- Cerrar dos veces contaria la venta dos veces. Se avisa y no se toca.
    return query select false, 'Esa venta ya estaba cerrada'::text,
      ped.cobrado, ped.vuelto_dado, 0; return;
  end if;
  if ped.estado = 'cancelado' then
    return query select false, 'El pedido esta cancelado'::text, 0, 0, 0; return;
  end if;

  cobro := coalesce(p_cobrado, ped.total);

  -- El vuelto solo tiene sentido en efectivo y si dijo con cuanto paga.
  if coalesce(p_metodo, ped.metodo_pago) = 'efectivo'
     and ped.paga_con is not null and ped.paga_con > cobro then
    vuelto := ped.paga_con - cobro;
  end if;

  update pedidos
     set estado        = case when estado = 'entregado' then estado else 'entregado' end,
         pagado        = true,
         cobrado       = cobro,
         vuelto_dado   = vuelto,
         metodo_pago   = coalesce(p_metodo, metodo_pago),
         cerrado_at    = now()
   where id = p_pedido_id;

  return query select true, 'Venta cerrada'::text, cobro, vuelto, cobro - ped.total;
end $$;

comment on function cerrar_venta(bigint, integer, text) is
  'Entregado + cobrado = vendido. Hasta acá el pedido no cuenta como venta.';


-- Marcar que ya se le agradeció, para no agradecer dos veces.
create or replace function marcar_agradecido(p_pedido_id bigint)
returns boolean
language sql as $$
  update pedidos set agradecido_at = now()
   where id = p_pedido_id and cerrado_at is not null and agradecido_at is null
  returning true;
$$;


-- ─────────────────────────────────────────────────────────────────────
--  5. LO QUE SE VENDIO DE VERDAD
-- ─────────────────────────────────────────────────────────────────────
--  Antes "vendido" era "entregado". Un pedido entregado y no cobrado
--  inflaba el numero y nadie se enteraba.
create or replace view v_ventas
with (security_invoker = true) as
select
  date_trunc('day', p.cerrado_at)                as dia,
  count(*)                                       as ventas,
  sum(p.cobrado)                                 as cobrado,
  sum(p.subtotal)                                as mercaderia,
  sum(p.envio)                                   as envios,
  sum(coalesce(p.pago_al_punto, 0))              as pagado_a_kioscos,
  sum(p.cobrado - coalesce(p.pago_al_punto, 0))  as queda_para_k24,
  count(*) filter (where p.cobrado < p.total)    as cobradas_de_menos,
  sum(p.total - p.cobrado) filter (where p.cobrado < p.total) as faltante_de_cobro
from pedidos p
where p.cerrado_at is not null
group by 1
order by 1 desc;

revoke all on v_ventas from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  6. PUERTAS CERRADAS
-- ─────────────────────────────────────────────────────────────────────
revoke all on function punto_confirma(uuid, jsonb)            from anon, authenticated;
revoke all on function cerrar_venta(bigint, integer, text)     from anon, authenticated;
revoke all on function marcar_agradecido(bigint)              from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  7. COMPROBACION
-- ─────────────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.columns
    where table_name = 'pedidos'
      and column_name in ('cobrado','vuelto_dado','cerrado_at','agradecido_at'))  as columnas_nuevas,
  (select count(*) from information_schema.views where table_name = 'v_ventas')   as vista_ventas,
  (select count(*) from pg_trigger where tgname = 'trg_faltante_limpia_lista')    as trigger_faltantes;
-- Esperado: 4, 1, 1
