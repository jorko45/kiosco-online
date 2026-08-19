-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Alta de repartidores con documentos
--  Ejecutar DESPUES de 19_direcciones.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  LO QUE MANDA EL DERECHO, NO EL DISENO
--
--  Ley 25.326, articulo 7 inciso 4:
--    "Los datos relativos a antecedentes penales o contravencionales
--     solo pueden ser objeto de tratamiento por parte de las autoridades
--     publicas competentes, en el marco de las leyes y reglamentaciones
--     respectivas."
--
--  K24 no es una autoridad publica. Guardar el certificado de
--  antecedentes en esta base seria exactamente lo que ese inciso
--  prohibe, y el archivo guardado seria la prueba en contra el dia que
--  alguien reclame.
--
--  Por eso ese documento se VE y NO SE GUARDA. El repartidor lo muestra,
--  vos lo mirás, y lo unico que queda registrado es que lo miraste: quien
--  verifico, cuando, y hasta cuando vale. Sin archivo, sin numero de
--  certificado, sin nada que describa su contenido.
--
--  Hay un check en la tabla que impide guardar una URL para ese tipo. No
--  esta por desconfianza: esta porque dentro de un ano nadie se va a
--  acordar de esta conversacion, y una linea de codigo bien intencionada
--  puede meter el archivo sin que nadie lo note.
--
--  LOS OTROS TRES SI SE GUARDAN
--  Licencia, tarjeta verde y seguro son datos personales comunes, no
--  sensibles. Se guardan con consentimiento y con fecha de vencimiento,
--  que ademas es donde esta el valor real: un seguro vencido es un
--  problema tuyo, no de el, y el sistema avisa antes de que pase.
--
--  BORRADO AUTOMATICO
--  Articulo 4 inciso 7: los datos "deben ser destruidos cuando hayan
--  dejado de ser necesarios". A los 90 dias de la baja se borran solos.
--  Automatico a proposito: si depende de que alguien se acuerde, no pasa.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════

insert into parametros_negocio (clave, valor, nota) values
  ('repartidor_borrar_dias', 90,
   'Dias despues de la baja en que se borran los documentos. Ley 25.326 art. 4 inc. 7.'),
  ('doc_aviso_dias', 30,
   'Con cuantos dias de anticipacion se avisa que un documento vence.')
on conflict (clave) do nothing;


alter table repartidores add column if not exists estado_alta   text not null default 'aprobado';
alter table repartidores add column if not exists email         text;
alter table repartidores add column if not exists dni           text;
alter table repartidores add column if not exists patente       text;
alter table repartidores add column if not exists baja_at       timestamptz;
alter table repartidores add column if not exists consintio_at  timestamptz;
alter table repartidores add column if not exists motivo_rechazo text;

-- Los que ya existen quedan aprobados: nadie se queda afuera por esto.
update repartidores set estado_alta = 'aprobado' where estado_alta is null;

alter table repartidores drop constraint if exists estado_alta_valido;
alter table repartidores add constraint estado_alta_valido
  check (estado_alta in ('pendiente','aprobado','rechazado','baja'));

comment on column repartidores.consintio_at is
  'Cuando acepto que tratemos sus datos. Sin esto no hay consentimiento y no hay tratamiento licito.';


-- ─────────────────────────────────────────────────────────────────────
--  LOS DOCUMENTOS
-- ─────────────────────────────────────────────────────────────────────
create table if not exists repartidor_docs (
  id            bigint generated always as identity primary key,
  repartidor_id uuid not null references repartidores(id) on delete cascade,

  tipo          text not null,

  -- Donde esta el archivo. Para antecedentes penales tiene que ser NULL:
  -- lo garantiza el check de mas abajo, no la buena memoria de nadie.
  archivo_url   text,

  vence_el      date,
  estado        text not null default 'pendiente',

  verificado_por text,
  verificado_at  timestamptz,
  nota           text,

  subido_at     timestamptz not null default now(),

  constraint tipo_doc check (tipo in (
    'licencia',      -- licencia de conducir
    'tarjeta_verde', -- cedula del vehiculo
    'seguro',        -- poliza vigente
    'antecedentes'   -- se ve y no se guarda
  )),
  constraint estado_doc check (estado in ('pendiente','aprobado','rechazado','vencido')),

  -- El corazon de todo esto. Ley 25.326 art. 7 inc. 4.
  constraint antecedentes_no_se_guardan check (
    tipo <> 'antecedentes' or archivo_url is null
  ),

  unique (repartidor_id, tipo)
);

