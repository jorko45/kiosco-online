-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Reemplazos y acompañamientos
--  Ejecutar DESPUES de 20_alta_de_repartidores.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  EL PEDIDO ES INDIVISIBLE
--  Esa fue la regla desde el principio: si el kiosco no tiene todo, el
--  pedido baja por la cascada hasta el Mami. Funciona, pero tiene un
--  costo: por un Fernet de 750 que no hay, un pedido que el kiosco de la
--  esquina podia entregar en diez minutos termina saliendo del Mami.
--
--  El reemplazo es la valvula. El kiosco dice "no tengo el de 750, tengo
--  el de 1 litro", el cliente acepta, y el pedido se queda en la esquina.
--
--  QUIEN DECIDE
--  Propone el kiosco, acepta el cliente. Es lo mas preciso: el kiosco
--  sabe lo que tiene en la gondola, cosa que ningun algoritmo sabe.
--
--  EL PROBLEMA QUE ESO TRAE, Y COMO SE RESUELVE
--  Si el pedido espera una respuesta, a las 3 AM se queda parado para
--  siempre. Alguien pide, se duerme, y el pedido queda colgado con el
--  kiosco esperando.
--
--  Por eso la propuesta VENCE. Y al vencer no se cancela el pedido ni se
--  manda el reemplazo por las dudas: se SACA el item y se descuenta. Esa
--  es la unica salida que no le cobra a nadie algo que no acepto ni le
--  deja el pedido colgado. El cliente recibe menos de lo que pidio, que
--  es malo, pero es lo menos malo de las tres.
--
--  EL MARGEN
--  Solo se puede proponer algo que cueste entre el 90% y el 110% del
--  original. Fuera de ahi no es un reemplazo, es otra cosa: mandar una
--  botella de 40.000 en lugar de una de 18.000 no le sirve a nadie, y al
--  reves tampoco. El limite lo hace la base, no la buena voluntad del
--  kiosco.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════

insert into parametros_negocio (clave, valor, nota) values
  ('reemplazo_margen_pct', 10,
   'Cuanto puede diferir el precio del reemplazo, para arriba o para abajo.'),
  ('reemplazo_espera_min', 10,
   'Minutos que espera la respuesta del cliente. Al vencer se saca el item y se descuenta.')
on conflict (clave) do nothing;


create table if not exists pedido_reemplazos (
  id           bigint generated always as identity primary key,
  pedido_id    bigint not null references pedidos(id) on delete cascade,
  punto_id     uuid references puntos_preparacion(id) on delete set null,

  -- Lo que pidio
  item_id      text not null,
  item_nombre  text not null,
  item_precio  integer not null,
  cantidad     integer not null default 1,

  -- Lo que ofrece el kiosco
  nuevo_id     text not null,
  nuevo_nombre text not null,
  nuevo_precio integer not null,

  estado       text not null default 'propuesto',
  vence_at     timestamptz not null,
  respondido_at timestamptz,
  creado_at    timestamptz not null default now(),

  constraint estado_reemplazo check (estado in ('propuesto','aceptado','rechazado','vencido'))
);

create index if not exists idx_reemp_pedido on pedido_reemplazos(pedido_id);
create index if not exists idx_reemp_vence  on pedido_reemplazos(vence_at)
  where estado = 'propuesto';

alter table pedido_reemplazos enable row level security;
revoke all on pedido_reemplazos from anon, authenticated;

comment on table pedido_reemplazos is
  'Propone el kiosco, acepta el cliente. Si no contesta, se saca el item: es la salida que no le cobra a nadie algo que no acepto.';


-- ─────────────────────────────────────────────────────────────────────
--  EL KIOSCO PROPONE
-- ─────────────────────────────────────────────────────────────────────
create or replace function proponer_reemplazo(
  p_pedido_id    bigint,
  p_punto_id     uuid,
  p_item_id      text,
  p_nuevo_id     text,
  p_nuevo_nombre text,
  p_nuevo_precio integer
)
returns table (ok boolean, reemplazo_id bigint, motivo text)
language plpgsql as $$
declare
  it     jsonb;
  precio integer;
  cant   integer;
  nom    text;
  margen numeric := param('reemplazo_margen_pct', 10);
  nuevo  bigint;
  est    text;
