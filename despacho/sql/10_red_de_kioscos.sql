-- ═══════════════════════════════════════════════════════════════════════
--  K24 · La red de kioscos
--  Ejecutar DESPUES de 09_aviso_cliente.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  QUE RESUELVE
--  Hoy el pedido entra y alguien lo asigna a mano. Con kioscos adheridos
--  eso no escala: el pedido tiene que buscar solo al kiosco mas cercano
--  que este despierto y que tenga lo que el cliente pidio.
--
--  LAS TRES REGLAS DEL NEGOCIO, ESCRITAS UNA SOLA VEZ
--
--  1. EL PEDIDO ES INDIVISIBLE. Si a un kiosco le falta UN item, queda
--     afuera. No se parte entre dos kioscos: seria dos viajes, dos vueltos
--     y dos motivos de queja.
--
--  2. EL MAMI CIERRA LA FILA. Siempre ultimo, sin importar la distancia.
--     Es el unico que nunca rechaza, asi que es la garantia de que el
--     pedido sale. Si el Mami compitiera por cercania, se quedaria con
--     casi todo y la red de kioscos no arrancaria nunca.
--
--  3. EL KIOSCO COBRA 15% MENOS DE LO QUE PAGA EL CLIENTE. Ese 15% sale
--     del subtotal de mercaderia, NO del envio: el envio le paga al
--     repartidor y no es plata del kiosco ni tuya.
--
--  POR QUE FALTANTES Y NO STOCK
--  Pedirle a un kiosquero que cargue 5.000 productos con cantidades es
--  pedirle algo que no va a hacer. Que marque los diez que se le
--  acabaron, si. Entonces el modelo es al reves del habitual: se asume
--  que el kiosco tiene todo, y la excepcion es lo que falta.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────
--  1. PARAMETROS
-- ─────────────────────────────────────────────────────────────────────
insert into parametros_negocio (clave, valor, nota) values
  ('kiosco_comision_pct',   15, 'Porcentaje del subtotal que se queda K24. El kiosco cobra el resto.'),
  ('kiosco_espera_segundos', 120, 'Cuanto espera un kiosco antes de que el pedido pase al siguiente.'),
  ('kiosco_latido_segundos', 90, 'Sin señal por mas de esto, el kiosco se considera desconectado.')
on conflict (clave) do nothing;


-- ─────────────────────────────────────────────────────────────────────
--  2. QUIEN ENTRA AL KIOSCO
-- ─────────────────────────────────────────────────────────────────────
--  Un kiosco no es una persona: es un mostrador donde puede haber varios
--  turnos. Por eso la sesion es del PUNTO, no de un empleado.
alter table puntos_preparacion add column if not exists pin_hash text;
alter table puntos_preparacion add column if not exists usuario  text;

create unique index if not exists idx_punto_usuario
  on puntos_preparacion(lower(usuario)) where usuario is not null;

-- Presencia. No alcanza con "activo": un kiosco puede estar dado de alta,
-- dentro del horario, y con la persiana baja igual. Solo cuenta si su
-- pantalla esta abierta y mandando señal.
alter table puntos_preparacion add column if not exists ultimo_latido timestamptz;
alter table puntos_preparacion add column if not exists online        boolean not null default false;

comment on column puntos_preparacion.online is
  'Lo prende el kiosquero a mano. Se apaga solo si deja de mandar latido.';


create or replace function punto_conectado(p_punto_id uuid)
returns boolean
language sql stable as $$
  select coalesce(
    p.online
    and p.ultimo_latido is not null
    and p.ultimo_latido > now() - (param('kiosco_latido_segundos', 90) || ' seconds')::interval,
  false)
  from puntos_preparacion p where p.id = p_punto_id;
$$;


-- Alta y cambio de clave. El PIN se hashea con bcrypt igual que el de los
-- repartidores: en la base nunca queda el numero, solo el hash.
create or replace function poner_pin_punto(
  p_punto_id uuid,
  p_usuario  text,
  p_pin      text
)
returns table (ok boolean, motivo text)
language plpgsql as $$
declare
  u text := lower(trim(coalesce(p_usuario, '')));
