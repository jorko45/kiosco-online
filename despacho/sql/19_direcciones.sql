-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Direcciones: primera vez, reportes y alerta por cercanía
--  Ejecutar DESPUES de 18_alta_de_kioscos.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  QUE RESUELVE
--  El repartidor llega a una direccion sabiendo lo mismo que sabria un
--  desconocido. Si ahi ya entregamos cuarenta veces sin problema, no lo
--  sabe. Si el mes pasado a un companero le robaron en la esquina,
--  tampoco. Toda la experiencia de la red se pierde entre un viaje y el
--  siguiente.
--
--  TRES SENALES, DISTINTAS ENTRE SI
--
--  1. PRIMERA VEZ  ·  cuantas veces entregamos en esa direccion.
--     Es un hecho, no una opinion. Una direccion con historial es la
--     mejor noticia que puede recibir el repartidor.
--
--  2. REPORTES     ·  lo que los repartidores dejaron escrito de ESA
--     direccion: no existe, nadie atiende, es un pasillo sin timbre,
--     mal trato. Concreto y verificable.
--
--  3. CERCANIA     ·  robos o agresiones reportados cerca, hace poco.
--
--  POR QUE LA CERCANIA ES LA MAS DELICADA
--  Marcar zonas se parece peligrosamente a marcar barrios, y eso deja
--  sin servicio a gente que no hizo nada. Por eso esta senal esta atada
--  corta a proposito:
--
--    · solo cuenta robo y violencia, no "me fue mal"
--    · tienen que ser DOS repartidores distintos, no uno insistiendo
--    · dentro de 400 metros, no "la zona sur"
--    · de los ultimos 90 dias, y CADUCA SOLA
--
--  Ese ultimo punto es el que importa: el aviso se apaga con el tiempo
--  sin que nadie lo levante. Un barrio no queda marcado para siempre
--  porque hubo dos hechos en 2026.
--
--  Los cuatro numeros son parametros. Si te quedan cortos o largos, se
--  cambian en parametros_negocio sin tocar una linea de codigo.
--
--  QUE PASA CON UN AVISO
--  El pedido no se bloquea: se pide que este pagado antes de salir. Es
--  la decision que tomaste y es la mas defendible de las tres, porque
--  protege la plata sin negarle el servicio a nadie. El cliente que
--  paga online compra igual.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════

insert into parametros_negocio (clave, valor, nota) values
  ('zona_alerta_metros', 400,
   'Radio para contar hechos cercanos. Chico a proposito: es una esquina, no un barrio.'),
  ('zona_alerta_dias', 90,
   'Ventana de la alerta por cercania. Al pasar, el aviso se apaga solo.'),
  ('zona_alerta_minimo', 2,
   'Repartidores DISTINTOS que tienen que haber reportado. Uno solo no alcanza.'),
  ('direccion_reportes_minimo', 2,
   'Reportes de la misma direccion para que empiece a avisar.')
on conflict (clave) do nothing;


-- ─────────────────────────────────────────────────────────────────────
--  LO QUE EL REPARTIDOR DEJA ANOTADO
-- ─────────────────────────────────────────────────────────────────────
-- Se guarda la direccion normalizada y no el cliente: lo que se esta
-- describiendo es un lugar, no una persona. Un mismo timbre roto le va
-- a pasar al que viva ahi dentro de dos anos.
create table if not exists direccion_reportes (
  id            bigint generated always as identity primary key,
  direccion     text not null,
  direccion_norm text not null,
  lat           double precision,
  lng           double precision,

  repartidor_id uuid not null references repartidores(id) on delete cascade,
  pedido_id     bigint references pedidos(id) on delete set null,

  tipo          text not null,
  nota          text,
  creado_at     timestamptz not null default now(),

  constraint tipo_reporte check (tipo in (
    'no_existe',      -- la direccion no existe o esta mal escrita
    'nadie_atiende',  -- toque y no salio nadie
    'dificil',        -- pasillo, sin timbre, porton, piso alto sin ascensor
    'mal_trato',      -- me trataron mal
    'inseguro'        -- me senti en peligro
  ))
);

