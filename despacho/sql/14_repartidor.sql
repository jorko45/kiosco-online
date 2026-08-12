-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Etapa 2 · El repartidor
--  Ejecutar DESPUES de 13_promos_al_cobrar.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  QUE SE SUMA
--
--  1. AUXILIO. Un boton que en la calle sirva de algo. Cuatro motivos, y
--     no son intercambiables: un desperfecto se resuelve mandando otra
--     moto; un robo con violencia se resuelve llamando al 911 y sacando
--     al tipo de ahi. Guardar los cuatro en la misma bolsa haria que el
--     grave se pierda entre los leves.
--
--     Se guarda la ubicacion en el momento de apretar. Es el dato que mas
--     importa y el que nadie va a poder dictar por telefono si esta en
--     problemas.
--
--  2. LA PLATA DEL DIA Y DE LA SEMANA. Un repartidor que no sabe cuanto
--     lleva ganado no puede decidir si le conviene seguir. Y uno que no
--     sabe cuanto tiene que rendir, rinde mal.
--
--  3. QUE REPARTIDOR LE QUEDA MAS CERCA AL KIOSCO. Una vez que un kiosco
--     acepta, el viaje arranca ahi, no en la casa del cliente. Elegir por
--     cercania al cliente manda al repartidor a cruzar la ciudad para
--     buscar la mercaderia.
--
--  4. UN PEDIDO NO SE QUEDA COLGADO. Si se le asigna a alguien y no lo
--     agarra, vuelve a la cola en vez de envejecer con el cliente
--     esperando.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────
--  1. PARAMETROS
-- ─────────────────────────────────────────────────────────────────────
insert into parametros_negocio (clave, valor, nota) values
  ('repa_espera_minutos', 5, 'Minutos que tiene un repartidor para agarrar un pedido asignado antes de que vuelva a la cola.')
on conflict (clave) do nothing;


-- ─────────────────────────────────────────────────────────────────────
--  2. AUXILIO
-- ─────────────────────────────────────────────────────────────────────
create table if not exists incidentes (
  id            bigint generated always as identity primary key,
  repartidor_id uuid not null references repartidores(id),
  pedido_id     bigint references pedidos(id) on delete set null,

  tipo          text not null,
  -- Lo que el repartidor escribio, si llego a escribir algo. En un robo
  -- no va a escribir nada, y esta bien: el boton tiene que servir igual.
  detalle       text,

  lat           double precision,
  lng           double precision,

  -- Plata, solo para el pago parcial: cuanto se esperaba y cuanto entro.
  esperaba      integer,
  cobro         integer,

  estado        text not null default 'abierto',
  atendido_at   timestamptz,
  atendido_nota text,
  creado_at     timestamptz not null default now(),

  constraint tipo_incidente check (tipo in ('desperfecto','robo','violencia','pago_parcial')),
  constraint estado_incidente check (estado in ('abierto','atendido','cerrado'))
);

create index if not exists idx_incidentes_abiertos
  on incidentes(creado_at desc) where estado = 'abierto';

comment on table incidentes is
  'Auxilio del repartidor. Un robo y un pinchazo no se miran igual: por eso el tipo.';


create or replace function pedir_auxilio(
  p_repartidor_id uuid,
  p_tipo          text,
  p_detalle       text default null,
  p_pedido_id     bigint default null,
  p_lat           double precision default null,
  p_lng           double precision default null,
  p_esperaba      integer default null,
  p_cobro         integer default null
)
returns table (ok boolean, id bigint, urgente boolean, motivo text)
language plpgsql as $$
declare
  nuevo bigint;
  lat2  double precision := p_lat;
  lng2  double precision := p_lng;
