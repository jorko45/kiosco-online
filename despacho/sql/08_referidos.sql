-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Programa de referidos
--  Ejecutar DESPUES de 07_margen_real.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  CÓMO FUNCIONA
--  Cada cliente que compró alguna vez tiene un código (K24-A7B3). Se lo
--  pasa a un amigo; el amigo lo escribe en su primera compra y se lleva
--  un descuento. Cuando esa compra se concreta, al que recomendó le queda
--  un premio para usar en su próximo pedido.
--
--  POR QUÉ ESTO VIVE EN LA BASE Y NO EN EL NAVEGADOR
--  Los envíos gratis se guardan en el localStorage del cliente. Para esa
--  promo alcanza: para hacerse trampa hay que gastar $50.000 igual.
--  Con referidos no alcanza ni cerca — cualquiera abre una ventana de
--  incógnito y se "recomienda" a sí mismo todas las veces que quiera.
--  Por eso el canje se valida acá, contra la tabla de pedidos, que es el
--  único lugar donde el cliente no puede escribir.
--
--  Las tres reglas que hacen que no se pueda abusar:
--    1. El referido tiene que ser un teléfono SIN pedidos previos.
--    2. Nadie puede usar su propio código.
--    3. Un teléfono canjea UN código en su vida (índice único).

-- ─────────────────────────────────────────────────────────────────────
--  1. Los montos, en la tabla de parámetros que ya existe
-- ─────────────────────────────────────────────────────────────────────
insert into parametros_negocio (clave, valor, nota) values
  ('ref_descuento_referido', 3000,  'Descuento para el amigo en su primera compra'),
  ('ref_descuento_dueno',    3000,  'Premio para quien recomendo, cuando el amigo compra'),
  ('ref_minimo_compra',      15000, 'Compra minima para poder usar un codigo de referido')
on conflict (clave) do nothing;

create or replace function param(p_clave text, p_default numeric default 0)
returns numeric language sql stable as $$
  select coalesce((select valor from parametros_negocio where clave = p_clave), p_default);
$$;

-- ─────────────────────────────────────────────────────────────────────
--  2. Normalizacion del telefono
-- ─────────────────────────────────────────────────────────────────────
-- La gente escribe 351 555-1234, +54 9 351 5551234, 3515551234...
-- Todo eso es la misma persona. Guardamos solo los digitos, y nos
-- quedamos con los ultimos 10, que en Argentina identifican la linea
-- sin importar si pusieron el 54, el 9 o el 0.
create or replace function tel_norm(p_tel text)
returns text language sql immutable as $$
  select right(regexp_replace(coalesce(p_tel, ''), '\D', '', 'g'), 10);
$$;

-- ─────────────────────────────────────────────────────────────────────
--  3. Codigos
-- ─────────────────────────────────────────────────────────────────────
create table if not exists referidos (
  id         bigint generated always as identity primary key,
  codigo     text not null unique,
  telefono   text not null unique,        -- ya normalizado
  creado_at  timestamptz not null default now(),
  constraint telefono_valido check (length(telefono) = 10)
);

alter table referidos enable row level security;
revoke all on referidos from anon, authenticated;

-- Alfabeto sin 0/O ni 1/I/L: el codigo se dicta por telefono y por
-- WhatsApp, y esas confusiones generan canjes fallidos.
create or replace function generar_codigo_referido()
returns text language plpgsql as $$
declare
  abc  text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  cod  text;
  i    integer;
begin
  for intento in 1..50 loop
    cod := '';
    for i in 1..4 loop
      cod := cod || substr(abc, 1 + floor(random() * length(abc))::integer, 1);
    end loop;
    cod := 'K24-' || cod;
    if not exists (select 1 from referidos where codigo = cod) then
      return cod;
    end if;
  end loop;
  -- 31^4 = 923.521 combinaciones; llegar aca significa que la tabla
  -- crecio muchisimo. Mejor fallar fuerte que devolver un codigo repetido.
  raise exception 'No se pudo generar un codigo de referido unico';
