-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Sistema de despacho de flota — esquema inicial
--  Ejecutar en Supabase: SQL Editor → New query → pegar todo → Run
--  Es idempotente: se puede correr varias veces sin romper nada.
-- ═══════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ─────────────────────────────────────────────────────────────────────
--  REPARTIDORES
-- ─────────────────────────────────────────────────────────────────────
create table if not exists repartidores (
  id              uuid primary key default gen_random_uuid(),
  nombre          text not null,
  telefono        text not null unique,
  pin_hash        text not null,              -- nunca se guarda el PIN en claro
  activo          boolean not null default true,
  en_turno        boolean not null default false,
  turno_inicio    timestamptz,
  ultima_lat      double precision,
  ultima_lng      double precision,
  ultima_pos_at   timestamptz,
  creado_at       timestamptz not null default now()
);

comment on column repartidores.pin_hash is
  'PIN hasheado con crypt(). Ver funcion crear_repartidor().';

-- ─────────────────────────────────────────────────────────────────────
--  PEDIDOS
-- ─────────────────────────────────────────────────────────────────────
-- Estados y transiciones validas:
--
--   nuevo ─→ confirmado ─→ preparando ─→ asignado ─→ en_camino ─→ entregado
--     │           │             │            │            │
--     └───────────┴─────────────┴────────────┴────────────┴──→ cancelado
--
-- "asignado" significa que tiene repartidor pero todavia no salio del local.
-- "en_camino" es cuando el repartidor marca que retiro el pedido.

create table if not exists pedidos (
  id                bigint generated always as identity primary key,
  codigo            text not null unique,       -- K24-000123, legible por telefono
  token_seguimiento text not null unique default encode(gen_random_bytes(16), 'hex'),
  estado            text not null default 'nuevo',

  -- cliente
  cliente_nombre    text,
  cliente_telefono  text,
  cliente_email     text,

  -- entrega
  direccion         text not null,
  direccion_notas   text,
  lat               double precision,
  lng               double precision,

  -- contenido y plata (todo en pesos enteros, sin centavos)
  items             jsonb not null default '[]'::jsonb,
  subtotal          integer not null default 0,
  envio             integer not null default 0,
  total             integer not null default 0,
  metodo_pago       text,                       -- efectivo | mercadopago | transferencia
  pagado            boolean not null default false,
  mp_payment_id     text,

  -- asignacion
  repartidor_id     uuid references repartidores(id) on delete set null,
  asignado_at       timestamptz,
  retirado_at       timestamptz,
  entregado_at      timestamptz,
  cancelado_at      timestamptz,
  cancelado_motivo  text,

  -- prueba de entrega
  entrega_receptor  text,
  entrega_nota      text,

  creado_at         timestamptz not null default now(),
  actualizado_at    timestamptz not null default now(),

  constraint estado_valido check (estado in
    ('nuevo','confirmado','preparando','asignado','en_camino','entregado','cancelado')),
  constraint metodo_pago_valido check (metodo_pago is null or metodo_pago in
    ('efectivo','mercadopago','transferencia')),
  constraint totales_no_negativos check (subtotal >= 0 and envio >= 0 and total >= 0)
);

create index if not exists idx_pedidos_estado      on pedidos(estado);
create index if not exists idx_pedidos_repartidor  on pedidos(repartidor_id) where repartidor_id is not null;
create index if not exists idx_pedidos_creado      on pedidos(creado_at desc);
create index if not exists idx_pedidos_token       on pedidos(token_seguimiento);
create index if not exists idx_pedidos_activos     on pedidos(creado_at desc)
  where estado not in ('entregado','cancelado');

-- ─────────────────────────────────────────────────────────────────────
--  EVENTOS — auditoria de cada cambio de estado
-- ─────────────────────────────────────────────────────────────────────
-- Sirve para reconstruir que paso con un pedido cuando un cliente reclama,
-- y para medir tiempos reales (cuanto tarda en salir, cuanto en llegar).
create table if not exists pedido_eventos (
  id          bigint generated always as identity primary key,
  pedido_id   bigint not null references pedidos(id) on delete cascade,
  estado_de   text,
  estado_a    text not null,
  actor       text,                    -- 'cliente' | 'panel' | 'repartidor:<uuid>' | 'sistema'
  nota        text,
  creado_at   timestamptz not null default now()
);

create index if not exists idx_eventos_pedido on pedido_eventos(pedido_id, creado_at);

-- ─────────────────────────────────────────────────────────────────────
--  POSICIONES — rastro GPS del repartidor
-- ─────────────────────────────────────────────────────────────────────
-- Tabla que crece rapido. Ver 02_mantenimiento.sql para la limpieza.
create table if not exists posiciones (
  id             bigint generated always as identity primary key,
  repartidor_id  uuid not null references repartidores(id) on delete cascade,
  pedido_id      bigint references pedidos(id) on delete set null,
  lat            double precision not null,
  lng            double precision not null,
  precision_m    real,
  creado_at      timestamptz not null default now()
);

