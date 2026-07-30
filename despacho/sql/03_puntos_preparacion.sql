-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Puntos de preparacion (red de nodos)
--  Ejecutar DESPUES de 01_esquema.sql y 02_mantenimiento.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  POR QUE "puntos_preparacion" Y NO "sucursales_mami"
--
--  Hoy los pedidos se arman en sucursales Mami. Manana tambien en kioscos
--  adheridos a la red, y eventualmente en un local propio. Si el modelo
--  dice "sucursal Mami", sumar el primer kiosco obliga a migrar el esquema
--  y a tocar todo el codigo que lo usa.
--
--  Con un unico concepto de "punto de preparacion" y un campo tipo, sumar
--  un kiosco es insertar una fila. Nada mas.
--
--  PRIVACIDAD — regla central de este archivo:
--  Un kiosco adherido es, a la vez, proveedor y competencia: le vende a los
--  mismos vecinos. Por eso un nodo NUNCA ve nombre, telefono ni direccion
--  del cliente. Solo ve que productos juntar. Eso lo garantiza la vista
--  v_pedidos_para_nodo, que es lo unico que puede consultar un nodo.
-- ═══════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────
--  PUNTOS
-- ─────────────────────────────────────────────────────────────────────
create table if not exists puntos_preparacion (
  id            uuid primary key default gen_random_uuid(),
  nombre        text not null,
  tipo          text not null default 'mami',
  direccion     text not null,
  lat           double precision,
  lng           double precision,
  telefono      text,
  contacto      text,

  -- Radio maximo que cubre, en km. Fuera de eso no se le asignan pedidos.
  radio_km      numeric(5,2) not null default 5.0,

  -- Prioridad manual para desempatar: mas alto, se elige antes.
  -- Sirve para favorecer un nodo propio sobre uno de tercero a igual distancia.
  prioridad     integer not null default 0,

  activo        boolean not null default true,
  notas         text,
  creado_at     timestamptz not null default now(),

  constraint tipo_valido check (tipo in ('mami','kiosco_adherido','propio')),
  constraint radio_positivo check (radio_km > 0)
);

create index if not exists idx_puntos_activos on puntos_preparacion(activo) where activo;

-- ─────────────────────────────────────────────────────────────────────
--  HORARIOS
-- ─────────────────────────────────────────────────────────────────────
-- Tabla aparte y no dos columnas en puntos_preparacion, porque:
--   · cada dia puede tener horario distinto (sabados corto, domingos cerrado)
--   · hay turnos partidos (8-13 y 17-21): eso son DOS filas del mismo dia
--   · hay horarios que cruzan medianoche (20:00 a 02:00)
-- Con desde/hasta en la tabla principal nada de esto se puede expresar.
create table if not exists punto_horarios (
  id          bigint generated always as identity primary key,
  punto_id    uuid not null references puntos_preparacion(id) on delete cascade,
  dia_semana  smallint not null,          -- 0=domingo ... 6=sabado (igual que extract(dow))
  desde       time not null,
  hasta       time not null,
  constraint dia_valido check (dia_semana between 0 and 6)
);

create index if not exists idx_horarios_punto on punto_horarios(punto_id, dia_semana);

comment on table punto_horarios is
  'Un tramo por fila. Turno partido = dos filas. Si "hasta" < "desde", el tramo cruza medianoche.';

-- ─────────────────────────────────────────────────────────────────────
--  El pedido ahora tiene ORIGEN, no solo destino
-- ─────────────────────────────────────────────────────────────────────
alter table pedidos add column if not exists punto_id uuid references puntos_preparacion(id);
alter table pedidos add column if not exists punto_asignado_at timestamptz;

create index if not exists idx_pedidos_punto on pedidos(punto_id) where punto_id is not null;

-- ═══════════════════════════════════════════════════════════════════════
--  GEOGRAFIA
-- ═══════════════════════════════════════════════════════════════════════

