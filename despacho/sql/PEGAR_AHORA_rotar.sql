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

revoke all on function rotar_ofertas_vencidas() from anon, authenticated;

select 'rotar_ofertas_vencidas actualizada' as resultado;