create index if not exists idx_docs_rep   on repartidor_docs(repartidor_id);
create index if not exists idx_docs_vence on repartidor_docs(vence_el);

comment on constraint antecedentes_no_se_guardan on repartidor_docs is
  'Ley 25.326 art. 7 inc. 4: solo autoridades publicas pueden tratar antecedentes penales.';

alter table repartidor_docs enable row level security;
revoke all on repartidor_docs from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  SE REGISTRA
-- ─────────────────────────────────────────────────────────────────────
create or replace function registrar_repartidor(
  p_nombre    text,
  p_telefono  text,
  p_pin       text,
  p_dni       text default null,
  p_email     text default null,
  p_vehiculo  text default 'moto',
  p_patente   text default null,
  p_consiente boolean default false
)
returns table (ok boolean, repartidor_id uuid, motivo text)
language plpgsql as $$
declare
  tel   text := regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g');
  nom   text := trim(coalesce(p_nombre, ''));
  nuevo uuid;
begin
  if length(nom) < 3 then
    return query select false, null::uuid, 'Poné tu nombre y apellido'::text; return;
  end if;
  if length(tel) < 8 then
    return query select false, null::uuid, 'Poné un teléfono válido'::text; return;
  end if;
  if length(coalesce(p_pin, '')) < 4 then
    return query select false, null::uuid, 'El PIN necesita al menos 4 dígitos'::text; return;
  end if;

  -- Sin consentimiento no se guarda nada. No es un tramite: es la
  -- condicion que hace licito todo lo demas.
  if not p_consiente then
    return query select false, null::uuid,
      'Necesitamos que aceptes cómo vamos a usar tus datos'::text; return;
  end if;

  if exists (select 1 from repartidores where regexp_replace(telefono,'\D','','g') = tel) then
    return query select false, null::uuid,
      'Ya hay una cuenta con ese teléfono. Entrá con tu PIN.'::text; return;
  end if;

  insert into repartidores
    (nombre, telefono, pin_hash, vehiculo, patente, dni, email,
     activo, en_turno, estado_alta, consintio_at)
  values
    (left(nom, 120), tel, crypt(p_pin, gen_salt('bf')),
     coalesce(nullif(p_vehiculo,''), 'moto'),
     nullif(upper(trim(coalesce(p_patente,''))), ''),
     nullif(regexp_replace(coalesce(p_dni,''), '\D', '', 'g'), ''),
     nullif(lower(trim(coalesce(p_email,''))), ''),
     false, false, 'pendiente', now())
  returning id into nuevo;

  -- Los cuatro casilleros, vacios, para que sepa que le falta.
  insert into repartidor_docs (repartidor_id, tipo)
  select nuevo, t from unnest(array['licencia','tarjeta_verde','seguro','antecedentes']) t;

  return query select true, nuevo, 'Listo, ahora cargá tus papeles'::text;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  CARGAR UN DOCUMENTO
-- ─────────────────────────────────────────────────────────────────────
create or replace function cargar_doc(
  p_repartidor_id uuid,
  p_tipo          text,
  p_archivo_url   text default null,
  p_vence_el      date default null
)
returns table (ok boolean, motivo text)
language plpgsql as $$
begin
  if p_tipo not in ('licencia','tarjeta_verde','seguro','antecedentes') then
    return query select false, 'Documento desconocido'::text; return;
  end if;

  -- Se corta acá y con un mensaje que explica por que, para que el que
  -- lea el error entienda la razon y no busque como saltearla.
  if p_tipo = 'antecedentes' and p_archivo_url is not null then
    return query select false,
      'El certificado de antecedentes no se sube: se muestra y queda la constancia de que fue verificado (Ley 25.326, art. 7 inc. 4).'::text;
    return;
  end if;

  if p_tipo <> 'antecedentes' and coalesce(p_archivo_url, '') = '' then
    return query select false, 'Falta el archivo'::text; return;
  end if;

  insert into repartidor_docs (repartidor_id, tipo, archivo_url, vence_el, estado, subido_at)
  values (p_repartidor_id, p_tipo, p_archivo_url, p_vence_el, 'pendiente', now())
  on conflict (repartidor_id, tipo) do update
    set archivo_url    = excluded.archivo_url,
        vence_el       = excluded.vence_el,
        estado         = 'pendiente',   -- si lo cambia, se revisa de nuevo
        verificado_por = null,
        verificado_at  = null,
        subido_at      = now();

  return query select true, 'Cargado, queda a revisión'::text;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  VOS APROBAS