begin
  if p_tipo not in ('desperfecto','robo','violencia','pago_parcial') then
    return query select false, null::bigint, false, 'Motivo invalido'::text; return;
  end if;

  -- Si el celular no pudo dar la ubicacion, se usa la ultima conocida.
  -- Peor es no tener ninguna.
  if lat2 is null or lng2 is null then
    select r.ultima_lat, r.ultima_lng into lat2, lng2
      from repartidores r where r.id = p_repartidor_id;
  end if;

  insert into incidentes (repartidor_id, pedido_id, tipo, detalle, lat, lng, esperaba, cobro)
  values (p_repartidor_id, p_pedido_id, p_tipo, p_detalle, lat2, lng2, p_esperaba, p_cobro)
  returning incidentes.id into nuevo;

  return query select true, nuevo, p_tipo in ('robo','violencia'), 'Aviso enviado'::text;
end $$;


-- Lo que tenes que mirar ya. Ordenado por gravedad, no por hora: un robo
-- de hace diez minutos va antes que un pinchazo de hace dos.
create or replace view v_auxilios
with (security_invoker = true) as
select
  i.id, i.tipo, i.detalle, i.estado,
  r.nombre    as repartidor,
  r.telefono,
  p.codigo    as pedido,
  i.lat, i.lng,
  case when i.lat is not null
       then 'https://maps.google.com/?q=' || i.lat || ',' || i.lng end as mapa,
  i.esperaba, i.cobro,
  coalesce(i.esperaba, 0) - coalesce(i.cobro, 0) as falta,
  i.creado_at,
  extract(epoch from (now() - i.creado_at))::int as segundos
from incidentes i
join repartidores r on r.id = i.repartidor_id
left join pedidos p on p.id = i.pedido_id
where i.estado = 'abierto'
order by
  case i.tipo when 'violencia' then 0 when 'robo' then 1
              when 'pago_parcial' then 2 else 3 end,
  i.creado_at desc;

revoke all on v_auxilios from anon, authenticated;


create or replace function atender_auxilio(p_id bigint, p_nota text default null)
returns boolean language sql as $$
  update incidentes
     set estado = 'atendido', atendido_at = now(), atendido_nota = p_nota
   where id = p_id and estado = 'abierto'
  returning true;
$$;


-- ─────────────────────────────────────────────────────────────────────
--  3. LA PLATA DEL REPARTIDOR
-- ─────────────────────────────────────────────────────────────────────
--  Usa lo COBRADO, no el total del pedido. Si cobro de menos, el que
--  tiene menos en el bolsillo es el, y la rendicion tiene que reflejarlo.
create or replace function ganancias_repartidor(p_repartidor_id uuid)
returns table (
  hoy_entregas     integer,
  hoy_ganado       integer,
  hoy_efectivo     integer,
  hoy_a_rendir     integer,
  semana_entregas  integer,
  semana_ganado    integer
)
language sql stable as $$
  with base as (
    select p.*,
           coalesce(p.cobrado, p.total) as entro,
           (p.entregado_at at time zone 'America/Argentina/Cordoba')::date as dia
      from pedidos p
     where p.repartidor_id = p_repartidor_id
       and p.estado = 'entregado'
  ),
  hoy as (
    select * from base
     where dia = (now() at time zone 'America/Argentina/Cordoba')::date
  ),
  sem as (
    select * from base
     where dia >= ((now() at time zone 'America/Argentina/Cordoba')::date
                   - extract(dow from (now() at time zone 'America/Argentina/Cordoba'))::int)
  )
  select
    (select count(*) from hoy)::integer,
    (select coalesce(sum(pago_repartidor),0) from hoy)::integer,
    (select coalesce(sum(entro) filter (where metodo_pago='efectivo'),0) from hoy)::integer,
    (select coalesce(sum(entro) filter (where metodo_pago='efectivo'),0)
          - coalesce(sum(pago_repartidor),0) from hoy)::integer,
    (select count(*) from sem)::integer,
    (select coalesce(sum(pago_repartidor),0) from sem)::integer;
$$;

comment on function ganancias_repartidor(uuid) is
  'Hoy y la semana. A rendir = efectivo que junto menos lo que se gano.';


