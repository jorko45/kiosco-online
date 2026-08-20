-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Arreglo: nadie podia registrar su kiosco
--  Ejecutar DESPUES de 21_reemplazos.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  QUE PASABA
--  El alta exigia poder ubicar la direccion en el mapa. Si el
--  geocodificador fallaba una vez, el fracaso quedaba cacheado con
--  encontrada=false, y a partir de ahi geo_buscar devolvia "no se
--  encontro" sin volver a preguntar NUNCA. El kiosquero probaba de nuevo
--  con la misma direccion y recibia el mismo error para siempre.
--
--  Tres errores encadenados y los tres eran mios:
--
--  1. Bloquear el alta por la direccion no hacia falta. punto_listo ya
--     exige lat y lng para recibir pedidos: un kiosco sin ubicar
--     simplemente no recibe nada hasta que se resuelva. Cortarle el
--     registro ademas era redundante, y era lo que lo dejaba afuera.
--
--  2. Cachear el "no encontrado" para siempre. El cache existe para no
--     molestar a Nominatim con la misma consulta, no para grabar en
--     piedra que una direccion no existe. Un fracaso puede ser una caida
--     momentanea del servicio.
--
--  3. Rechazar por cercania a otro kiosco. Dos direcciones distintas que
--     el geocodificador manda a la misma esquina no son el mismo kiosco.
--     Ahora se compara la direccion escrita, que es el dato que el
--     kiosquero controla.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════

insert into parametros_negocio (clave, valor, nota) values
  ('geo_reintentar_horas', 6,
   'Cuantas horas vale un "no encontrado" antes de volver a intentar.')
on conflict (clave) do nothing;


-- ─────────────────────────────────────────────────────────────────────
--  1. EL "NO ENCONTRADO" CADUCA
-- ─────────────────────────────────────────────────────────────────────
-- Un exito se guarda para siempre: la esquina de Colón y Cañada no se
-- muda. Un fracaso vale unas horas: puede haber sido el servicio caido,
-- un timeout, o la direccion escrita a medias y ya corregida.
create or replace function geo_buscar(p_dir text)
returns table (lat double precision, lng double precision, encontrada boolean)
language plpgsql as $$
declare
  v_key   text;
  v_horas integer := param('geo_reintentar_horas', 6);
  v_fila  record;
begin
  v_key := normalizar_direccion(p_dir);

  -- Se LEE primero y se actualiza despues. Al reves no funciona: el
  -- update de ultima_at la deja en now(), y entonces la comparacion de
  -- antiguedad da siempre "reciente". El contador de consultas terminaba
  -- anulando la prueba que decide si hay que reintentar.
  select g.lat, g.lng, g.encontrada, g.ultima_at
    into v_fila
    from geocodificaciones g
   where g.direccion_norm = v_key;

  update geocodificaciones
     set consultas = consultas + 1, ultima_at = now()
   where direccion_norm = v_key;

  if v_fila is null then return; end if;

  -- Un exito vale para siempre: la esquina de Colon y Cañada no se muda.
  -- Un fracaso vale unas horas: puede haber sido el servicio caido.
  if not v_fila.encontrada
     and v_fila.ultima_at <= now() - (v_horas || ' hours')::interval then
    return;
  end if;

  return query select v_fila.lat, v_fila.lng, v_fila.encontrada;
end $$;

comment on function geo_buscar(text) is
  'El cache guarda exitos para siempre y fracasos por unas horas: un fracaso puede haber sido el servicio caido.';


-- Para destrabar a los que ya quedaron marcados como imposibles.
-- Se corre una vez ahora y despues cuando haga falta.
delete from geocodificaciones where not encontrada;


-- ─────────────────────────────────────────────────────────────────────
--  2. EL ALTA NO SE BLOQUEA POR LA DIRECCION
-- ─────────────────────────────────────────────────────────────────────
create or replace function registrar_kiosco(
  p_nombre    text,
  p_direccion text,
  p_lat       double precision,
  p_lng       double precision,
  p_usuario   text,
  p_pin       text,
  p_telefono  text default null,
  p_radio_km  numeric default 5.0
)
returns table (ok boolean, punto_id uuid, motivo text)
language plpgsql as $$
declare
  u     text := lower(trim(coalesce(p_usuario, '')));
  nom   text := trim(coalesce(p_nombre, ''));
  dir   text := trim(coalesce(p_direccion, ''));
  nuevo uuid;
