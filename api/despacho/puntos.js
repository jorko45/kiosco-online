// api/despacho/puntos.js
//
//   GET  /api/despacho/puntos                 → lista de puntos con su estado
//   GET  /api/despacho/puntos?pedido_id=123   → candidatos ordenados para ese pedido
//   POST /api/despacho/puntos                 → alta de punto
//   POST /api/despacho/puntos { id, ... }     → edicion (activar, radio, prioridad)
//
// Todo esto es del panel. Un repartidor no tiene nada que hacer aca.

import { seleccionar, actualizar, rpc, json, cors, cuerpo } from '../_lib/db.js';
import { exigirPanel } from '../_lib/auth.js';

const TIPOS = ['mami', 'kiosco_adherido', 'propio'];

export default async function handler(req, res) {
  if (cors(req, res, 'GET, POST, OPTIONS')) return;
  if (!exigirPanel(req, res)) return;

  try {
    // ── GET ────────────────────────────────────────────────────────
    if (req.method === 'GET') {
      const pedidoId = req.query.pedido_id;

      // Sin pedido: la lista completa para administrar
      if (!pedidoId) {
        const [puntos, abiertos] = await Promise.all([
          seleccionar('puntos_preparacion', { order: 'nombre.asc' }),
          seleccionar('v_puntos_abiertos', { select: 'id,abierto_ahora' }),
        ]);
        const estado = new Map(abiertos.map((a) => [a.id, a.abierto_ahora]));
        return json(res, 200, {
          ok: true,
          puntos: puntos.map((p) => ({ ...p, abierto_ahora: estado.get(p.id) ?? false })),
        });
      }

      // Con pedido: candidatos ordenados por conveniencia
      const peds = await seleccionar('pedidos', {
        select: 'id,codigo,lat,lng,repartidor_id,direccion',
        id: `eq.${Number(pedidoId)}`,
      });
      const ped = peds[0];
      if (!ped) return json(res, 404, { ok: false, error: 'Pedido inexistente' });

      // Sin coordenadas no hay calculo de cercania posible.
      if (ped.lat == null || ped.lng == null) {
        const puntos = await seleccionar('puntos_preparacion', {
          select: 'id,nombre,tipo,direccion',
          activo: 'eq.true',
          order: 'nombre.asc',
        });
        return json(res, 200, {
          ok: true,
          sin_coordenadas: true,
          motivo: 'El pedido no tiene ubicación, no se puede sugerir por cercanía',
          candidatos: puntos.map((p) => ({ punto_id: p.id, nombre: p.nombre, tipo: p.tipo })),
        });
      }

      // Si ya tiene repartidor, su posicion entra en el calculo
      let rlat = null, rlng = null;
      if (ped.repartidor_id) {
        const reps = await seleccionar('repartidores', {
          select: 'ultima_lat,ultima_lng',
          id: `eq.${ped.repartidor_id}`,
        });
        if (reps[0]) { rlat = reps[0].ultima_lat; rlng = reps[0].ultima_lng; }
      }

      const candidatos = await rpc('puntos_candidatos', {
        p_lat: ped.lat,
        p_lng: ped.lng,
        p_repartidor_lat: rlat,
        p_repartidor_lng: rlng,
      });

      return json(res, 200, { ok: true, pedido: ped.codigo, candidatos });
    }

    // ── POST ───────────────────────────────────────────────────────
    if (req.method === 'POST') {
      const b = cuerpo(req);

      // Edicion
      if (b.id) {
        const cambios = {};
        if (b.activo !== undefined) cambios.activo = Boolean(b.activo);
        if (b.radio_km !== undefined) {
          const r = Number(b.radio_km);
          if (!Number.isFinite(r) || r <= 0) {
            return json(res, 400, { ok: false, error: 'Radio inválido' });
          }
          cambios.radio_km = r;
        }
        if (b.prioridad !== undefined) cambios.prioridad = Math.round(Number(b.prioridad) || 0);
        if (b.telefono !== undefined) cambios.telefono = String(b.telefono).slice(0, 40) || null;
        if (b.contacto !== undefined) cambios.contacto = String(b.contacto).slice(0, 120) || null;
        if (b.notas !== undefined) cambios.notas = String(b.notas).slice(0, 500) || null;

        if (!Object.keys(cambios).length) {
          return json(res, 400, { ok: false, error: 'No se indicó ningún cambio' });
        }
        const r = await actualizar('puntos_preparacion', { id: `eq.${b.id}` }, cambios);
        return json(res, 200, { ok: true, punto: r[0] });
      }

      // Alta
      const nombre = String(b.nombre || '').trim();
      const direccion = String(b.direccion || '').trim();
      if (!nombre || !direccion) {
        return json(res, 400, { ok: false, error: 'Faltan nombre y dirección' });
      }
      if (!TIPOS.includes(b.tipo)) {
        return json(res, 400, { ok: false, error: `Tipo inválido. Debe ser: ${TIPOS.join(', ')}` });
      }

      // Coordenadas: si no vienen, se geocodifica la direccion del punto.
      let lat = Number(b.lat), lng = Number(b.lng);
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
        const { geocodificar } = await import('../_lib/geo.js');
        const g = await geocodificar(direccion);
        if (!g) {
          return json(res, 400, {
            ok: false,
            error: 'No pudimos ubicar esa dirección. Cargá latitud y longitud a mano.',
          });
        }
        lat = g.lat; lng = g.lng;
      }

      const id = await rpc('crear_punto', {
        p_nombre: nombre,
        p_tipo: b.tipo,
        p_direccion: direccion,
        p_lat: lat,
        p_lng: lng,
        p_desde: b.desde || '08:00',
        p_hasta: b.hasta || '21:00',
        p_radio_km: Number(b.radio_km) > 0 ? Number(b.radio_km) : 5.0,
      });

      return json(res, 201, { ok: true, id, lat, lng });
    }

    return json(res, 405, { ok: false, error: 'Método no permitido' });
  } catch (e) {
    console.error('[despacho] puntos:', e.message, e.detalle || '');
    return json(res, 500, { ok: false, error: 'Error del servidor' });
  }
}
