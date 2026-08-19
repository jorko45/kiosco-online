// api/despacho/seguimiento.js — GET /api/despacho/seguimiento?t=<token>
// Vista publica del pedido para el cliente. Sin login.
//
// Privacidad: el token identifica UN pedido. Se devuelve lo minimo para
// mostrar el seguimiento y nada mas — ni el telefono del cliente, ni el
// del repartidor, ni el id interno del pedido. Del repartidor se manda
// solo el nombre de pila y su posicion mientras el pedido esta en camino.

import { seleccionar, rpc, json, cors, cuerpo } from '../_lib/db.js';

export default async function handler(req, res) {
  if (cors(req, res, 'GET, POST, OPTIONS')) return;
  if (!['GET', 'POST'].includes(req.method)) {
    return json(res, 405, { ok: false, error: 'Metodo no permitido' });
  }

  const token = String(req.query.t || '').trim();
  // El token es hex de 16 bytes. Validar el formato evita mandar basura a la base.
  if (!/^[a-f0-9]{32}$/.test(token)) {
    return json(res, 404, { ok: false, error: 'Seguimiento inexistente' });
  }

  try {
    const filas = await seleccionar('pedidos', {
      select:
        'id,codigo,estado,direccion,total,envio,metodo_pago,items,' +
        'creado_at,asignado_at,retirado_at,entregado_at,repartidor_id',
      token_seguimiento: `eq.${token}`,
    });
    const p = filas[0];
    if (!p) return json(res, 404, { ok: false, error: 'Seguimiento inexistente' });

    // ── El cliente contesta un reemplazo ───────────────────────────
    // El token del seguimiento es la unica llave: quien lo tiene es el
    // dueño del pedido. Se verifica que el reemplazo sea de ESTE pedido,
    // porque el id es un numero corrido y se puede adivinar.
    if (req.method === 'POST') {
      const b = cuerpo(req);
      const mios = await seleccionar('pedido_reemplazos', {
        select: 'id',
        id: `eq.${Number(b.reemplazo_id) || 0}`,
        pedido_id: `eq.${p.id}`,
      });
      if (!mios.length) {
        return json(res, 404, { ok: false, error: 'Esa propuesta no es de este pedido' });
      }
      const r = await rpc('responder_reemplazo', {
        p_reemplazo_id: Number(b.reemplazo_id),
        p_acepta: b.acepta === true,
      });
      const e = (Array.isArray(r) ? r[0] : r) || {};
      return json(res, e.r_ok ? 200 : 400,
        { ok: !!e.r_ok, total: e.r_total, mensaje: e.r_motivo });
    }

    // Lo que tiene que contestar ahora, si hay algo.
    let reemplazos = [];
    try {
      reemplazos = await rpc('reemplazos_abiertos', { p_pedido_id: p.id });
    } catch (e) { /* sin esto el seguimiento anda igual */ }

    const salida = {
      codigo: p.codigo,
      estado: p.estado,
      direccion: p.direccion,
      total: p.total,
      envio: p.envio,
      metodo_pago: p.metodo_pago,
      // El carrito del sitio manda name/qty y el despacho a veces
      // nombre/cantidad. Leer solo uno dejaba la lista en blanco.
      items: (p.items || []).map((i) => ({
        nombre: i.nombre || i.name || '',
        qty: i.qty || i.cantidad || 1,
        reemplazo_de: i.reemplazo_de || null,
      })),
      creado_at: p.creado_at,
      asignado_at: p.asignado_at,
      retirado_at: p.retirado_at,
      entregado_at: p.entregado_at,
      repartidor: null,
      posicion: null,
      reemplazos: Array.isArray(reemplazos) ? reemplazos : [],
    };

    // La posicion del repartidor solo se expone mientras el pedido va en camino.
    // Ni antes (no aporta) ni despues (seria rastrear a una persona sin motivo).
    if (p.estado === 'en_camino' && p.repartidor_id) {
      const reps = await seleccionar('repartidores', {
        select: 'nombre,ultima_lat,ultima_lng,ultima_pos_at',
        id: `eq.${p.repartidor_id}`,
      });
      const r = reps[0];
      if (r) {
        salida.repartidor = { nombre: String(r.nombre || '').split(' ')[0] };
        const frescura = r.ultima_pos_at ? Date.now() - new Date(r.ultima_pos_at).getTime() : Infinity;
        // Una posicion de hace mas de 5 minutos confunde mas de lo que ayuda
        if (r.ultima_lat != null && frescura < 5 * 60_000) {
          salida.posicion = {
            lat: r.ultima_lat,
            lng: r.ultima_lng,
            hace_segundos: Math.round(frescura / 1000),
          };
        }
      }
    }

    return json(res, 200, { ok: true, pedido: salida });
  } catch (e) {
    console.error('[despacho] seguimiento:', e.message);
    return json(res, 500, { ok: false, error: 'Error del servidor' });
  }
}