begin
  select estado into est from pedidos where id = p_pedido_id;
  if est is null then
    return query select false, null::bigint, 'Ese pedido no existe'::text; return;
  end if;
  if est in ('entregado','cancelado') then
    return query select false, null::bigint, 'Ese pedido ya está cerrado'::text; return;
  end if;

  -- Buscar el item dentro del pedido. Se lee del pedido y no de lo que
  -- manda el kiosco: si el precio viniera de afuera, cualquiera podria
  -- decir que el original costaba mas para que el margen le cierre.
  select e into it
    from pedidos p, lateral jsonb_array_elements(p.items) e
   where p.id = p_pedido_id
     and coalesce(e->>'id', e->>'producto_id') = p_item_id
   limit 1;

  if it is null then
    return query select false, null::bigint, 'Ese producto no está en el pedido'::text; return;
  end if;

  precio := coalesce((it->>'price')::integer, (it->>'precio')::integer, 0);
  cant   := coalesce((it->>'qty')::integer, (it->>'cantidad')::integer, 1);
  nom    := coalesce(it->>'name', it->>'nombre', p_item_id);

  if precio <= 0 then
    return query select false, null::bigint, 'No pudimos leer el precio original'::text; return;
  end if;

  -- El limite lo pone la base, no la buena voluntad del kiosco.
  if p_nuevo_precio < precio * (100 - margen) / 100.0
     or p_nuevo_precio > precio * (100 + margen) / 100.0 then
    return query select false, null::bigint,
      ('Ese reemplazo se va del ' || margen || '% permitido. ' ||
       'Tiene que costar entre $' || round(precio * (100-margen)/100.0) ||
       ' y $' || round(precio * (100+margen)/100.0) || '.')::text;
    return;
  end if;

  -- Una propuesta por item a la vez: dos abiertas dejarian al cliente
  -- eligiendo entre cosas que capaz ya no estan.
  update pedido_reemplazos
     set estado = 'rechazado', respondido_at = now()
   where pedido_id = p_pedido_id and item_id = p_item_id and estado = 'propuesto';

  insert into pedido_reemplazos
    (pedido_id, punto_id, item_id, item_nombre, item_precio, cantidad,
     nuevo_id, nuevo_nombre, nuevo_precio, vence_at)
  values
    (p_pedido_id, p_punto_id, p_item_id, nom, precio, cant,
     p_nuevo_id, left(coalesce(p_nuevo_nombre,''), 200), p_nuevo_precio,
     now() + (param('reemplazo_espera_min', 10) || ' minutes')::interval)
  returning id into nuevo;

  return query select true, nuevo, 'Le preguntamos al cliente'::text;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  EL CLIENTE CONTESTA
-- ─────────────────────────────────────────────────────────────────────
-- Se suelta primero porque cambiaron los nombres de las columnas de
-- salida, y PostgreSQL no deja cambiar eso con create or replace.
drop function if exists responder_reemplazo(bigint, boolean);

create or replace function responder_reemplazo(
  p_reemplazo_id bigint,
  p_acepta       boolean
)
-- El nombre de la columna de salida lleva r_ porque "total" tambien es
-- una columna de pedidos, y plpgsql no sabe a cual te referis.
returns table (r_ok boolean, r_total integer, r_motivo text)
language plpgsql as $$
declare
  r      record;
  nuevos jsonb;
  nt     integer;
begin
  select * into r from pedido_reemplazos where id = p_reemplazo_id;
  if r is null then
    return query select false, null::integer, 'Esa propuesta no existe'::text; return;
  end if;
  if r.estado <> 'propuesto' then
    return query select false, null::integer,
      'Esa propuesta ya no está abierta'::text; return;
  end if;
  if r.vence_at < now() then
    return query select false, null::integer,
      'Se venció el tiempo para responder'::text; return;
  end if;

  if p_acepta then
    -- Se cambia el item adentro del pedido, respetando el nombre de campo
    -- que ya traia: el carrito usa name/price/qty y el despacho a veces
    -- nombre/precio/cantidad. Pisar el formato romperia la pantalla.
    select jsonb_agg(
             case when coalesce(e->>'id', e->>'producto_id') = r.item_id
               then e
                    || jsonb_build_object('id', r.nuevo_id)
                    || (case when e ? 'name'  then jsonb_build_object('name',  r.nuevo_nombre)
                             else jsonb_build_object('nombre', r.nuevo_nombre) end)
                    || (case when e ? 'price' then jsonb_build_object('price', r.nuevo_precio)
                             else jsonb_build_object('precio', r.nuevo_precio) end)
                    || jsonb_build_object('reemplazo_de', r.item_nombre)
               else e end)
      into nuevos
      from pedidos p, lateral jsonb_array_elements(p.items) e
     where p.id = r.pedido_id;
  else
    -- Rechaza: se saca el item. No se cancela el pedido entero por una
    -- botella: el resto sirve igual y cancelar todo castiga al cliente
    -- por un faltante que no es suyo.
    select coalesce(jsonb_agg(e) filter (
             where coalesce(e->>'id', e->>'producto_id') <> r.item_id), '[]'::jsonb)
      into nuevos
      from pedidos p, lateral jsonb_array_elements(p.items) e
     where p.id = r.pedido_id;
  end if;

  update pedidos
     set items = nuevos,
         subtotal = (select coalesce(sum(
             coalesce((e->>'price')::integer, (e->>'precio')::integer, 0)
             * coalesce((e->>'qty')::integer, (e->>'cantidad')::integer, 1)
           ), 0) from jsonb_array_elements(nuevos) e)
   where id = r.pedido_id;

  update pedidos
     set total = greatest(0, subtotal + coalesce(envio,0) - coalesce(descuento,0))
   where id = r.pedido_id
  returning pedidos.total into nt;

  update pedido_reemplazos
     set estado = case when p_acepta then 'aceptado' else 'rechazado' end,
         respondido_at = now()
   where id = p_reemplazo_id;

  return query select true, nt,
    case when p_acepta then 'Cambiado' else 'Lo sacamos del pedido' end::text;