end $$;

-- Devuelve el codigo del cliente; si no tiene, se lo crea.
-- Solo para telefonos que ya compraron: el codigo es un premio por
-- ser cliente, no algo que cualquiera pueda pedir.
create or replace function codigo_de(p_telefono text)
returns text language plpgsql as $$
declare
  t   text := tel_norm(p_telefono);
  cod text;
begin
  if length(t) <> 10 then
    return null;
  end if;

  select codigo into cod from referidos where telefono = t;
  if cod is not null then
    return cod;
  end if;

  if not exists (
    select 1 from pedidos
     where tel_norm(cliente_telefono) = t
       and estado not in ('cancelado')
  ) then
    return null;   -- todavia no es cliente
  end if;

  cod := generar_codigo_referido();
  insert into referidos (codigo, telefono) values (cod, t)
  on conflict (telefono) do update set codigo = referidos.codigo
  returning codigo into cod;
  return cod;
end $$;

-- ─────────────────────────────────────────────────────────────────────
--  4. Canjes
-- ─────────────────────────────────────────────────────────────────────
create table if not exists referido_canjes (
  id                 bigint generated always as identity primary key,
  codigo             text not null references referidos(codigo) on delete cascade,
  telefono_dueno     text not null,
  telefono_referido  text not null,        -- un canje por telefono, de por vida
  pedido_id          bigint references pedidos(id) on delete set null,
  descuento_referido integer not null default 0,
  descuento_dueno    integer not null default 0,
  premio_usado       boolean not null default false,
  premio_pedido_id   bigint references pedidos(id) on delete set null,
  creado_at          timestamptz not null default now(),
  constraint no_autoreferido check (telefono_dueno <> telefono_referido)
);

create unique index if not exists referido_canjes_tel_unico
  on referido_canjes (telefono_referido);
create index if not exists referido_canjes_dueno
  on referido_canjes (telefono_dueno) where not premio_usado;

alter table referido_canjes enable row level security;
revoke all on referido_canjes from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
--  5. Validacion
-- ─────────────────────────────────────────────────────────────────────
-- Se llama ANTES de crear el pedido, para mostrarle al cliente si el
-- codigo sirve. Devuelve el motivo en castellano para poder mostrarlo tal
-- cual. No modifica nada: validar y canjear son dos pasos separados,
-- porque entre que el cliente escribe el codigo y confirma la compra
-- puede pasar cualquier cosa.
create or replace function validar_referido(
  p_codigo   text,
  p_telefono text,
  p_subtotal integer default 0
)
returns table (ok boolean, descuento integer, motivo text)
language plpgsql stable as $$
declare
  cod    text := upper(trim(coalesce(p_codigo, '')));
  t      text := tel_norm(p_telefono);
  duenio text;
  minimo integer := param('ref_minimo_compra', 15000)::integer;
  desc_  integer := param('ref_descuento_referido', 3000)::integer;
begin
  if cod !~ '^K24-[0-9A-Z]{4}$' then
    return query select false, 0, 'Ese código no existe'; return;
  end if;

  select telefono into duenio from referidos where codigo = cod;
  if duenio is null then
    return query select false, 0, 'Ese código no existe'; return;
  end if;

  if length(t) <> 10 then
    return query select false, 0, 'Necesitamos tu teléfono para validar el código'; return;
  end if;

  if duenio = t then
    return query select false, 0, 'No podés usar tu propio código'; return;
  end if;

  if exists (select 1 from referido_canjes where telefono_referido = t) then
    return query select false, 0, 'Ya usaste un código de referido antes'; return;
  end if;

  if exists (
    select 1 from pedidos
     where tel_norm(cliente_telefono) = t
       and estado not in ('cancelado')
  ) then
    return query select false, 0, 'Los códigos son solo para la primera compra'; return;
  end if;

  if coalesce(p_subtotal, 0) < minimo then
    return query select false, 0,
      'El código se usa en compras desde $' || to_char(minimo, 'FM999G999');
    return;
  end if;

  return query select true, desc_, 'Descuento aplicado'::text;