-- ─────────────────────────────────────────────────────────────────────
-- Para antecedentes, esta funcion es el unico registro que va a existir:
-- que vos lo viste, cuando, y hasta cuando vale.
create or replace function verificar_doc(
  p_repartidor_id uuid,
  p_tipo          text,
  p_aprobado      boolean,
  p_quien         text,
  p_vence_el      date default null,
  p_nota          text default null
)
returns table (ok boolean, motivo text)
language plpgsql as $$
begin
  update repartidor_docs
     set estado         = case when p_aprobado then 'aprobado' else 'rechazado' end,
         verificado_por = left(coalesce(p_quien, 'panel'), 80),
         verificado_at  = now(),
         vence_el       = coalesce(p_vence_el, vence_el),
         nota           = left(coalesce(p_nota, ''), 300)
   where repartidor_id = p_repartidor_id and tipo = p_tipo;

  if not found then
    return query select false, 'Ese documento no existe'::text; return;
  end if;
  return query select true, case when p_aprobado then 'Aprobado' else 'Rechazado' end::text;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  ¿PUEDE SALIR A REPARTIR?
-- ─────────────────────────────────────────────────────────────────────
-- Un documento vencido no sirve aunque este aprobado. Se mira la fecha,
-- no el sello: un seguro que vencio ayer es un problema tuyo hoy.
create or replace function repartidor_habilitado(p_repartidor_id uuid)
returns boolean
language sql stable as $$
  select r.activo
     and r.estado_alta = 'aprobado'
     and not exists (
       select 1 from repartidor_docs d
        where d.repartidor_id = r.id
          and (d.estado <> 'aprobado' or (d.vence_el is not null and d.vence_el < current_date))
     )
  from repartidores r
  where r.id = p_repartidor_id;
$$;


create or replace function etiqueta_doc(p_tipo text)
returns text language sql immutable as $$
  select case p_tipo
    when 'licencia'      then 'licencia de conducir'
    when 'tarjeta_verde' then 'tarjeta verde del vehículo'
    when 'seguro'        then 'seguro'
    when 'antecedentes'  then 'certificado de antecedentes'
    else p_tipo end;
$$;


create or replace function que_le_falta_repartidor(p_repartidor_id uuid)
returns table (listo boolean, faltan text[])
language sql stable as $$
  with d as (
    select
      array_remove(array_agg(
        case
          when estado = 'pendiente' and tipo = 'antecedentes'
            then 'Mostranos el certificado de antecedentes para verificarlo'
          when estado = 'pendiente'  then 'Falta cargar: ' || etiqueta_doc(tipo)
          when estado = 'rechazado'  then 'Rechazado: ' || etiqueta_doc(tipo)
               || coalesce(' (' || nullif(nota,'') || ')', '')
          when vence_el is not null and vence_el < current_date
            then 'Vencido: ' || etiqueta_doc(tipo) || ' (venció el ' || to_char(vence_el,'DD/MM/YYYY') || ')'
        end), null) as f
    from repartidor_docs where repartidor_id = p_repartidor_id
  )
  select repartidor_habilitado(p_repartidor_id), coalesce(d.f, array[]::text[]) from d;
$$;


-- ─────────────────────────────────────────────────────────────────────
--  BORRADO AUTOMATICO  ·  Ley 25.326 art. 4 inc. 7
-- ─────────────────────────────────────────────────────────────────────
create or replace function borrar_docs_vencidos()
returns integer
language plpgsql as $$
declare n integer;
begin
  with borrados as (
    delete from repartidor_docs d
     using repartidores r
     where d.repartidor_id = r.id
       and r.baja_at is not null
       and r.baja_at < now() - (param('repartidor_borrar_dias', 90) || ' days')::interval
    returning d.id
  )
  select count(*) into n from borrados;

  -- Del que se fue queda lo minimo para las liquidaciones ya hechas.
  -- Los papeles no: esos ya no son necesarios para nada.
  update repartidores
     set dni = null, email = null, patente = null
   where baja_at is not null
     and baja_at < now() - (param('repartidor_borrar_dias', 90) || ' days')::interval
     and (dni is not null or email is not null or patente is not null);

  return n;
