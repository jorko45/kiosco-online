-- ═══════════════════════════════════════════════════════════════════════
--  K24 · La lista de precios de cada kiosco
--  Ejecutar DESPUES de 10_red_de_kioscos.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  PARA QUE
--  Cada kiosco carga a cuanto vende en su mostrador. Con eso, y sabiendo
--  lo que nos cuesta a nosotros, se puede leer quien compra bien y quien
--  compra mal:
--
--    · vende barato  → compra barato → preguntarle a quien le compra, y
--                      ver si nos conviene comprar ahi a nosotros
--    · vende caro    → compra caro   → ofrecerle nosotros la mercaderia,
--                      que para el es ahorro y para nosotros volumen
--
--  POR QUE EL PRECIO DE MOSTRADOR Y NO EL COSTO
--  El costo es el dato que un comerciante no le da a nadie, y menos a
--  alguien que le vende a sus mismos vecinos. El precio de mostrador esta
--  pegado en la vidriera: pedirlo no incomoda. Y para lo que necesitamos
--  alcanza, porque lo que importa es la comparacion entre kioscos, no el
--  numero exacto.
--
--  ESTA LISTA NO CAMBIA NINGUN PRECIO DE k24hs.com.
--  El sitio tiene un precio y uno solo. Esto es para negociar y decidir,
--  no para cotizar. Si algun dia se usara para cotizar, el mismo producto
--  costaria distinto segun quien este abierto, y eso no se le explica a
--  ningun cliente.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────
--  1. LA LISTA
-- ─────────────────────────────────────────────────────────────────────
create table if not exists punto_precios (
  id            bigint generated always as identity primary key,
  punto_id      uuid not null references puntos_preparacion(id) on delete cascade,

  -- Como lo escribio el kiosquero. Es lo que se muestra y lo que se usa
  -- para cruzar contra nuestro catalogo por nombre.
  nombre        text not null,

  -- Si se pudo emparejar con un producto nuestro, queda anotado. Puede
  -- ser null: hay cosas que ellos venden y nosotros no, y esas son
  -- justamente las mas interesantes.
  producto_id   text,

  precio        integer not null,
  actualizado_at timestamptz not null default now(),

  constraint precio_positivo check (precio > 0),
  constraint nombre_no_vacio check (length(trim(nombre)) > 1)
);

-- Un producto una vez por kiosco. Si lo vuelve a cargar, se pisa el precio.
create unique index if not exists idx_precio_unico
  on punto_precios(punto_id, lower(trim(nombre)));

create index if not exists idx_precios_producto on punto_precios(producto_id)
  where producto_id is not null;

comment on table punto_precios is
  'A cuanto vende cada kiosco en su mostrador. NO afecta el precio de k24hs.com.';


-- ─────────────────────────────────────────────────────────────────────
--  2. LO QUE PROPONEN
-- ─────────────────────────────────────────────────────────────────────
--  Un kiosquero sabe cosas que nosotros no: que le piden y no tiene, que
--  se vende solo, que quedo parado. Sin un lugar donde anotarlo, eso se
--  pierde en una conversacion de WhatsApp que nadie vuelve a leer.
create table if not exists punto_sugerencias (
  id         bigint generated always as identity primary key,
  punto_id   uuid not null references puntos_preparacion(id) on delete cascade,
  tipo       text not null,
  nombre     text not null,
  precio     integer,
  nota       text,
  estado     text not null default 'nueva',
  creado_at  timestamptz not null default now(),

  constraint tipo_sug_valido check (tipo in ('falta_en_catalogo','para_oferta','otro')),
  constraint estado_sug_valido check (estado in ('nueva','vista','aplicada','descartada'))
);

create index if not exists idx_sug_abiertas on punto_sugerencias(estado, creado_at desc);


-- ─────────────────────────────────────────────────────────────────────
--  3. CARGAR
-- ─────────────────────────────────────────────────────────────────────
create or replace function guardar_precio_punto(
  p_punto_id    uuid,
  p_nombre      text,
  p_precio      integer,
  p_producto_id text default null
)
returns table (ok boolean, motivo text)
language plpgsql as $$
declare
  n text := trim(coalesce(p_nombre, ''));