end $$;


-- ─────────────────────────────────────────────────────────────────────
--  NADIE CONTESTA
-- ─────────────────────────────────────────────────────────────────────
-- Tres salidas posibles y ninguna es buena:
--   cancelar el pedido    -> castiga al cliente por un faltante ajeno
--   mandar el reemplazo   -> le cobra algo que no acepto
--   sacar el item         -> recibe menos de lo que pidio
-- Se elige la tercera: es la unica donde nadie paga por algo que no
-- eligio y el pedido no queda colgado.
create or replace function vencer_reemplazos()
returns integer
language plpgsql as $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select id from pedido_reemplazos
     where estado = 'propuesto' and vence_at <= now()
  loop
    perform responder_reemplazo_forzado(r.id);
    n := n + 1;
  end loop;
  return n;
end $$;


-- Igual que rechazar, pero sin mirar el vencimiento: es justamente para
-- los vencidos.
create or replace function responder_reemplazo_forzado(p_reemplazo_id bigint)
returns void
language plpgsql as $$
declare
  r      record;
  nuevos jsonb;
begin
  select * into r from pedido_reemplazos where id = p_reemplazo_id;
  if r is null or r.estado <> 'propuesto' then return; end if;

  select coalesce(jsonb_agg(e) filter (
           where coalesce(e->>'id', e->>'producto_id') <> r.item_id), '[]'::jsonb)
    into nuevos
    from pedidos p, lateral jsonb_array_elements(p.items) e
   where p.id = r.pedido_id;

  update pedidos
     set items = nuevos,
         subtotal = (select coalesce(sum(
             coalesce((e->>'price')::integer, (e->>'precio')::integer, 0)
             * coalesce((e->>'qty')::integer, (e->>'cantidad')::integer, 1)
           ), 0) from jsonb_array_elements(nuevos) e)
   where id = r.pedido_id;

  update pedidos
     set total = greatest(0, subtotal + coalesce(envio,0) - coalesce(descuento,0))
   where id = r.pedido_id;

  update pedido_reemplazos
     set estado = 'vencido', respondido_at = now()
   where id = p_reemplazo_id;
end $$;


-- Lo que el cliente tiene que contestar ahora, para su pantalla.
create or replace function reemplazos_abiertos(p_pedido_id bigint)
returns table (
  id bigint, item_nombre text, item_precio integer,
  nuevo_nombre text, nuevo_precio integer,
  diferencia integer, segundos integer
)
language sql stable as $$
  select r.id, r.item_nombre, r.item_precio, r.nuevo_nombre, r.nuevo_precio,
         r.nuevo_precio - r.item_precio,
         greatest(0, extract(epoch from (r.vence_at - now()))::integer)
    from pedido_reemplazos r
   where r.pedido_id = p_pedido_id and r.estado = 'propuesto' and r.vence_at > now();
$$;


-- ═══════════════════════════════════════════════════════════════════════
--  ACOMPAÑAMIENTOS
-- ═══════════════════════════════════════════════════════════════════════
--  "Llevás Fernet, ¿te falta la Coca?"
--
--  Se arma de lo que la gente compra junto de verdad, no de lo que a
--  nosotros nos parece que va junto. Pero hasta que haya pedidos
--  suficientes eso no existe, asi que se pueden cargar pares a mano y
--  conviven: los aprendidos le ganan a los cargados a mano en cuanto
--  hay datos.
-- ═══════════════════════════════════════════════════════════════════════