end $$;

comment on function borrar_docs_vencidos() is
  'Automatico a proposito: si depende de que alguien se acuerde, no pasa.';


-- ─────────────────────────────────────────────────────────────────────
--  PARA TU CONSOLA
-- ─────────────────────────────────────────────────────────────────────
create or replace view v_altas_repartidores
with (security_invoker = true) as
select
  r.id, r.nombre, r.telefono, r.dni, r.email, r.vehiculo, r.patente,
  r.estado_alta, r.activo, r.creado_at, r.consintio_at, r.baja_at,
  repartidor_habilitado(r.id)                                as puede_repartir,
  (select count(*) from repartidor_docs d
    where d.repartidor_id = r.id and d.estado = 'aprobado')::integer  as docs_ok,
  (select count(*) from repartidor_docs d
    where d.repartidor_id = r.id and d.estado = 'pendiente')::integer as docs_pendientes,
  (select min(d.vence_el) from repartidor_docs d
    where d.repartidor_id = r.id and d.vence_el is not null)          as primer_vencimiento
from repartidores r
order by (r.estado_alta = 'pendiente') desc, r.creado_at desc;

revoke all on v_altas_repartidores from anon, authenticated;


-- Lo que vence pronto. Un seguro vencido es un problema tuyo, no de el.
create or replace view v_docs_por_vencer
with (security_invoker = true) as
select
  r.nombre, r.telefono, d.tipo, etiqueta_doc(d.tipo) as documento,
  d.vence_el, (d.vence_el - current_date)::integer as dias
from repartidor_docs d
join repartidores r on r.id = d.repartidor_id
where d.vence_el is not null
  and r.activo
  and r.baja_at is null
  and d.vence_el <= current_date + param('doc_aviso_dias', 30)::integer
order by d.vence_el;

revoke all on v_docs_por_vencer from anon, authenticated;


revoke all on function registrar_repartidor(text, text, text, text, text, text, text, boolean)
  from anon, authenticated;
revoke all on function cargar_doc(uuid, text, text, date)              from anon, authenticated;
revoke all on function verificar_doc(uuid, text, boolean, text, date, text) from anon, authenticated;
revoke all on function repartidor_habilitado(uuid)                     from anon, authenticated;
revoke all on function que_le_falta_repartidor(uuid)                   from anon, authenticated;
revoke all on function borrar_docs_vencidos()                          from anon, authenticated;


do $$
begin
  perform cron.schedule('k24-borrar-docs', '30 4 * * *',
                        'select borrar_docs_vencidos()');
exception when others then
  raise notice 'pg_cron no disponible (%). Hay que correr borrar_docs_vencidos() desde el panel.', sqlerrm;
end $$;


select
  (select count(*) from information_schema.tables
    where table_name = 'repartidor_docs')                     as tabla,
  (select count(*) from pg_proc where proname in (
     'registrar_repartidor','cargar_doc','verificar_doc',
     'repartidor_habilitado','que_le_falta_repartidor','borrar_docs_vencidos')) as funciones,
  (select count(*) from information_schema.views
    where table_name in ('v_altas_repartidores','v_docs_por_vencer')) as vistas;
-- Esperado: 1, 6, 2


-- ─────────────────────────────────────────────────────────────────────
--  LA ASIGNACION MIRA LOS PAPELES
-- ─────────────────────────────────────────────────────────────────────
-- Sin esto, todo lo de arriba es decorativo: alguien se registra, no
-- carga nada, prende el turno y le llegan pedidos igual. El unico lugar
-- donde la habilitacion realmente cuenta es aca, en el momento de
-- repartir un pedido.
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
    and repartidor_habilitado(r.id)        -- <- lo que agrega este archivo
    and not exists (
      select 1 from pedidos p2
       where p2.repartidor_id = r.id
         and p2.estado in ('asignado','en_camino')
    );
$$;
revoke all on function repartidores_para_pedido(bigint) from anon, authenticated;