begin
  if length(nom) < 3 then
    return query select false, null::uuid, 'Poné el nombre de tu kiosco'::text; return;
  end if;
  if length(dir) < 6 then
    return query select false, null::uuid, 'Poné la dirección completa'::text; return;
  end if;
  if u !~ '^[a-z0-9_.\-]{3,30}$' then
    return query select false, null::uuid,
      'El usuario va sin espacios ni acentos, de 3 a 30 caracteres'::text; return;
  end if;
  if length(coalesce(p_pin, '')) < 4 then
    return query select false, null::uuid, 'El PIN necesita al menos 4 dígitos'::text; return;
  end if;
  if exists (select 1 from puntos_preparacion where lower(usuario) = u) then
    return query select false, null::uuid, 'Ese usuario ya está tomado'::text; return;
  end if;

  -- Antes se rechazaba por cercania: cualquier kiosco a menos de 50
  -- metros bloqueaba el alta. Dos direcciones distintas que el
  -- geocodificador manda a la misma esquina no son el mismo kiosco, y eso
  -- dejaba afuera a gente que no habia hecho nada.
  --
  -- Ahora se compara la direccion ESCRITA, que es el dato que el
  -- kiosquero controla y el unico que realmente identifica un duplicado.
  if exists (
    select 1 from puntos_preparacion
     where normalizar_direccion(direccion) = normalizar_direccion(dir)
  ) then
    return query select false, null::uuid,
      'Ya hay un kiosco registrado en esa dirección. Si es tuyo, entrá con tu usuario.'::text;
    return;
  end if;

  -- La direccion puede entrar sin coordenadas. No recibe pedidos hasta
  -- tenerlas (punto_listo lo exige), pero puede entrar, cargar sus
  -- precios y trabajar en su cuenta mientras tanto.
  insert into puntos_preparacion
    (nombre, tipo, direccion, lat, lng, telefono, radio_km, activo, online, alta_propia)
  values
    (left(nom, 120), 'kiosco_adherido', left(dir, 300), p_lat, p_lng,
     left(coalesce(p_telefono, ''), 40), greatest(coalesce(p_radio_km, 5), 1), true, false, true)
  returning id into nuevo;

  perform poner_pin_punto(nuevo, u, p_pin);

  insert into punto_horarios (punto_id, dia_semana, desde, hasta)
  select nuevo, d, '00:00'::time, '23:59'::time from generate_series(0, 6) d;

  return query select true, nuevo,
    case when p_lat is null
      then 'Listo. Después ubicá tu kiosco en el mapa para empezar a recibir pedidos.'
      else 'Listo' end::text;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  3. PODER ARREGLAR LA UBICACION DESPUES
-- ─────────────────────────────────────────────────────────────────────
-- Sin esto, un kiosco que entro sin coordenadas queda trabado igual: no
-- tendria como cargarlas nunca.
create or replace function ubicar_punto(
  p_punto_id uuid,
  p_lat      double precision,
  p_lng      double precision,
  p_direccion text default null
)
returns table (ok boolean, motivo text)
language plpgsql as $$
begin
  -- Cordoba Capital y alrededores. Una coordenada de Mendoza no es un
  -- error del kiosquero, es un dato malo que romperia toda la asignacion
  -- por cercania sin que nadie lo note.
  if p_lat is null or p_lng is null
     or p_lat < -31.60 or p_lat > -31.25
     or p_lng < -64.40 or p_lng > -64.00 then
    return query select false,
      'Esa ubicación no está en Córdoba. Probá de nuevo parado en el kiosco.'::text;
    return;
  end if;

  update puntos_preparacion
     set lat = p_lat,
         lng = p_lng,
         direccion = coalesce(nullif(trim(coalesce(p_direccion,'')), ''), direccion)
   where id = p_punto_id;

  if not found then
    return query select false, 'Ese kiosco no existe'::text; return;
  end if;
  return query select true, 'Ubicación guardada'::text;
end $$;


revoke all on function registrar_kiosco(text, text, double precision, double precision, text, text, text, numeric)
  from anon, authenticated;
revoke all on function ubicar_punto(uuid, double precision, double precision, text)
  from anon, authenticated;
revoke all on function geo_buscar(text) from anon, authenticated;


select
  (select count(*) from pg_proc where proname = 'ubicar_punto')          as ubicar,
  (select count(*) from geocodificaciones where not encontrada)          as fracasos_cacheados,
  (select valor from parametros_negocio where clave='geo_reintentar_horas') as horas;
-- Esperado: 1, 0, 6


-- ─────────────────────────────────────────────────────────────────────
--  4. EL LOGIN TIENE QUE DECIR SI EL KIOSCO ESTA UBICADO
-- ─────────────────────────────────────────────────────────────────────
-- Sin esto, la pantalla no puede saber si mostrar el aviso de "ubicá tu
-- kiosco", y se lo mostraria a todos: tambien a los que ya estan
-- ubicados y no tienen nada que arreglar.
drop function if exists verificar_pin_punto(text, text);

create or replace function verificar_pin_punto(p_usuario text, p_pin text)
returns table (
  id uuid, nombre text, tipo text, online boolean,
  lat double precision, lng double precision
)
language sql stable as $$
  select p.id, p.nombre, p.tipo, p.online, p.lat, p.lng
    from puntos_preparacion p
   where lower(p.usuario) = lower(trim(coalesce(p_usuario, '')))
     and p.pin_hash is not null
     and p.activo
     and p.pin_hash = crypt(p_pin, p.pin_hash);
$$;

revoke all on function verificar_pin_punto(text, text) from anon, authenticated;