-- Distancia en km por la formula del haversine.
-- No usamos PostGIS a proposito: para una sola ciudad el error del haversine
-- es de metros, y evitamos una extension que complica backups y migraciones.
create or replace function distancia_km(
  lat1 double precision, lng1 double precision,
  lat2 double precision, lng2 double precision
) returns double precision
language sql immutable parallel safe as $$
  select case
    when lat1 is null or lng1 is null or lat2 is null or lng2 is null then null
    else 6371 * 2 * asin(sqrt(
           power(sin(radians(lat2 - lat1) / 2), 2) +
           cos(radians(lat1)) * cos(radians(lat2)) *
           power(sin(radians(lng2 - lng1) / 2), 2)
         ))
  end;
$$;

-- ¿Esta abierto este punto en este momento?
-- Contempla turnos partidos y tramos que cruzan medianoche.
create or replace function punto_abierto(p_punto_id uuid, p_momento timestamptz default now())
returns boolean language plpgsql stable as $$
declare
  v_dow  smallint;
  v_hora time;
  v_hay  boolean;
begin
  -- Hora local de Cordoba, no UTC: si no, a las 22:00 el sistema cree que son las 01:00.
  v_dow  := extract(dow from (p_momento at time zone 'America/Argentina/Cordoba'))::smallint;
  v_hora := (p_momento at time zone 'America/Argentina/Cordoba')::time;

  select exists (
    select 1 from punto_horarios h
     where h.punto_id = p_punto_id
       and (
         -- tramo normal dentro del mismo dia
         (h.hasta > h.desde and h.dia_semana = v_dow and v_hora >= h.desde and v_hora < h.hasta)
         -- tramo que cruza medianoche: cuenta el final de hoy...
         or (h.hasta < h.desde and h.dia_semana = v_dow and v_hora >= h.desde)
         -- ...y la madrugada del dia siguiente
         or (h.hasta < h.desde and h.dia_semana = (v_dow + 6) % 7 and v_hora < h.hasta)
       )
  ) into v_hay;

  return coalesce(v_hay, false);
end $$;

-- ═══════════════════════════════════════════════════════════════════════
--  ELECCION DE PUNTO
-- ═══════════════════════════════════════════════════════════════════════
--
--  Devuelve los puntos candidatos para un pedido, del mejor al peor.
--  El panel la usa para SUGERIR mientras la asignacion es manual; el dia
--  que se automatice, el sistema toma directamente el primero.
--
--  El costo no es solo "que tan cerca esta el nodo del cliente". Tambien
--  pesa cuanto tiene que ir el repartidor hasta el nodo. Por eso se calculan
--  las dos distancias y se combina.
--
create or replace function puntos_candidatos(
  p_lat            double precision,
  p_lng            double precision,
  p_momento        timestamptz default now(),
  p_repartidor_lat double precision default null,
  p_repartidor_lng double precision default null
)
returns table (
  punto_id        uuid,
  nombre          text,
  tipo            text,
  km_al_cliente   numeric,
  km_del_repartidor numeric,
  costo           numeric,
  abierto         boolean,
  dentro_del_radio boolean
)
language sql stable as $$
  select
    p.id,
    p.nombre,
    p.tipo,
    round(distancia_km(p.lat, p.lng, p_lat, p_lng)::numeric, 2),
    round(distancia_km(p.lat, p.lng, p_repartidor_lat, p_repartidor_lng)::numeric, 2),
    -- Costo = trayecto del pedido + la mitad del reposicionamiento del
    -- repartidor (pesa menos porque ese viaje se hace igual), menos la
    -- prioridad manual expresada en km equivalentes.
    round((
      coalesce(distancia_km(p.lat, p.lng, p_lat, p_lng), 999)
      + coalesce(distancia_km(p.lat, p.lng, p_repartidor_lat, p_repartidor_lng), 0) * 0.5
      - p.prioridad
    )::numeric, 2),
    punto_abierto(p.id, p_momento),
    coalesce(distancia_km(p.lat, p.lng, p_lat, p_lng) <= p.radio_km, false)
  from puntos_preparacion p
  where p.activo
    and p.lat is not null
    and p.lng is not null
  order by
    -- primero los que realmente pueden tomarlo
    punto_abierto(p.id, p_momento) desc,
    coalesce(distancia_km(p.lat, p.lng, p_lat, p_lng) <= p.radio_km, false) desc,
    6 asc;   -- despues por costo
$$;

