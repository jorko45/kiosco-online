-- ═══════════════════════════════════════════════════════════════════════
--  K24 · El kiosco se maneja solo
--  Ejecutar DESPUES de 14_repartidor.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  QUE SE SUMA
--  Hasta ahora el kiosquero podia recibir pedidos, pero no podia ver nada
--  de lo suyo: cuantos tomo, cuanto genero, que le queda por cobrar. Un
--  socio que no puede ver su propia cuenta no es un socio, es un mandado.
--
--  LA REGLA DE SIEMPRE, QUE NO CAMBIA
--  De aca no sale el nombre, el telefono ni la direccion del cliente. Un
--  kiosco adherido le vende a los mismos vecinos: si le damos la lista de
--  clientes, le estamos armando la competencia con nuestra propia plata.
--  Ve que preparo, cuando, y cuanto le toca. Nada mas.
--
--  SOBRE "CUANTO GANE"
--  Se informa lo GENERADO, no lo cobrado. No existe todavia un circuito
--  de liquidacion —cuando le pagaste, con que, si quedo saldo— y mostrar
--  un numero como si fuera plata en la mano seria mentirle. Cuando exista
--  la liquidacion, se agrega la columna y recien ahi se puede hablar de
--  saldo.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────
--  1. LO QUE PREPARO
-- ─────────────────────────────────────────────────────────────────────
create or replace view v_kiosco_pedidos
with (security_invoker = true) as
select
  p.punto_id,
  p.id                                        as pedido_id,
  p.codigo,
  p.estado,
  jsonb_array_length(coalesce(p.items, '[]'::jsonb)) as renglones,
  (select coalesce(sum((it->>'qty')::int), 0)
     from jsonb_array_elements(coalesce(p.items,'[]'::jsonb)) it) as unidades,
  p.items,
  p.subtotal,
  p.pago_al_punto,
  p.comision_pct,
  p.punto_asignado_at,
  p.entregado_at,
  p.cerrado_at,
  case
    when p.estado = 'cancelado'    then 'cancelado'
    when p.cerrado_at is not null  then 'cobrado'
    when p.estado = 'entregado'    then 'entregado, falta cobrar'
    else 'en curso'
  end                                         as situacion
from pedidos p
where p.punto_id is not null;

revoke all on v_kiosco_pedidos from anon, authenticated;

comment on view v_kiosco_pedidos is
  'Lo que preparo cada punto. Sin datos del cliente: es competencia.';


-- ─────────────────────────────────────────────────────────────────────
--  2. SU PLATA
-- ─────────────────────────────────────────────────────────────────────
--  Solo cuentan los pedidos con la venta cerrada. Un pedido entregado y
--  no cobrado todavia no genero nada para nadie.
create or replace function ganancias_punto(p_punto_id uuid)
returns table (
  hoy_pedidos      integer,
  hoy_generado     integer,
  semana_pedidos   integer,
  semana_generado  integer,
  mes_pedidos      integer,
  mes_generado     integer,
  en_curso         integer,
  sin_cobrar       integer
)
language sql stable as $$
  with base as (
    select p.*,
           (p.cerrado_at at time zone 'America/Argentina/Cordoba')::date as dia
      from pedidos p
     where p.punto_id = p_punto_id
  ),
  hoy_ as (select * from base where dia = (now() at time zone 'America/Argentina/Cordoba')::date),
  sem_ as (select * from base
            where dia >= ((now() at time zone 'America/Argentina/Cordoba')::date
                          - extract(dow from (now() at time zone 'America/Argentina/Cordoba'))::int)),
  mes_ as (select * from base
            where dia >= date_trunc('month', (now() at time zone 'America/Argentina/Cordoba')::date))
  select
    (select count(*) from hoy_)::integer,
    (select coalesce(sum(pago_al_punto),0) from hoy_)::integer,
    (select count(*) from sem_)::integer,
    (select coalesce(sum(pago_al_punto),0) from sem_)::integer,
    (select count(*) from mes_)::integer,
    (select coalesce(sum(pago_al_punto),0) from mes_)::integer,
    (select count(*) from base
      where estado in ('confirmado','preparando','asignado','en_camino'))::integer,
    (select coalesce(sum(pago_al_punto),0) from base
      where estado = 'entregado' and cerrado_at is null)::integer;
$$;

comment on function ganancias_punto(uuid) is
  'Lo GENERADO, no lo cobrado. Todavia no hay circuito de liquidacion.';


-- ─────────────────────────────────────────────────────────────────────
--  3. SUS PRODUCTOS, EN UNA SOLA LISTA
-- ─────────────────────────────────────────────────────────────────────
--  Hasta ahora el kiosquero tenia dos listas separadas —lo que vende y lo
--  que le falta— y tenia que entender la diferencia. En el mostrador eso
--  no funciona. Ahora es una lista sola con un interruptor por producto.
create or replace view v_kiosco_productos
with (security_invoker = true) as
select
  pp.punto_id,
  pp.id,
  pp.nombre,
  pp.producto_id,
  pp.precio,
  true                as disponible,
  pp.actualizado_at   as desde
from punto_precios pp
union all
select
  f.punto_id,
  null::bigint,
  coalesce(f.nombre, f.producto_id),
  f.producto_id,
  null::integer,
  false,
  f.desde
from punto_faltantes f;

revoke all on v_kiosco_productos from anon, authenticated;


-- Prender o apagar un producto desde la misma lista. Apagarlo lo manda a
-- faltantes; prenderlo lo saca y, si tenia precio, lo devuelve a la lista.
create or replace function poner_disponible(
  p_punto_id    uuid,
  p_nombre      text,
  p_disponible  boolean,
  p_producto_id text default null,
  p_precio      integer default null
)
returns table (ok boolean, motivo text)
language plpgsql as $$
declare
  n    text := trim(coalesce(p_nombre, ''));
  prod text := nullif(trim(coalesce(p_producto_id, '')), '');
begin
  if length(n) < 2 and prod is null then
    return query select false, 'Falta el producto'::text; return;
  end if;

  if p_disponible then
    delete from punto_faltantes
     where punto_id = p_punto_id
       and (producto_id = prod or lower(trim(coalesce(nombre,''))) = lower(n));
    if p_precio is not null and p_precio > 0 then
      perform guardar_precio_punto(p_punto_id, n, p_precio, prod);
    end if;
    return query select true, 'Disponible'::text;
  else
    -- El trigger de 12_ se encarga de sacarlo de la lista de precios.
    insert into punto_faltantes (punto_id, producto_id, nombre)
    values (p_punto_id, coalesce(prod, lower(n)), n)
    on conflict (punto_id, producto_id) do nothing;
    return query select true, 'Marcado como que no lo tenes'::text;
  end if;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  4. PUERTAS CERRADAS
-- ─────────────────────────────────────────────────────────────────────
revoke all on function ganancias_punto(uuid)                              from anon, authenticated;
revoke all on function poner_disponible(uuid, text, boolean, text, integer) from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  5. COMPROBACION
-- ─────────────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.views
    where table_name in ('v_kiosco_pedidos','v_kiosco_productos'))   as vistas,
  (select count(*) from pg_proc
    where proname in ('ganancias_punto','poner_disponible'))         as funciones;
-- Esperado: 2, 2