create index if not exists idx_reporte_dir  on direccion_reportes(direccion_norm);
create index if not exists idx_reporte_geo  on direccion_reportes(lat, lng);
create index if not exists idx_reporte_when on direccion_reportes(creado_at desc);

comment on table direccion_reportes is
  'Describe un lugar, no a una persona: por eso se guarda la direccion y no el cliente.';

alter table direccion_reportes enable row level security;
revoke all on direccion_reportes from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  REPORTAR
-- ─────────────────────────────────────────────────────────────────────
create or replace function reportar_direccion(
  p_repartidor_id uuid,
  p_direccion     text,
  p_tipo          text,
  p_nota          text default null,
  p_pedido_id     bigint default null,
  p_lat           double precision default null,
  p_lng           double precision default null
)
returns table (ok boolean, motivo text)
language plpgsql as $$
declare
  dir  text := trim(coalesce(p_direccion, ''));
  ya   integer;
begin
  if length(dir) < 4 then
    return query select false, 'Falta la dirección'::text; return;
  end if;
  if p_tipo not in ('no_existe','nadie_atiende','dificil','mal_trato','inseguro') then
    return query select false, 'Tipo de reporte desconocido'::text; return;
  end if;

  -- Un repartidor no reporta lo mismo dos veces el mismo dia. Sin esto,
  -- alguien enojado puede inflar el contador solo y disparar el aviso
  -- que despues le cambia el checkout al cliente.
  select count(*) into ya
    from direccion_reportes
   where repartidor_id = p_repartidor_id
     and direccion_norm = normalizar_direccion(dir)
     and tipo = p_tipo
     and creado_at > now() - interval '24 hours';
  if ya > 0 then
    return query select true, 'Ya lo habías reportado hoy'::text; return;
  end if;

  insert into direccion_reportes
    (direccion, direccion_norm, lat, lng, repartidor_id, pedido_id, tipo, nota)
  values
    (left(dir, 300), normalizar_direccion(dir), p_lat, p_lng,
     p_repartidor_id, p_pedido_id, p_tipo, left(coalesce(p_nota, ''), 500));

  return query select true, 'Gracias, queda anotado'::text;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  QUE SABEMOS DE ESTA DIRECCION
-- ─────────────────────────────────────────────────────────────────────
-- Devuelve solo lo operativo. No dice quien vive ahi, ni cuanto gasta,
-- ni con que frecuencia pide: eso es del cliente y el repartidor no lo
-- necesita para tocar un timbre.
create or replace function perfil_direccion(
  p_direccion text,
  p_lat       double precision default null,
  p_lng       double precision default null
)
returns table (
  entregas      integer,
  primera_vez   boolean,
  reportes      integer,
  hechos_cerca  integer,
  alerta        boolean,
  avisos        text[]
)
language sql stable as $$
  with
  n as (select normalizar_direccion(coalesce(p_direccion,'')) as dir),

  ent as (
    select count(*)::integer as n
      from pedidos p, n
     where p.estado = 'entregado'
       and normalizar_direccion(p.direccion) = n.dir
  ),

  rep as (
    select
      count(*)::integer                                       as n,
      count(distinct repartidor_id)::integer                   as gente,
      array_agg(distinct tipo)                                 as tipos
      from direccion_reportes r, n
     where r.direccion_norm = n.dir
       and r.creado_at > now() - (param('zona_alerta_dias', 90) || ' days')::interval
  ),

  -- Hechos GRAVES cerca: solo robo y violencia, de repartidores
  -- distintos, adentro del radio y de la ventana. Los tres filtros
  -- juntos son los que evitan que esto se convierta en marcar barrios.
  cerca as (
    select count(distinct i.repartidor_id)::integer as gente
      from incidentes i
     where p_lat is not null and p_lng is not null
       and i.lat is not null and i.lng is not null
       and i.tipo in ('robo','violencia')
       and i.creado_at > now() - (param('zona_alerta_dias', 90) || ' days')::interval
       and distancia_km(i.lat, i.lng, p_lat, p_lng)
           <= param('zona_alerta_metros', 400) / 1000.0
  )

  select
    ent.n,
    ent.n = 0,
    coalesce(rep.n, 0),
    coalesce(cerca.gente, 0),
    -- El aviso se enciende por reportes de la direccion o por hechos
    -- cerca. Cualquiera de los dos alcanza; ninguno solo con un caso.
    (coalesce(rep.gente, 0) >= param('direccion_reportes_minimo', 2)
     or coalesce(cerca.gente, 0) >= param('zona_alerta_minimo', 2)),
    array_remove(array[
      case when ent.n = 0
           then 'Primera vez que entregamos en esta dirección' end,
      case when ent.n >= 5
           then 'Ya entregamos ' || ent.n || ' veces acá, sin problemas' end,
      case when 'no_existe'     = any(rep.tipos) then 'Reportaron que la dirección puede estar mal' end,
      case when 'nadie_atiende' = any(rep.tipos) then 'Reportaron que no atendió nadie' end,
      case when 'dificil'       = any(rep.tipos) then 'Acceso complicado: fijate el timbre y el piso' end,
      case when 'mal_trato'     = any(rep.tipos) then 'Un compañero reportó mal trato acá' end,
      case when 'inseguro'      = any(rep.tipos) then 'Un compañero se sintió inseguro acá' end,
      case when coalesce(cerca.gente,0) >= param('zona_alerta_minimo', 2)
           then cerca.gente || ' compañeros reportaron hechos cerca en los últimos '
                || param('zona_alerta_dias', 90) || ' días · llevá lo justo y cobrá antes de bajar' end
    ], null)
  from ent, rep, cerca;