create index if not exists idx_posiciones_pedido on posiciones(pedido_id, creado_at desc);
create index if not exists idx_posiciones_rep    on posiciones(repartidor_id, creado_at desc);

-- ═══════════════════════════════════════════════════════════════════════
--  LOGICA
-- ═══════════════════════════════════════════════════════════════════════

-- ── Codigo legible: K24-000001 ──────────────────────────────────────
create sequence if not exists pedidos_codigo_seq start 1;

create or replace function generar_codigo_pedido()
returns trigger language plpgsql as $$
begin
  if new.codigo is null or new.codigo = '' then
    new.codigo := 'K24-' || lpad(nextval('pedidos_codigo_seq')::text, 6, '0');
  end if;
  return new;
end $$;

drop trigger if exists trg_codigo_pedido on pedidos;
create trigger trg_codigo_pedido
  before insert on pedidos
  for each row execute function generar_codigo_pedido();

-- ── Maquina de estados: rechaza transiciones invalidas ──────────────
-- Sin esto, un bug en la app del repartidor puede marcar como "entregado"
-- un pedido que nunca salio del local, y no queda rastro del error.
create or replace function validar_transicion_pedido()
returns trigger language plpgsql as $$
declare
  permitidas text[];
begin
  new.actualizado_at := now();

  if new.estado = old.estado then
    return new;
  end if;

  permitidas := case old.estado
    when 'nuevo'       then array['confirmado','cancelado']
    when 'confirmado'  then array['preparando','asignado','cancelado']
    when 'preparando'  then array['asignado','cancelado']
    when 'asignado'    then array['en_camino','preparando','cancelado']
    when 'en_camino'   then array['entregado','cancelado']
    when 'entregado'   then array[]::text[]
    when 'cancelado'   then array[]::text[]
    else array[]::text[]
  end;

  if not (new.estado = any(permitidas)) then
    raise exception
      'Transicion invalida: % -> % (pedido %). Permitidas desde %: %',
      old.estado, new.estado, old.codigo, old.estado,
      coalesce(nullif(array_to_string(permitidas, ', '), ''), 'ninguna');
  end if;

  -- No se puede pasar a asignado/en_camino sin repartidor
  if new.estado in ('asignado','en_camino') and new.repartidor_id is null then
    raise exception 'El pedido % no puede pasar a "%" sin repartidor asignado',
      old.codigo, new.estado;
  end if;

  -- Sellos de tiempo automaticos
  if new.estado = 'asignado'  and new.asignado_at  is null then new.asignado_at  := now(); end if;
  if new.estado = 'en_camino' and new.retirado_at  is null then new.retirado_at  := now(); end if;
  if new.estado = 'entregado' and new.entregado_at is null then new.entregado_at := now(); end if;
  if new.estado = 'cancelado' and new.cancelado_at is null then new.cancelado_at := now(); end if;

  new.actualizado_at := now();
  return new;
end $$;

drop trigger if exists trg_transicion_pedido on pedidos;
create trigger trg_transicion_pedido
  before update on pedidos
  for each row execute function validar_transicion_pedido();

-- ── Auditoria automatica ────────────────────────────────────────────
create or replace function registrar_evento_pedido()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    insert into pedido_eventos (pedido_id, estado_de, estado_a, actor)
    values (new.id, null, new.estado, 'cliente');
  elsif new.estado is distinct from old.estado then
    insert into pedido_eventos (pedido_id, estado_de, estado_a, actor, nota)
    values (new.id, old.estado, new.estado,
            coalesce(current_setting('k24.actor', true), 'sistema'),
            case when new.estado = 'cancelado' then new.cancelado_motivo else null end);
  end if;
  return new;
end $$;

drop trigger if exists trg_evento_pedido on pedidos;
create trigger trg_evento_pedido
  after insert or update on pedidos
  for each row execute function registrar_evento_pedido();

-- ── Ultima posicion cacheada en el repartidor ───────────────────────
-- Evita tener que escanear la tabla posiciones para saber donde esta cada uno.
create or replace function actualizar_ultima_posicion()
returns trigger language plpgsql as $$
begin
  update repartidores
     set ultima_lat = new.lat,
         ultima_lng = new.lng,
         ultima_pos_at = new.creado_at
   where id = new.repartidor_id;
  return new;
end $$;

drop trigger if exists trg_ultima_posicion on posiciones;
create trigger trg_ultima_posicion
  after insert on posiciones
  for each row execute function actualizar_ultima_posicion();

