-- ═══════════════════════════════════════════════════════════════════════
--  K24 · Cargar la lista del kiosco de una sola vez
--  Ejecutar DESPUES de 15_kiosco_autogestion.sql
-- ═══════════════════════════════════════════════════════════════════════
--
--  POR QUE
--  Cargar producto por producto no lo hace nadie. Un kiosco tiene cientos
--  y el que atiende el mostrador no va a estar media hora tipeando. Si la
--  carga es un embole, la lista queda vacia, y sin lista no hay forma de
--  saber quien compra bien ni de darle prioridad al que confirmo stock.
--
--  El archivo se lee en el navegador del kiosquero y llega aca ya
--  convertido en filas. Del lado del servidor solo se guarda: nada de
--  parsear PDFs en la base.
--
--  Es seguro correrlo mas de una vez.
-- ═══════════════════════════════════════════════════════════════════════

create or replace function cargar_precios_lote(
  p_punto_id uuid,
  p_filas    jsonb,
  p_reemplazar boolean default false
)
returns table (ok boolean, cargados integer, salteados integer, motivo text)
language plpgsql as $$
declare
  n_ok  integer := 0;
  n_mal integer := 0;
  it    jsonb;
  nom   text;
  pre   integer;
begin
  if jsonb_typeof(coalesce(p_filas, 'null'::jsonb)) <> 'array' then
    return query select false, 0, 0, 'No llegaron filas'::text; return;
  end if;

  -- Reemplazar es peligroso: si el archivo vino mal, borra la lista buena
  -- y deja la mala. Por eso solo se hace si el kiosquero lo pide expreso,
  -- y recien DESPUES de que vio la vista previa.
  if p_reemplazar then
    delete from punto_precios where punto_id = p_punto_id;
  end if;

  for it in select * from jsonb_array_elements(p_filas)
  loop
    nom := trim(coalesce(it->>'nombre', ''));
    begin
      pre := round((it->>'precio')::numeric)::integer;
    exception when others then
      pre := 0;
    end;

    if length(nom) < 2 or coalesce(pre, 0) <= 0 then
      n_mal := n_mal + 1;
      continue;
    end if;

    insert into punto_precios (punto_id, nombre, precio, producto_id)
    values (p_punto_id, left(nom, 200), pre, nullif(trim(coalesce(it->>'producto_id','')), ''))
    on conflict (punto_id, lower(trim(nombre))) do update
      set precio = excluded.precio,
          producto_id = coalesce(excluded.producto_id, punto_precios.producto_id),
          actualizado_at = now();

    -- Si lo carga con precio, es que lo tiene: se limpia el faltante viejo.
    delete from punto_faltantes
     where punto_id = p_punto_id
       and lower(trim(coalesce(nombre, ''))) = lower(nom);

    n_ok := n_ok + 1;
  end loop;

  return query select true, n_ok, n_mal,
    (n_ok || ' cargados, ' || n_mal || ' salteados')::text;
end $$;

revoke all on function cargar_precios_lote(uuid, jsonb, boolean) from anon, authenticated;


-- Deja constancia de cada carga masiva. Si un dia aparecen precios raros,
-- esto dice cuando entraron y desde que archivo.
create table if not exists punto_cargas (
  id         bigint generated always as identity primary key,
  punto_id   uuid not null references puntos_preparacion(id) on delete cascade,
  archivo    text,
  filas      integer,
  salteadas  integer,
  reemplazo  boolean not null default false,
  creado_at  timestamptz not null default now()
);

alter table punto_cargas enable row level security;
revoke all on punto_cargas from anon, authenticated;

create index if not exists idx_cargas_punto on punto_cargas(punto_id, creado_at desc);


select
  (select count(*) from pg_proc where proname='cargar_precios_lote')                  as funcion,
  (select count(*) from information_schema.tables where table_name='punto_cargas')    as tabla;
-- Esperado: 1, 1
