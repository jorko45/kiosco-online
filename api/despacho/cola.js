// api/despacho/cola.js — GET /api/despacho/cola
// Todo lo que el panel necesita en una sola llamada: pedidos activos,
// repartidores y un resumen del dia. Una sola request cada pocos segundos.

import { seleccionar, json, cors } from '../_lib/db.js';
import { exigirPanel } from '../_lib/auth.js';

export default async function handler(req, res) {
  if (cors(req, res, 'GET, OPTIONS')) return;
  if (req.method !== 'GET') return json(res, 405, { ok: false, error: 'Metodo no permitido' });
  if (!exigirPanel(req, res)) return;

  try {
    const desdeHoy = new Date();
    desdeHoy.setHours(0, 0, 0, 0);

    const [cola, repartidores, hoy] = await Promise.all([
      seleccionar('v_cola_despacho'),
      seleccionar('repartidores', {
        select: 'id,nombre,telefono,activo,en_turno,ultima_lat,ultima_lng,ultima_pos_at',
        activo: 'eq.true',
        order: 'nombre.asc',
      }),
      seleccionar('pedidos', {
        select: 'estado,total',
        creado_at: `gte.${desdeHoy.toISOString()}`,
      }),
    ]);

    const entregados = hoy.filter((p) => p.estado === 'entregado');
    const resumen = {
      pedidos_hoy: hoy.length,
      entregados_hoy: entregados.length,
      cancelados_hoy: hoy.filter((p) => p.estado === 'cancelado').length,
      facturado_hoy: entregados.reduce((a, p) => a + (p.total || 0), 0),
      en_cola: cola.length,
    };

    return json(res, 200, { ok: true, cola, repartidores, resumen, ahora: Date.now() });
  } catch (e) {
    console.error('[despacho] cola:', e.message);
    return json(res, 500, { ok: false, error: 'No se pudo leer la cola' });
  }
}
