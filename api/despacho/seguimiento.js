// api/despacho/seguimiento.js — GET /api/despacho/seguimiento?t=<token>
// Vista publica del pedido para el cliente. Sin login.
//
// Privacidad: el token identifica UN pedido. Se devuelve lo minimo para
// mostrar el seguimiento y nada mas — ni el telefono del cliente, ni el
// del repartidor, ni el id interno del pedido. Del repartidor se manda
// solo el nombre de pila y su posicion mientras el pedido esta en camino.

import { seleccionar, json, cors } from '../_lib/db.js';

export default async function handler(req, res) {
  if (cors(req, res, 'GET, OPTIONS')) return;
  if (req.method !== 'GET') return json(res, 405, { ok: false, error: 'Metodo no permitido' });

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

    const salida = {
      codigo: p.codigo,
      estado: p.estado,
      direccion: p.direccion,
      total: p.total,
      envio: p.envio,
      metodo_pago: p.metodo_pago,
      items: (p.items || []).map((i) => ({ nombre: i.nombre, qty: i.qty })),
      creado_at: p.creado_at,
      asignado_at: p.asignado_at,
      retirado_at: p.retirado_at,
      entregado_at: p.entregado_at,
      repartidor: null,
      posicion: null,
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