begin
  if u !~ '^[a-z0-9_.\-]{3,30}$' then
    return query select false, 'El usuario va sin espacios, de 3 a 30 letras o numeros'::text; return;
  end if;
  if length(coalesce(p_pin, '')) < 4 then
    return query select false, 'El PIN necesita al menos 4 digitos'::text; return;
  end if;
  if exists (select 1 from puntos_preparacion
              where lower(usuario) = u and id is distinct from p_punto_id) then
    return query select false, 'Ese usuario ya esta tomado por otro punto'::text; return;
  end if;

  update puntos_preparacion
     set usuario  = u,
         pin_hash = crypt(p_pin, gen_salt('bf'))
   where id = p_punto_id;

  if not found then
    return query select false, 'No existe ese punto'::text; return;
  end if;
  return query select true, 'Listo'::text;
end $$;


create or replace function verificar_pin_punto(p_usuario text, p_pin text)
returns table (id uuid, nombre text, tipo text, online boolean)
language sql stable as $$
  select p.id, p.nombre, p.tipo, p.online
    from puntos_preparacion p
   where lower(p.usuario) = lower(trim(coalesce(p_usuario, '')))
     and p.pin_hash is not null
     and p.activo
     and p.pin_hash = crypt(p_pin, p.pin_hash);
$$;


-- El latido. Lo manda la pantalla del kiosco cada tantos segundos: es lo
-- unico que distingue "el kiosco esta abierto" de "alguien dejo la pagina
-- abierta en una compu que ya nadie mira".
create or replace function latido_punto(p_punto_id uuid, p_online boolean default null)
returns table (online boolean, conectado boolean)
language plpgsql as $$
begin
  update puntos_preparacion
     set ultimo_latido = now(),
         online = coalesce(p_online, puntos_preparacion.online)
   where id = p_punto_id;
  return query
    select p.online, punto_conectado(p.id) from puntos_preparacion p where p.id = p_punto_id;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  3. LO QUE NO TIENEN
-- ─────────────────────────────────────────────────────────────────────
create table if not exists punto_faltantes (
  punto_id    uuid not null references puntos_preparacion(id) on delete cascade,
  producto_id text not null,
  nombre      text,                       -- copia, para poder mostrar la lista sin el catalogo
  desde       timestamptz not null default now(),
  primary key (punto_id, producto_id)
);

create index if not exists idx_faltantes_producto on punto_faltantes(producto_id);

comment on table punto_faltantes is
  'Lo que el kiosco NO tiene. Se asume que tiene todo lo demas.';


-- Un faltante viejo es mentira: nadie repone y nadie desmarca. A los 7 dias
-- se limpia solo, y si de verdad sigue faltando el kiosco lo vuelve a marcar
-- la proxima vez que rechace un pedido.
create or replace function limpiar_faltantes_viejos()
returns integer
language sql as $$
  with borrados as (
    delete from punto_faltantes where desde < now() - interval '7 days' returning 1
  ) select count(*)::integer from borrados;
$$;


-- ¿Este punto puede cumplir ESTE pedido entero?
create or replace function punto_tiene_todo(p_punto_id uuid, p_items jsonb)
returns boolean
language sql stable as $$
  select not exists (
    select 1
      from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) it
      join punto_faltantes f
        on f.punto_id = p_punto_id
       and f.producto_id = coalesce(it->>'id', it->>'key', '')
  );
$$;

comment on function punto_tiene_todo(uuid, jsonb) is
  'Indivisible: alcanza UN faltante para que el punto quede afuera.';


-- ─────────────────────────────────────────────────────────────────────
--  4. LA RONDA
-- ─────────────────────────────────────────────────────────────────────
--  Cada intento de asignar el pedido a un punto queda registrado. Sirve
--  para tres cosas: saber a quien le toca ahora, poder mostrarte la
--  cascada en la consola, y tener con que discutir despues si un kiosco
--  dice que nunca le llego nada.
create table if not exists pedido_ofertas (
  id          bigint generated always as identity primary key,
  pedido_id   bigint not null references pedidos(id) on delete cascade,
  punto_id    uuid   not null references puntos_preparacion(id),
  orden       integer not null,           -- 1 = el primero al que se le ofrecio
  ofrecido_at timestamptz not null default now(),
  vence_at    timestamptz not null,
  respuesta   text,                       -- null = esperando
  motivo      text,
  respondido_at timestamptz,

  constraint respuesta_valida check (respuesta is null or respuesta in ('acepto','rechazo','vencio','saltado'))
);

create index if not exists idx_ofertas_pedido on pedido_ofertas(pedido_id, orden);
create index if not exists idx_ofertas_punto  on pedido_ofertas(punto_id)
  where respuesta is null;