-- ─────────────────────────────────────────────────────────────────────
--  4. QUE REPARTIDOR LE QUEDA MAS CERCA AL KIOSCO
-- ─────────────────────────────────────────────────────────────────────
--  El viaje arranca donde esta la mercaderia. Medir contra la casa del
--  cliente manda al repartidor a cruzar la ciudad para ir a buscarla.
create or replace function repartidores_para_pedido(p_pedido_id bigint)
returns table (
  repartidor_id uuid,
  nombre        text,
  km_al_kiosco  numeric,
  km_del_viaje  numeric,
  posicion_de   timestamptz,
  orden         integer
)
language sql stable as $$
  with ped as (
    select p.id, p.lat as clat, p.lng as clng, pp.lat as klat, pp.lng as klng
      from pedidos p
      left join puntos_preparacion pp on pp.id = p.punto_id
     where p.id = p_pedido_id
  )
  select
    r.id, r.nombre,
    round(distancia_km(r.ultima_lat, r.ultima_lng, ped.klat, ped.klng)::numeric, 2),
    round(distancia_km(ped.klat, ped.klng, ped.clat, ped.clng)::numeric, 2),
    r.ultima_pos_at,
    (row_number() over (
       order by coalesce(distancia_km(r.ultima_lat, r.ultima_lng, ped.klat, ped.klng), 999)
    ))::integer
  from repartidores r, ped
  where r.activo and r.en_turno
    and not exists (
      select 1 from pedidos p2
       where p2.repartidor_id = r.id
         and p2.estado in ('asignado','en_camino')
    );
$$;

revoke all on function repartidores_para_pedido(bigint) from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  5. UN PEDIDO NO SE QUEDA COLGADO
-- ─────────────────────────────────────────────────────────────────────
alter table pedidos add column if not exists asignado_vence_at timestamptz;

create or replace function soltar_pedidos_no_agarrados()
returns integer
language plpgsql as $$
declare
  n integer := 0;
begin
  with sueltos as (
    update pedidos
       set repartidor_id = null,
           estado = 'preparando',
           asignado_vence_at = null
     where estado = 'asignado'
       and asignado_vence_at is not null
       and asignado_vence_at <= now()
    returning 1
  )
  select count(*) into n from sueltos;
  return n;
end $$;

comment on function soltar_pedidos_no_agarrados() is
  'El que no lo agarra lo devuelve. Sin esto el pedido envejece con el cliente esperando.';


-- ─────────────────────────────────────────────────────────────────────
--  6. QUE GIRE SOLO
-- ─────────────────────────────────────────────────────────────────────
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('k24_soltar_pedidos')
    where exists (select 1 from cron.job where jobname = 'k24_soltar_pedidos');
  perform cron.schedule('k24_soltar_pedidos', '* * * * *',
    $cron$ select soltar_pedidos_no_agarrados(); $cron$);
  raise notice 'pg_cron: los pedidos no agarrados vuelven a la cola solos';
exception when others then
  raise notice 'pg_cron no disponible (%). Hay que soltarlos desde el panel.', sqlerrm;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  7. PUERTAS CERRADAS
-- ─────────────────────────────────────────────────────────────────────
alter table incidentes enable row level security;
revoke all on incidentes from anon, authenticated;
revoke all on function pedir_auxilio(uuid, text, text, bigint, double precision, double precision, integer, integer)
  from anon, authenticated;
revoke all on function atender_auxilio(bigint, text)          from anon, authenticated;
revoke all on function ganancias_repartidor(uuid)             from anon, authenticated;
revoke all on function soltar_pedidos_no_agarrados()          from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  8. COMPROBACION
-- ─────────────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.tables where table_name = 'incidentes')  as tabla_incidentes,
  (select count(*) from information_schema.views  where table_name = 'v_auxilios')  as vista_auxilios,
  (select count(*) from pg_proc where proname in
     ('pedir_auxilio','ganancias_repartidor','repartidores_para_pedido','soltar_pedidos_no_agarrados')) as funciones,
  (select count(*) from parametros_negocio where clave = 'repa_espera_minutos')     as parametro;
-- Esperado: 1, 1, 4, 1