begin
  if length(n) < 2 then
    return query select false, 'Escribi el nombre del producto'::text; return;
  end if;
  if coalesce(p_precio, 0) <= 0 then
    return query select false, 'El precio tiene que ser mayor a cero'::text; return;
  end if;

  insert into punto_precios (punto_id, nombre, precio, producto_id)
  values (p_punto_id, n, p_precio, nullif(trim(coalesce(p_producto_id, '')), ''))
  on conflict (punto_id, lower(trim(nombre))) do update
    set precio = excluded.precio,
        producto_id = coalesce(excluded.producto_id, punto_precios.producto_id),
        actualizado_at = now();

  return query select true, 'Guardado'::text;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  4. LEER
-- ─────────────────────────────────────────────────────────────────────
--  La comparacion contra NUESTRO precio no se hace aca a proposito: el
--  catalogo de k24hs.com no vive en esta base, vive en la planilla y en
--  el sitio. Duplicarlo seria condenarse a que las dos copias se separen.
--  La consola cruza estos datos contra /api/precios en el navegador.
create or replace view v_precios_red
with (security_invoker = true) as
select
  pp.id,
  pp.punto_id,
  p.nombre  as punto,
  p.tipo    as punto_tipo,
  pp.nombre as producto,
  pp.producto_id,
  pp.precio,
  pp.actualizado_at,
  -- Cuantos kioscos cargaron este mismo producto, y donde queda este
  -- respecto de los demas. Es la lectura que importa: no el precio suelto
  -- sino quien esta caro y quien barato dentro de la red.
  count(*)  over (partition by lower(trim(pp.nombre))) as cuantos_lo_venden,
  min(pp.precio) over (partition by lower(trim(pp.nombre))) as mas_barato_de_la_red,
  max(pp.precio) over (partition by lower(trim(pp.nombre))) as mas_caro_de_la_red,
  round(avg(pp.precio) over (partition by lower(trim(pp.nombre))))::integer as promedio_de_la_red
from punto_precios pp
join puntos_preparacion p on p.id = pp.punto_id;

revoke all on v_precios_red from anon, authenticated;


-- Resumen por kiosco: ¿este compra bien o compra mal?
--  Se mide contra el resto de la red, no contra un costo teorico. Si un
--  kiosco esta sistematicamente arriba del promedio, o compra mal o tiene
--  el margen mas alto; en los dos casos hay algo para conversar.
create or replace view v_kiosco_competitividad
with (security_invoker = true) as
select
  punto_id,
  punto,
  count(*)                                             as productos_cargados,
  count(*) filter (where precio = mas_barato_de_la_red
                     and cuantos_lo_venden > 1)        as veces_mas_barato,
  count(*) filter (where precio = mas_caro_de_la_red
                     and cuantos_lo_venden > 1)        as veces_mas_caro,
  round(avg(case when cuantos_lo_venden > 1
                 then 100.0 * (precio - promedio_de_la_red) / nullif(promedio_de_la_red, 0)
            end), 1)                                   as desvio_pct,
  max(actualizado_at)                                  as ultima_carga
from v_precios_red
group by punto_id, punto;

revoke all on v_kiosco_competitividad from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  5. PUERTAS CERRADAS
-- ─────────────────────────────────────────────────────────────────────
alter table punto_precios     enable row level security;
alter table punto_sugerencias enable row level security;

revoke all on punto_precios     from anon, authenticated;
revoke all on punto_sugerencias from anon, authenticated;
revoke all on function guardar_precio_punto(uuid, text, integer, text) from anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────
--  6. COMPROBACION
-- ─────────────────────────────────────────────────────────────────────
select
  (select count(*) from information_schema.tables
    where table_name in ('punto_precios','punto_sugerencias'))        as tablas,
  (select count(*) from information_schema.views
    where table_name in ('v_precios_red','v_kiosco_competitividad'))  as vistas;
-- Esperado: 2, 2
