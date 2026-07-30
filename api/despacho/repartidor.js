// api/despacho/repartidor.js
//
//   GET  /api/despacho/repartidor            → mis pedidos + estado de turno
//   POST /api/despacho/repartidor  { turno: true|false }        → abre/cierra turno
//   POST /api/despacho/repartidor  { lat, lng, precision_m }    → reporta posicion
//
// Todo referido al repartidor del token: nunca recibe un id por parametro,
// asi no hay forma de mirar ni tocar los pedidos de otro.

import { seleccionar, actualizar, insertar, json, cors, cuerpo } from '../_lib/db.js';
import { exigirRepartidor } from '../_lib/auth.js';

export default async function handler(req, res) {
  if (cors(req, res, 'GET, POST, OPTIONS')) return;

  const sesion = exigirRepartidor(req, res);
  if (!sesion) return;

  try {
    // ── GET: mis pedidos ───────────────────────────────────────────
    if (req.method === 'GET') {
      const [pedidos, yo] = await Promise.all([
        seleccionar('pedidos', {
          select:
            'id,codigo,estado,cliente_nombre,cliente_telefono,direccion,direccion_notas,' +
            'lat,lng,items,total,envio,metodo_pago,pagado,creado_at,asignado_at,retirado_at',
          repartidor_id: `eq.${sesion.id}`,
          estado: 'in.(asignado,en_camino)',
          order: 'asignado_at.asc',
        }),
        seleccionar('repartidores', {
          select: 'id,nombre,en_turno,turno_inicio',
          id: `eq.${sesion.id}`,
        }),
      ]);

      // Cuantas entregó hoy, para que vea su propio avance
      const desdeHoy = new Date();
      desdeHoy.setHours(0, 0, 0, 0);
      const hoy = await seleccionar('pedidos', {
        select: 'id',
        repartidor_id: `eq.${sesion.id}`,
        estado: 'eq.entregado',
        entregado_at: `gte.${desdeHoy.toISOString()}`,
      });

      return json(res, 200, {
        ok: true,
        repartidor: yo[0] || { id: sesion.id, nombre: sesion.nombre },
        pedidos,
        entregados_hoy: hoy.length,
      });
    }

    // ── POST ───────────────────────────────────────────────────────
    if (req.method === 'POST') {
      const b = cuerpo(req);

      // Abrir / cerrar turno
      if (b.turno !== undefined) {
        const abrir = b.turno === true || b.turno === 'true';
        const cambios = { en_turno: abrir };
        if (abrir) cambios.turno_inicio = new Date().toISOString();
        const r = await actualizar('repartidores', { id: `eq.${sesion.id}` }, cambios);
        return json(res, 200, { ok: true, en_turno: r[0]?.en_turno ?? abrir });
      }

      // Reportar posicion
      const lat = Number(b.lat);
      const lng = Number(b.lng);
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
        return json(res, 400, { ok: false, error: 'Faltan lat y lng' });
      }
      if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
        return json(res, 400, { ok: false, error: 'Coordenadas fuera de rango' });
      }

      // Si el repartidor tiene un pedido en camino, la posicion se asocia a ese
      // pedido: es lo que alimenta el seguimiento del cliente.
      let pedidoId = null;
      if (b.pedido_id) {
        const p = await seleccionar('pedidos', {
          select: 'id',
          id: `eq.${Number(b.pedido_id)}`,
          repartidor_id: `eq.${sesion.id}`,
        });
        if (p[0]) pedidoId = p[0].id;
      } else {
        const p = await seleccionar('pedidos', {
          select: 'id',
          repartidor_id: `eq.${sesion.id}`,
          estado: 'eq.en_camino',
          order: 'retirado_at.asc',
          limit: '1',
        });
        if (p[0]) pedidoId = p[0].id;
      }

      await insertar('posiciones', {
        repartidor_id: sesion.id,
        pedido_id: pedidoId,
        lat,
        lng,
        precision_m: Number.isFinite(Number(b.precision_m)) ? Number(b.precision_m) : null,
      });

      return json(res, 200, { ok: true, pedido_id: pedidoId });
    }

    return json(res, 405, { ok: false, error: 'Metodo no permitido' });
  } catch (e) {
    console.error('[despacho] repartidor:', e.message, e.detalle || '');
    return json(res, 500, { ok: false, error: 'Error del servidor' });
  }
}