-- Un pedido no puede tener dos ofertas abiertas a la vez.
create unique index if not exists idx_una_oferta_abierta
  on pedido_ofertas(pedido_id) where respuesta is null;


-- Plata: cuanto le queda al kiosco y cuanto a K24.
alter table pedidos add column if not exists comision_pct  numeric(5,2);
alter table pedidos add column if not exists pago_al_punto integer;

comment on column pedidos.pago_al_punto is
  'Lo que cobra el kiosco: subtotal menos comision. El envio no entra.';


create or replace function calcular_pago_al_punto(p_pedido_id bigint)
returns integer
language sql stable as $$
  select greatest(0, round(
    (p.subtotal - coalesce(p.descuento, 0))
    * (1 - param('kiosco_comision_pct', 15) / 100.0)
  ))::integer
  from pedidos p where p.id = p_pedido_id;
$$;

comment on function calcular_pago_al_punto(bigint) is
  'Sobre el subtotal de mercaderia. El envio queda afuera: paga al repartidor.';


-- ─────────────────────────────────────────────────────────────────────
--  5. A QUIEN LE TOCA
-- ─────────────────────────────────────────────────────────────────────
--  Devuelve los puntos que PUEDEN tomar este pedido, en orden.
--  Filtra por: activo, conectado, abierto, dentro del radio, y que tenga
--  todos los items. El Mami va ultimo siempre.
create or replace function candidatos_para_pedido(p_pedido_id bigint)
returns table (
  punto_id  uuid,
  nombre    text,
  tipo      text,
  km        numeric,
  orden     integer
)
language sql stable as $$
  with ped as (
    select id, lat, lng, items from pedidos where id = p_pedido_id
  ),
  aptos as (
    select
      p.id, p.nombre, p.tipo,
      round(distancia_km(p.lat, p.lng, ped.lat, ped.lng)::numeric, 2) as km,
      p.prioridad
    from puntos_preparacion p, ped
    where p.activo
      and p.lat is not null and p.lng is not null
      and ped.lat is not null and ped.lng is not null
      and punto_abierto(p.id)
      and punto_tiene_todo(p.id, ped.items)
      -- El Mami no necesita estar "conectado": lo opera tu propio equipo
      -- desde la consola de despacho.
      and (p.tipo = 'mami' or punto_conectado(p.id))
      and distancia_km(p.lat, p.lng, ped.lat, ped.lng) <= p.radio_km
      -- y que no le hayamos ofrecido ya este pedido
      and not exists (
        select 1 from pedido_ofertas o
         where o.pedido_id = p_pedido_id and o.punto_id = p.id
      )
  )
  select id, nombre, tipo, km,
         (row_number() over (
            order by
              case when tipo = 'mami' then 1 else 0 end,   -- el Mami, ultimo
              km - prioridad,                               -- despues, el mas cerca
              nombre
         ))::integer
  from aptos;
$$;


-- ─────────────────────────────────────────────────────────────────────
--  6. OFRECER
-- ─────────────────────────────────────────────────────────────────────
drop function if exists ofrecer_pedido(bigint);

-- OJO CON LOS NOMBRES DE SALIDA.
-- Esta funcion devolvia columnas llamadas punto_id, nombre y vence_at, que
-- son tambien nombres de columnas de las tablas que consulta. Adentro de
-- plpgsql eso es ambiguo y Postgres se planta con "column reference is
-- ambiguous". Por eso las de salida ahora llevan prefijo r_ y adentro se
-- califica todo con el alias de la tabla.
create or replace function ofrecer_pedido(p_pedido_id bigint)
returns table (ok boolean, r_punto_id uuid, r_nombre text, r_vence_at timestamptz, r_motivo text)
language plpgsql as $$
declare
  c      record;
  espera integer := param('kiosco_espera_segundos', 120)::integer;
  v      timestamptz;
