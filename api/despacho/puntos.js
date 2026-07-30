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
        const [puntos, abiertos, horarios] = await Promise.all([
          seleccionar('puntos_preparacion', { order: 'nombre.asc' }),
          seleccionar('v_puntos_abiertos', { select: 'id,abierto_ahora' }),
          seleccionar('punto_horarios', { select: 'punto_id,dia_semana,desde,hasta' }),
        ]);
        const estado = new Map(abiertos.map((a) => [a.id, a.abierto_ahora]));

        // Para el formulario de edicion alcanza con el tramo del lunes.
        // Si un punto tiene horarios distintos por dia, lo avisamos para no
        // pisarlos sin querer desde el panel.
        const porPunto = new Map();
        for (const h of horarios) {
          if (!porPunto.has(h.punto_id)) porPunto.set(h.punto_id, []);
          porPunto.get(h.punto_id).push(h);
        }

        return json(res, 200, {
          ok: true,
          puntos: puntos.map((p) => {
            const hs = porPunto.get(p.id) || [];
            const tramos = new Set(hs.map((h) => `${h.desde}-${h.hasta}`));
            const primero = hs[0] || null;
            return {
              ...p,
              abierto_ahora: estado.get(p.id) ?? false,
              desde: primero ? String(primero.desde).slice(0, 5) : null,
              hasta: primero ? String(primero.hasta).slice(0, 5) : null,
              horario_uniforme: tramos.size <= 1,
              es_24h: primero ? String(primero.desde) === String(primero.hasta) : false,
            };
          }),
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

      // ── Edicion ────────────────────────────────────────────────
      if (b.id) {
        const cambios = {};

        if (b.activo !== undefined) cambios.activo = Boolean(b.activo);
        if (b.nombre !== undefined) {
          const n = String(b.nombre).trim();
          if (!n) return json(res, 400, { ok: false, error: 'El nombre no puede quedar vacío' });
          cambios.nombre = n.slice(0, 120);
        }
        if (b.tipo !== undefined) {
          if (!TIPOS.includes(b.tipo)) {
            return json(res, 400, { ok: false, error: `Tipo inválido. Debe ser: ${TIPOS.join(', ')}` });
          }
          cambios.tipo = b.tipo;
        }
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

        // Cambio de direccion: hay que volver a ubicarla, si no las
        // coordenadas quedan apuntando al domicilio anterior y la
        // sugerencia por cercania miente sin que nadie lo note.
        if (b.direccion !== undefined) {
          const d = String(b.direccion).trim();
          if (d.length < 5) return json(res, 400, { ok: false, error: 'Dirección demasiado corta' });
          cambios.direccion = d.slice(0, 300);

          if (Number.isFinite(Number(b.lat)) && Number.isFinite(Number(b.lng))) {
            cambios.lat = Number(b.lat);
            cambios.lng = Number(b.lng);
          } else {
            const { geocodificar } = await import('../_lib/geo.js');
            const g = await geocodificar(d);
            if (!g) {
              return json(res, 400, {
                ok: false,
                error: 'No pudimos ubicar esa dirección. Revisala o cargá lat/lng a mano.',
              });
            }
            cambios.lat = g.lat;
            cambios.lng = g.lng;
          }
        }

        // ── Horarios ──
        // Se reemplazan los 7 dias con el mismo tramo. Si el punto tenia
        // horarios distintos por dia, el panel avisa antes de pisarlos.
        let horarioCambiado = false;
        if (b.desde !== undefined && b.hasta !== undefined) {
          const hora = /^([01]\d|2[0-3]):[0-5]\d$/;
          const desde = String(b.desde).slice(0, 5);
          const hasta = String(b.hasta).slice(0, 5);
          if (!hora.test(desde) || !hora.test(hasta)) {
            return json(res, 400, { ok: false, error: 'Horario inválido. Usá formato HH:MM.' });
          }
          await rpc('reemplazar_horario', { p_punto_id: b.id, p_desde: desde, p_hasta: hasta });
          horarioCambiado = true;
        }

        if (!Object.keys(cambios).length && !horarioCambiado) {
          return json(res, 400, { ok: false, error: 'No se indicó ningún cambio' });
        }

        let punto = null;
        if (Object.keys(cambios).length) {
          const r = await actualizar('puntos_preparacion', { id: `eq.${b.id}` }, cambios);
          punto = r[0];
        }
        return json(res, 200, { ok: true, punto, horario_actualizado: horarioCambiado });
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