-- ── Alta de repartidor con PIN hasheado ─────────────────────────────
create or replace function crear_repartidor(p_nombre text, p_telefono text, p_pin text)
returns uuid language plpgsql security definer as $$
declare v_id uuid;
begin
  if length(p_pin) < 4 then
    raise exception 'El PIN tiene que tener al menos 4 digitos';
  end if;
  insert into repartidores (nombre, telefono, pin_hash)
  values (p_nombre, p_telefono, crypt(p_pin, gen_salt('bf')))
  returning id into v_id;
  return v_id;
end $$;

-- ── Verificacion de PIN ─────────────────────────────────────────────
create or replace function verificar_pin(p_telefono text, p_pin text)
returns table (id uuid, nombre text, en_turno boolean)
language plpgsql security definer as $$
begin
  return query
    select r.id, r.nombre, r.en_turno
      from repartidores r
     where r.telefono = p_telefono
       and r.activo = true
       and r.pin_hash = crypt(p_pin, r.pin_hash);
end $$;

-- ═══════════════════════════════════════════════════════════════════════
--  SEGURIDAD (RLS)
-- ═══════════════════════════════════════════════════════════════════════
-- Regla de oro: el navegador NUNCA habla directo con estas tablas.
-- Todo pasa por las funciones serverless de Vercel, que usan la
-- service_role key (guardada como variable de entorno, jamas en el front).
-- Por eso RLS queda activo y sin politicas permisivas: cualquier intento
-- con la anon key desde el navegador devuelve vacio.

alter table pedidos        enable row level security;
alter table repartidores   enable row level security;
alter table pedido_eventos enable row level security;
alter table posiciones     enable row level security;

-- Sin policies = nadie con anon key lee ni escribe.
-- service_role saltea RLS por diseno.

-- ═══════════════════════════════════════════════════════════════════════
--  VISTAS DE APOYO
-- ═══════════════════════════════════════════════════════════════════════
--
--  ⚠ IMPORTANTE — por que las vistas llevan security_invoker = true
--
--  Por defecto en Postgres una vista se ejecuta con los permisos de SU DUENO,
--  no de quien la consulta. Eso significa que una vista sobre una tabla con
--  RLS activo SALTEA ese RLS: cualquiera con la anon key podria hacer
--  select * from v_cola_despacho y ver todos los pedidos con nombre,
--  telefono y direccion de cada cliente.
--
--  security_invoker = true hace que la vista respete el RLS del que consulta.
--  Ademas revocamos explicitamente el acceso a anon y authenticated.
--  Las dos cosas, por si alguna se pierde en una migracion futura.

-- Cola de despacho: lo que tiene que ver el panel.
create or replace view v_cola_despacho
with (security_invoker = true) as
select
  p.id, p.codigo, p.estado, p.cliente_nombre, p.cliente_telefono,
  p.direccion, p.direccion_notas, p.lat, p.lng,
  p.items, p.subtotal, p.envio, p.total, p.metodo_pago, p.pagado,
  p.repartidor_id, r.nombre as repartidor_nombre,
  p.creado_at, p.asignado_at, p.retirado_at,
  extract(epoch from (now() - p.creado_at))::int as segundos_desde_creado
from pedidos p
left join repartidores r on r.id = p.repartidor_id
where p.estado not in ('entregado','cancelado')
order by p.creado_at asc;

-- Metricas por dia: sirve para saber si la operacion mejora o empeora.
create or replace view v_metricas_dia
with (security_invoker = true) as
select
  date_trunc('day', creado_at)::date              as dia,
  count(*)                                         as pedidos,
  count(*) filter (where estado = 'entregado')     as entregados,
  count(*) filter (where estado = 'cancelado')     as cancelados,
  sum(total) filter (where estado = 'entregado')   as facturado,
  round(avg(extract(epoch from (retirado_at  - creado_at))/60)::numeric, 1) as min_hasta_salir,
  round(avg(extract(epoch from (entregado_at - retirado_at))/60)::numeric, 1) as min_en_calle,
  round(avg(extract(epoch from (entregado_at - creado_at))/60)::numeric, 1)  as min_total
from pedidos
group by 1
order by 1 desc;

-- ── Cierre de permisos ──────────────────────────────────────────────
-- Solo la service_role (usada por las funciones de Vercel) toca estos datos.
revoke all on v_cola_despacho, v_metricas_dia from anon, authenticated;
revoke all on pedidos, repartidores, pedido_eventos, posiciones from anon, authenticated;

-- Las funciones de PIN son security definer: hay que impedir que se llamen
-- desde el navegador con la anon key, o cualquiera puede probar PINes.
revoke all on function crear_repartidor(text, text, text) from anon, authenticated;
revoke all on function verificar_pin(text, text)          from anon, authenticated;