end $$;

-- ─────────────────────────────────────────────────────────────────────
--  6. Canje
-- ─────────────────────────────────────────────────────────────────────
-- Se llama DESPUES de crear el pedido, con el id ya en la mano.
-- Vuelve a validar todo: entre la validacion y el canje pudo entrar
-- otro pedido del mismo telefono.
create or replace function canjear_referido(
  p_codigo    text,
  p_telefono  text,
  p_pedido_id bigint
)
returns table (ok boolean, descuento integer, motivo text)
language plpgsql as $$
declare
  cod    text := upper(trim(coalesce(p_codigo, '')));
  t      text := tel_norm(p_telefono);
  duenio text;
  sub    integer;
  v      record;
begin
  select subtotal into sub from pedidos where id = p_pedido_id;
  select * into v from validar_referido(cod, t, coalesce(sub, 0));
  if not v.ok then
    return query select false, 0, v.motivo; return;
  end if;

  select telefono into duenio from referidos where codigo = cod;

  insert into referido_canjes (
    codigo, telefono_dueno, telefono_referido, pedido_id,
    descuento_referido, descuento_dueno
  ) values (
    cod, duenio, t, p_pedido_id,
    param('ref_descuento_referido', 3000)::integer,
    param('ref_descuento_dueno', 3000)::integer
  )
  -- Si dos pedidos del mismo telefono entran a la vez, el indice unico
  -- deja pasar uno solo. Sin esto la segunda llamada tiraria excepcion.
  on conflict (telefono_referido) do nothing;

  if not found then
    return query select false, 0, 'Ya usaste un código de referido antes'; return;
  end if;

  return query select true, param('ref_descuento_referido', 3000)::integer, 'Descuento aplicado'::text;
end $$;

-- ─────────────────────────────────────────────────────────────────────
--  7. El premio de quien recomendo
-- ─────────────────────────────────────────────────────────────────────
-- Cuantos premios sin usar tiene. Solo cuentan los referidos cuyo pedido
-- llego a entregado: si le regalaramos el premio al confirmar, bastaria
-- con pedir y cancelar para fabricar descuentos.
create or replace function premios_de(p_telefono text)
returns integer language sql stable as $$
  select count(*)::integer
    from referido_canjes c
    join pedidos p on p.id = c.pedido_id
   where c.telefono_dueno = tel_norm(p_telefono)
     and not c.premio_usado
     and p.estado = 'entregado';
$$;

-- Consume un premio y lo ata al pedido donde se uso.
create or replace function usar_premio(p_telefono text, p_pedido_id bigint)
returns integer language plpgsql as $$
declare
  id_canje bigint;
  monto    integer;
begin
  select c.id, c.descuento_dueno into id_canje, monto
    from referido_canjes c
    join pedidos p on p.id = c.pedido_id
   where c.telefono_dueno = tel_norm(p_telefono)
     and not c.premio_usado
     and p.estado = 'entregado'
   order by c.creado_at
   limit 1
   for update of c skip locked;

  if id_canje is null then
    return 0;
  end if;

  update referido_canjes
     set premio_usado = true, premio_pedido_id = p_pedido_id
   where id = id_canje;

  return coalesce(monto, 0);
end $$;

-- ─────────────────────────────────────────────────────────────────────
--  8. El pedido guarda el descuento
-- ─────────────────────────────────────────────────────────────────────
-- Va en su propia columna y no restado del subtotal, porque el subtotal
-- tiene que seguir siendo lo que valia la mercaderia: es la base con la
-- que se calcula la ganancia. Si el descuento se escondiera ahi adentro,
-- v_rentabilidad diria que vendiste menos, en vez de decir que gastaste
-- en promociones.
alter table pedidos add column if not exists descuento       integer not null default 0;
alter table pedidos add column if not exists referido_codigo text;

