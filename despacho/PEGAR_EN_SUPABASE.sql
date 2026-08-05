-- ═══════════════════════════════════════════════════════════════════════
--  PEGAR ESTO EN EL EDITOR SQL DE SUPABASE Y APRETAR RUN
--
--  Son dos cosas:
--    1. El arreglo del canje de referidos (obligatorio)
--    2. La limpieza de los pedidos de prueba (opcional pero conviene)
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════


-- ── 1. ARREGLO ────────────────────────────────────────────────────────
--
--  QUE PASABA
--  El descuento nunca se aplicaba, aunque la pantalla dijera que si.
--
--  La validacion corre dos veces: antes de crear el pedido (para avisarle
--  al cliente que el codigo sirve) y despues de crearlo, para consumirlo
--  —esa segunda pasada necesita el id del pedido—. En la segunda vuelta el
--  pedido que ibamos a descontar YA EXISTIA, asi que la regla "el telefono
--  no puede tener pedidos previos" lo bloqueaba a si mismo.
--
--  La red de seguridad funciono (el pedido se corrigio solo y no se regalo
--  nada), pero la regla estaba mal escrita. Ahora se excluye el pedido en
--  curso; para todos los demas la regla sigue igual de estricta.

drop function if exists validar_referido(text, text, integer);

create or replace function validar_referido(
  p_codigo   text,
  p_telefono text,
  p_subtotal integer default 0,
  p_excluir_pedido bigint default null
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
       and id is distinct from p_excluir_pedido
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
  -- Se excluye este pedido: si no, se bloquea a si mismo.
  select * into v from validar_referido(cod, t, coalesce(sub, 0), p_pedido_id);
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
  on conflict (telefono_referido) do nothing;

  if not found then
    return query select false, 0, 'Ya usaste un código de referido antes'; return;
  end if;

  return query select true, param('ref_descuento_referido', 3000)::integer, 'Descuento aplicado'::text;
end $$;

revoke all on function validar_referido(text, text, integer, bigint) from anon, authenticated;


-- ── 2. LIMPIEZA DE LAS PRUEBAS ────────────────────────────────────────
--  Las pruebas crearon pedidos a nombre de "PRUEBA REFERIDOS - BORRAR"
--  con los telefonos 3519900001/2/3. Esto los borra junto con sus canjes
--  y codigos, para que no te ensucien el panel ni los reportes.

delete from referido_canjes
 where telefono_referido like '35199000%' or telefono_dueno like '35199000%';

delete from referidos
 where telefono like '35199000%';

delete from pedidos
 where cliente_nombre = 'PRUEBA REFERIDOS - BORRAR'
    or tel_norm(cliente_telefono) like '35199000%';


-- ── 3. COMPROBACION ───────────────────────────────────────────────────
select
  (select count(*) from pedidos where cliente_nombre = 'PRUEBA REFERIDOS - BORRAR') as pedidos_de_prueba,
  (select count(*) from referidos)                                                 as codigos,
  (select count(*) from referido_canjes)                                           as canjes;
-- Los tres deberian dar 0.


-- ── 4. Y DESPUES, ENCENDER EL CAMPO EN LA WEB ─────────────────────────
--
--  Falta un paso mas, fuera de Supabase.
--
--  En index.html hay una linea que dice:
--      const REFERIDOS_ACTIVOS = false;
--  Cambiala a true y corre SUBIR.bat.
--
--  Esta en false a proposito: la validacion ya andaba y le hubiera dicho
--  al cliente "$3.000 de descuento", pero el canje fallaba y el pedido
--  salia al precio lleno. Prometer un descuento y no aplicarlo es peor
--  que no ofrecerlo. Una vez corrido este SQL, ya se puede encender.