begin
  -- Si ya hay una oferta viva, no se toca.
  if exists (select 1 from pedido_ofertas o
              where o.pedido_id = p_pedido_id and o.respuesta is null and o.vence_at > now()) then
    return query
      select true, o.punto_id, pp.nombre, o.vence_at, 'Ya estaba ofrecido'::text
        from pedido_ofertas o join puntos_preparacion pp on pp.id = o.punto_id
       where o.pedido_id = p_pedido_id and o.respuesta is null;
    return;
  end if;

  -- Cerrar la que vencio, si quedo alguna.
  update pedido_ofertas o
     set respuesta = 'vencio', respondido_at = now()
   where o.pedido_id = p_pedido_id and o.respuesta is null and o.vence_at <= now();

  select * into c from candidatos_para_pedido(p_pedido_id) order by orden limit 1;

  if c.punto_id is null then
    return query select false, null::uuid, null::text, null::timestamptz,
      'Ningun punto puede tomarlo: revisar faltantes, horarios y radios'::text;
    return;
  end if;

  v := now() + (espera || ' seconds')::interval;

  insert into pedido_ofertas (pedido_id, punto_id, orden, vence_at)
  values (p_pedido_id, c.punto_id,
          coalesce((select max(o2.orden) from pedido_ofertas o2
                     where o2.pedido_id = p_pedido_id), 0) + 1,
          v);

  return query select true, c.punto_id, c.nombre, v, null::text;
end $$;


create or replace function responder_oferta(
  p_pedido_id bigint,
  p_punto_id  uuid,
  p_respuesta text,
  p_motivo    text default null
)
returns table (ok boolean, motivo text)
language plpgsql as $$
declare
  n integer;
begin
  if p_respuesta not in ('acepto', 'rechazo') then
    return query select false, 'Respuesta invalida'::text; return;
  end if;

  update pedido_ofertas
     set respuesta = p_respuesta, motivo = p_motivo, respondido_at = now()
   where pedido_id = p_pedido_id
     and punto_id  = p_punto_id
     and respuesta is null
     and vence_at > now();
  get diagnostics n = row_count;

  if n = 0 then
    -- No es un error del kiosco: casi siempre es que tardo y ya paso al siguiente.
    return query select false, 'Ese pedido ya no esta esperando tu respuesta'::text; return;
  end if;

  if p_respuesta = 'acepto' then
    update pedidos
       set punto_id = p_punto_id,
           punto_asignado_at = now(),
           estado = case when estado = 'nuevo' then 'confirmado' else estado end,
           comision_pct  = param('kiosco_comision_pct', 15),
           pago_al_punto = calcular_pago_al_punto(p_pedido_id)
     where id = p_pedido_id;
    return query select true, 'Pedido tomado'::text;
  else
    return query select true, 'Pasa al siguiente'::text;
  end if;
end $$;


-- El barrendero. Hace dos cosas, y la segunda es la que importa mas:
--
--   1. cierra las ofertas vencidas y se las pasa al siguiente
--   2. levanta los pedidos que NUNCA salieron a ofrecerse
--
-- El punto 2 no estaba y era un agujero silencioso: un pedido que entra
-- y no encuentra ningun kiosco disponible en ese instante no genera
-- ninguna oferta, y sin fila en pedido_ofertas no habia nada que rotar.
-- Se quedaba quieto para siempre esperando que alguien mirara la consola.
create or replace function rotar_ofertas_vencidas()
returns integer
language plpgsql as $$
declare
  r record;
  n integer := 0;
begin
  for r in
    -- vencidas
    select distinct o.pedido_id as id
      from pedido_ofertas o
      join pedidos p on p.id = o.pedido_id
     where o.respuesta is null
       and o.vence_at <= now()
       and p.estado in ('nuevo','confirmado')
       and p.punto_id is null
    union
    -- nunca ofrecidos: entraron cuando no habia nadie, o fallo el aviso
    select p.id
      from pedidos p
     where p.estado in ('nuevo','confirmado')
       and p.punto_id is null
       and p.lat is not null and p.lng is not null
       and p.creado_at > now() - interval '12 hours'
       and not exists (select 1 from pedido_ofertas o2
                        where o2.pedido_id = p.id and o2.respuesta is null)
  loop
    perform ofrecer_pedido(r.id);
    n := n + 1;
  end loop;
  return n;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  7. LO QUE VE EL KIOSCO
-- ─────────────────────────────────────────────────────────────────────
--  Sin nombre, sin telefono, sin direccion. Solo que juntar, cuanto cobra
--  y cuanto tiempo le queda. Un kiosco adherido le vende a los mismos
--  vecinos: no puede quedarse con tu lista de clientes.
create or replace view v_oferta_para_kiosco
with (security_invoker = true) as
select
  o.pedido_id,
  o.punto_id,
  p.codigo,
  p.items,
  p.subtotal,
  greatest(0, round((p.subtotal - coalesce(p.descuento,0))
    * (1 - param('kiosco_comision_pct', 15) / 100.0)))::integer as vas_a_cobrar,
  o.vence_at,
  greatest(0, extract(epoch from (o.vence_at - now()))::int) as segundos_restantes