alter table pedidos drop constraint if exists descuento_razonable;
alter table pedidos add constraint descuento_razonable
  check (descuento >= 0 and descuento <= subtotal + envio);

comment on column pedidos.descuento is
  'Descuentos aplicados (referidos). El total ya viene neto.';

-- La contribucion tiene que restar el descuento: es plata que no entro.
drop view if exists v_rentabilidad;

create view v_rentabilidad
with (security_invoker = true) as
select
  p.codigo,
  p.entregado_at,
  p.metodo_pago,
  p.subtotal                                          as productos,
  ganancia_mercaderia(p.subtotal, p.metodo_pago)      as ganancia_mercaderia,
  p.envio                                             as envio_cobrado,
  coalesce(p.pago_repartidor, 0)                      as pago_repartidor,
  (p.envio - coalesce(p.pago_repartidor, 0))          as resultado_envio,
  coalesce(p.descuento, 0)                            as descuento,
  (ganancia_mercaderia(p.subtotal, p.metodo_pago)
     + p.envio - coalesce(p.pago_repartidor, 0)
     - coalesce(p.descuento, 0))                      as contribucion,
  (p.envio = 0)                                       as fue_envio_gratis,
  (coalesce(p.referido_codigo, '') <> '')             as fue_referido,
  r.nombre                                            as repartidor,
  r.vehiculo
from pedidos p
left join repartidores r on r.id = p.repartidor_id
where p.estado = 'entregado';

revoke all on v_rentabilidad from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
--  9. Resumen para mostrarle al cliente
-- ─────────────────────────────────────────────────────────────────────
create or replace function resumen_referidos(p_telefono text)
returns table (
  codigo          text,
  amigos_totales  integer,
  amigos_pagados  integer,
  premios_libres  integer,
  ganado_total    integer
)
language sql stable as $$
  with t as (select tel_norm(p_telefono) as tel)
  select
    (select r.codigo from referidos r, t where r.telefono = t.tel),
    (select count(*)::integer from referido_canjes c, t where c.telefono_dueno = t.tel),
    (select count(*)::integer from referido_canjes c join pedidos p on p.id = c.pedido_id, t
      where c.telefono_dueno = t.tel and p.estado = 'entregado'),
    (select premios_de(p_telefono)),
    (select coalesce(sum(c.descuento_dueno), 0)::integer
       from referido_canjes c, t
      where c.telefono_dueno = t.tel and c.premio_usado);
$$;

revoke all on function param(text, numeric)                     from anon, authenticated;
revoke all on function codigo_de(text)                          from anon, authenticated;
revoke all on function validar_referido(text, text, integer)    from anon, authenticated;
revoke all on function canjear_referido(text, text, bigint)     from anon, authenticated;
revoke all on function premios_de(text)                         from anon, authenticated;
revoke all on function usar_premio(text, bigint)                from anon, authenticated;
revoke all on function resumen_referidos(text)                  from anon, authenticated;
revoke all on function generar_codigo_referido()                from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
--  Consultas utiles
-- ─────────────────────────────────────────────────────────────────────
--
-- Como viene el programa:
--   select count(*) filter (where true)                         as canjes,
--          count(*) filter (where premio_usado)                 as premios_cobrados,
--          sum(descuento_referido + descuento_dueno)            as costo_total
--     from referido_canjes;
--
-- Quienes mas recomiendan:
--   select telefono_dueno, count(*) as amigos
--     from referido_canjes group by 1 order by 2 desc limit 10;
--
-- Cambiar los montos (no toca los canjes ya hechos):
--   update parametros_negocio set valor = 4000, desde = now()
--    where clave = 'ref_descuento_referido';