create table if not exists acompanamientos (
  producto_id  text not null,
  sugerido_id  text not null,
  sugerido_nom text,
  veces        integer not null default 1,
  a_mano       boolean not null default false,
  creado_at    timestamptz not null default now(),
  primary key (producto_id, sugerido_id)
);

alter table acompanamientos enable row level security;
revoke all on acompanamientos from anon, authenticated;


-- Mira los pedidos entregados y cuenta que se compro junto con que.
create or replace function aprender_acompanamientos()
returns integer
language plpgsql as $$
-- Se llama "cuantos" y no "n" porque adentro del CTE hay una columna n,
-- y plpgsql no distingue entre su variable y la columna: da
-- "column reference n is ambiguous".
declare cuantos integer;
begin
  with pares as (
    select
      coalesce(a->>'id', a->>'producto_id') as pa,
      coalesce(b->>'id', b->>'producto_id') as pb,
      coalesce(b->>'name', b->>'nombre')     as nb
    from pedidos p,
         lateral jsonb_array_elements(p.items) a,
         lateral jsonb_array_elements(p.items) b
    where p.estado = 'entregado'
      and p.entregado_at > now() - interval '180 days'
      and coalesce(a->>'id', a->>'producto_id') is distinct from
          coalesce(b->>'id', b->>'producto_id')
  ),
  contados as (
    select pa, pb, max(nb) as nb, count(*)::integer as n
      from pares where pa is not null and pb is not null
     group by pa, pb
  ),
  guardados as (
    insert into acompanamientos (producto_id, sugerido_id, sugerido_nom, veces, a_mano)
    select pa, pb, nb, n, false from contados
    on conflict (producto_id, sugerido_id) do update
      set veces = excluded.veces,
          sugerido_nom = coalesce(nullif(excluded.sugerido_nom,''), acompanamientos.sugerido_nom),
          a_mano = false
    returning 1
  )
  select count(*) into cuantos from guardados;
  return cuantos;
end $$;


-- Que ofrecerle a alguien que ya tiene esto en el carrito.
-- No repite lo que ya lleva: sugerir algo que ya esta en el carrito es
-- la forma mas rapida de que dejen de mirar las sugerencias.
create or replace function sugerir_acompanamientos(p_items jsonb, p_limite integer default 4)
returns table (producto_id text, nombre text, peso integer)
language sql stable as $$
  with tengo as (
    select coalesce(e->>'id', e->>'producto_id') as id
      from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e
  )
  select a.sugerido_id, max(a.sugerido_nom), sum(a.veces)::integer
    from acompanamientos a
   where a.producto_id in (select id from tengo)
     and a.sugerido_id not in (select id from tengo)
   group by a.sugerido_id
   order by sum(a.veces) desc, max(a.sugerido_nom)
   limit greatest(1, coalesce(p_limite, 4));
$$;


revoke all on function proponer_reemplazo(bigint, uuid, text, text, text, integer) from anon, authenticated;
revoke all on function responder_reemplazo(bigint, boolean)      from anon, authenticated;
revoke all on function responder_reemplazo_forzado(bigint)       from anon, authenticated;
revoke all on function vencer_reemplazos()                       from anon, authenticated;
revoke all on function reemplazos_abiertos(bigint)               from anon, authenticated;
revoke all on function aprender_acompanamientos()                from anon, authenticated;
revoke all on function sugerir_acompanamientos(jsonb, integer)   from anon, authenticated;


do $$
begin
  perform cron.schedule('k24-vencer-reemplazos', '* * * * *', 'select vencer_reemplazos()');
  perform cron.schedule('k24-aprender-juntos',  '0 5 * * *',  'select aprender_acompanamientos()');
exception when others then
  raise notice 'pg_cron no disponible (%). vencer_reemplazos() lo tiene que llamar el panel.', sqlerrm;
end $$;


select
  (select count(*) from information_schema.tables
    where table_name in ('pedido_reemplazos','acompanamientos'))   as tablas,
  (select count(*) from pg_proc where proname in (
     'proponer_reemplazo','responder_reemplazo','vencer_reemplazos',
     'reemplazos_abiertos','aprender_acompanamientos','sugerir_acompanamientos')) as funciones;
-- Esperado: 2, 6