from pedido_ofertas o
join pedidos p on p.id = o.pedido_id
where o.respuesta is null
  and o.vence_at > now();

revoke all on v_oferta_para_kiosco from anon, authenticated;


-- Para tu consola: la cascada completa de un pedido.
create or replace view v_cascada
with (security_invoker = true) as
select
  o.pedido_id,
  p.codigo,
  o.orden,
  pp.nombre    as punto,
  pp.tipo,
  o.ofrecido_at,
  o.vence_at,
  o.respuesta,
  o.motivo,
  greatest(0, extract(epoch from (o.vence_at - now()))::int) as segundos_restantes
from pedido_ofertas o
join pedidos p  on p.id = o.pedido_id
join puntos_preparacion pp on pp.id = o.punto_id
order by o.pedido_id desc, o.orden;

revoke all on v_cascada from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  8. PUERTAS CERRADAS
-- ─────────────────────────────────────────────────────────────────────
alter table punto_faltantes enable row level security;
alter table pedido_ofertas  enable row level security;

revoke all on punto_faltantes from anon, authenticated;
revoke all on pedido_ofertas  from anon, authenticated;

revoke all on function candidatos_para_pedido(bigint)      from anon, authenticated;
revoke all on function ofrecer_pedido(bigint)              from anon, authenticated;
revoke all on function responder_oferta(bigint, uuid, text, text) from anon, authenticated;
revoke all on function rotar_ofertas_vencidas()            from anon, authenticated;
revoke all on function punto_tiene_todo(uuid, jsonb)       from anon, authenticated;
revoke all on function calcular_pago_al_punto(bigint)      from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  9. LA RUEDA GIRA SOLA
-- ─────────────────────────────────────────────────────────────────────
--  Sin esto, la unica que empuja la cascada es la consola: si un kiosco
--  rechaza a las 4 de la manana y nadie tiene red.html abierto, el pedido
--  se queda quieto hasta que alguien entre. El cliente esperando y nadie
--  enterado. Con pg_cron la base se encarga sola, una vez por minuto.
--
--  Si la extension no esta disponible, no pasa nada: el bloque avisa y
--  sigue. La consola sigue funcionando como respaldo.
do $$
begin
  create extension if not exists pg_cron;

  -- Si ya estaba programada, se reemplaza.
  perform cron.unschedule('k24_rotar_ofertas')
    where exists (select 1 from cron.job where jobname = 'k24_rotar_ofertas');

  perform cron.schedule(
    'k24_rotar_ofertas',
    '* * * * *',                       -- cada minuto, el minimo que permite cron
    $cron$ select rotar_ofertas_vencidas(); $cron$
  );

  -- Los faltantes viejos mienten: nadie desmarca lo que repuso.
  perform cron.unschedule('k24_limpiar_faltantes')
    where exists (select 1 from cron.job where jobname = 'k24_limpiar_faltantes');

  perform cron.schedule(
    'k24_limpiar_faltantes',
    '17 4 * * *',                      -- 4:17 AM, cuando no hay nadie
    $cron$ select limpiar_faltantes_viejos(); $cron$
  );

  raise notice 'pg_cron listo: la cascada gira sola cada minuto';
exception when others then
  raise notice 'pg_cron no disponible (%). La consola red.html sigue siendo el motor.', sqlerrm;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  10. COMPROBACION
-- ─────────────────────────────────────────────────────────────────────
select
  (select count(*) from parametros_negocio where clave like 'kiosco_%')        as parametros,
  (select count(*) from information_schema.tables
    where table_name in ('punto_faltantes','pedido_ofertas'))                  as tablas_nuevas,
  (select count(*) from information_schema.views
    where table_name in ('v_oferta_para_kiosco','v_cascada'))                  as vistas_nuevas,
  (select count(*) from information_schema.columns
    where table_name = 'puntos_preparacion'
      and column_name in ('pin_hash','usuario','online','ultimo_latido'))      as columnas_punto,
  (select count(*) from information_schema.columns
    where table_name = 'pedidos'
      and column_name in ('comision_pct','pago_al_punto'))                     as columnas_pedido;
-- Esperado: 3, 2, 2, 4, 2