$$;

comment on function perfil_direccion(text, double precision, double precision) is
  'Solo lo operativo. Quien vive ahi y cuanto gasta no es asunto del repartidor.';


-- ─────────────────────────────────────────────────────────────────────
--  ¿ESTA DIRECCION TIENE QUE PAGAR ANTES?
-- ─────────────────────────────────────────────────────────────────────
-- Lo usa el checkout. Devuelve solo un si/no y un motivo en castellano:
-- el detalle de por que no se le muestra al cliente, porque no le
-- corresponde saber que reporto un repartidor.
create or replace function exige_pago_online(
  p_direccion text,
  p_lat       double precision default null,
  p_lng       double precision default null
)
returns table (exige boolean, motivo text)
language sql stable as $$
  select
    d.alerta,
    case when d.alerta
      then 'Para esta dirección pedimos que el pedido esté pagado antes de salir.'
      else null end
  from perfil_direccion(p_direccion, p_lat, p_lng) d;
$$;


-- ─────────────────────────────────────────────────────────────────────
--  PARA TU CONSOLA
-- ─────────────────────────────────────────────────────────────────────
create or replace view v_direcciones_reportadas
with (security_invoker = true) as
select
  r.direccion_norm,
  max(r.direccion)                                    as direccion,
  count(*)::integer                                   as reportes,
  count(distinct r.repartidor_id)::integer            as repartidores,
  array_agg(distinct r.tipo)                          as tipos,
  max(r.creado_at)                                    as ultimo,
  (select count(*) from pedidos p
    where p.estado = 'entregado'
      and normalizar_direccion(p.direccion) = r.direccion_norm)::integer as entregas_ok
from direccion_reportes r
where r.creado_at > now() - interval '180 days'
group by r.direccion_norm
having count(distinct r.repartidor_id) >= 1
order by count(distinct r.repartidor_id) desc, max(r.creado_at) desc;

revoke all on v_direcciones_reportadas from anon, authenticated;

revoke all on function reportar_direccion(uuid, text, text, text, bigint, double precision, double precision)
  from anon, authenticated;
revoke all on function perfil_direccion(text, double precision, double precision)
  from anon, authenticated;
revoke all on function exige_pago_online(text, double precision, double precision)
  from anon, authenticated;


select
  (select count(*) from information_schema.tables
    where table_name = 'direccion_reportes')                          as tabla,
  (select count(*) from pg_proc
    where proname in ('reportar_direccion','perfil_direccion','exige_pago_online')) as funciones,
  (select count(*) from information_schema.views
    where table_name = 'v_direcciones_reportadas')                    as vista,
  (select count(*) from parametros_negocio
    where clave like 'zona_alerta%' or clave = 'direccion_reportes_minimo') as parametros;
-- Esperado: 1, 3, 1, 4