-- ═══════════════════════════════════════════════════════════════════════
--  VISTA PARA LOS NODOS  ← la pieza critica de privacidad
-- ═══════════════════════════════════════════════════════════════════════
--
--  Esto es TODO lo que un kiosco adherido puede ver de un pedido.
--  No hay nombre, ni telefono, ni direccion, ni email, ni coordenadas,
--  ni el monto que paga el cliente. Solo el codigo y que productos juntar.
--
--  Si algun dia hace falta agregarle una columna, pensarlo dos veces:
--  cada dato que se suma acá es un dato que un competidor tuyo recibe gratis.
--
create or replace view v_pedidos_para_nodo
with (security_invoker = true) as
select
  p.codigo,
  p.punto_id,
  p.estado,
  p.items,
  p.creado_at,
  extract(epoch from (now() - p.creado_at))::int as segundos_esperando
from pedidos p
where p.estado in ('confirmado','preparando','asignado')
  and p.punto_id is not null;

revoke all on v_pedidos_para_nodo from anon, authenticated;
revoke all on puntos_preparacion, punto_horarios from anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════
--  APOYO
-- ═══════════════════════════════════════════════════════════════════════

-- Alta de punto con horario parejo de lunes a domingo (el caso comun).
-- Para horarios distintos por dia, insertar a mano en punto_horarios.
create or replace function crear_punto(
  p_nombre    text,
  p_tipo      text,
  p_direccion text,
  p_lat       double precision,
  p_lng       double precision,
  p_desde     time default '08:00',
  p_hasta     time default '21:00',
  p_radio_km  numeric default 5.0
) returns uuid language plpgsql security definer as $$
declare v_id uuid; d smallint;
begin
  insert into puntos_preparacion (nombre, tipo, direccion, lat, lng, radio_km)
  values (p_nombre, p_tipo, p_direccion, p_lat, p_lng, p_radio_km)
  returning id into v_id;

  for d in 0..6 loop
    insert into punto_horarios (punto_id, dia_semana, desde, hasta)
    values (v_id, d, p_desde, p_hasta);
  end loop;

  return v_id;
end $$;

revoke all on function crear_punto(text,text,text,double precision,double precision,time,time,numeric)
  from anon, authenticated;

-- Que puntos hay abiertos ahora mismo. Util para el panel y para detectar
-- el hueco nocturno: si esto devuelve 0 filas a las 3 AM, no hay con que
-- cumplir un pedido aunque el sitio lo acepte.
create or replace view v_puntos_abiertos
with (security_invoker = true) as
select id, nombre, tipo, direccion, radio_km, prioridad,
       punto_abierto(id) as abierto_ahora
  from puntos_preparacion
 where activo
 order by punto_abierto(id) desc, prioridad desc, nombre;

revoke all on v_puntos_abiertos from anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════
--  CONSULTAS UTILES
-- ═══════════════════════════════════════════════════════════════════════
--
-- Cargar una sucursal:
--   select crear_punto('Mami Nueva Cordoba', 'mami',
--                      'Bv. Chacabuco 500', -31.4290, -64.1880,
--                      '08:00', '22:00', 4.0);
--
-- Cargar un kiosco adherido con horario nocturno que cruza medianoche:
--   select crear_punto('Kiosco El Faro', 'kiosco_adherido',
--                      'Av. Colon 2100', -31.4100, -64.2000,
--                      '18:00', '03:00', 2.5);
--
-- Ver que punto conviene para un pedido:
--   select * from puntos_candidatos(-31.4135, -64.1811);
--
-- ¿Hay alguien abierto ahora?  (si da vacio a la madrugada, ahi esta el hueco)
--   select * from v_puntos_abiertos where abierto_ahora;
--
-- Cerrar un nodo temporalmente sin perder su historial:
--   update puntos_preparacion set activo = false where nombre = 'Kiosco El Faro';
--
-- Rendimiento por nodo, ultimos 30 dias:
--   select pp.nombre, pp.tipo, count(*) as pedidos,
--          round(avg(extract(epoch from (p.retirado_at - p.creado_at))/60)::numeric,1) as min_hasta_listo
--     from pedidos p join puntos_preparacion pp on pp.id = p.punto_id
--    where p.entregado_at > now() - interval '30 days'
--    group by 1,2 order by min_hasta_listo;
