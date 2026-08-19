// api/despacho/repartidor.js
//
//   GET  /api/despacho/repartidor            → mis pedidos + estado de turno
//   POST /api/despacho/repartidor  { turno: true|false }        → abre/cierra turno
//   POST /api/despacho/repartidor  { lat, lng, precision_m }    → reporta posicion
//   POST { accion:'retirar',  pedido_id }                       → lo tengo, voy
//   POST { accion:'entregar', pedido_id, cobrado, metodo }      → entregado y cobrado
//   POST { accion:'auxilio',  tipo, detalle, pedido_id, ... }   → boton de auxilio
//
// Todo referido al repartidor del token: nunca recibe un id por parametro,
// asi no hay forma de mirar ni tocar los pedidos de otro.

import { seleccionar, actualizar, insertar, rpc, json, cors, cuerpo } from '../_lib/db.js';
import { exigirRepartidor } from '../_lib/auth.js';

export default async function handler(req, res) {
  if (cors(req, res, 'GET, POST, OPTIONS')) return;

  const sesion = exigirRepartidor(req, res);
  if (!sesion) return;

  try {
    // ── GET: mis pedidos ───────────────────────────────────────────
    if (req.method === 'GET') {
      const [pedidos, yo, caja] = await Promise.all([
        seleccionar('pedidos', {
          select:
            'id,codigo,estado,cliente_nombre,cliente_telefono,direccion,direccion_notas,' +
            'lat,lng,items,total,envio,metodo_pago,pagado,paga_con,creado_at,asignado_at,retirado_at,' +
            'punto_id,asignado_vence_at,cobrado,cerrado_at',
          repartidor_id: `eq.${sesion.id}`,
          estado: 'in.(asignado,en_camino)',
          order: 'asignado_at.asc',
        }),
        seleccionar('repartidores', {
          select: 'id,nombre,en_turno,turno_inicio',
          id: `eq.${sesion.id}`,
        }),
        // Rendicion del turno: cuanto efectivo tiene que entregar
        rpc('caja_repartidor', { p_repartidor_id: sesion.id }),
      ]);

      // Cuanto lleva ganado hoy y en la semana. Un repartidor que no sabe
      // cuanto lleva no puede decidir si le conviene seguir.
      let ganancias = {};
      try {
        const g = await rpc('ganancias_repartidor', { p_repartidor_id: sesion.id });
        ganancias = (Array.isArray(g) ? g[0] : g) || {};
      } catch (e) { /* si falta la funcion, la pantalla lo muestra vacio */ }

      // De donde retira cada pedido. El viaje empieza en el kiosco, no en
      // la casa del cliente: sin esto el repartidor no sabe adonde ir.
      const puntoIds = [...new Set(pedidos.map((p) => p.punto_id).filter(Boolean))];
      const puntos = {};
      if (puntoIds.length) {
        const filas = await seleccionar('puntos_preparacion', {
          select: 'id,nombre,direccion,lat,lng,telefono',
          id: `in.(${puntoIds.join(',')})`,
        });
        filas.forEach((f) => { puntos[f.id] = f; });
      }

      // Domicilio verificado: ¿ya le entregamos antes a este cliente en
      // esta direccion? Es dato de seguridad para el que reparte de noche.
      const conHistorial = await Promise.all(
        pedidos.map(async (p) => {
          let previas = 0;
          try {
            previas = await rpc('entregas_previas', {
              p_telefono: p.cliente_telefono,
              p_direccion: p.direccion,
            });
          } catch (e) { /* si falla, se muestra como domicilio nuevo */ }

          // Lo que la red sabe del LUGAR, aparte de lo que sabe del
          // cliente. Son dos cosas distintas: un cliente nuevo en una
          // direccion donde entregamos cien veces no es un riesgo.
          let lugar = null;
          try {
            const d = await rpc('perfil_direccion', {
              p_direccion: p.direccion, p_lat: p.lat, p_lng: p.lng,
            });
            lugar = (Array.isArray(d) ? d[0] : d) || null;
          } catch (e) { /* sin perfil se reparte igual, solo sin avisos */ }
          const items = Array.isArray(p.items) ? p.items : [];
          return {
            ...p,
            entregas_previas: Number(previas) || 0,
            verificado: (Number(previas) || 0) > 0,
            vuelto: p.paga_con ? Math.max(0, p.paga_con - p.total) : null,
            unidades: items.reduce((a, it) => a + (Number(it.qty || it.cantidad) || 1), 0),
            renglones: items.length,
            punto: puntos[p.punto_id] || null,
            lugar,
          };
        })
      );

      const c = (Array.isArray(caja) ? caja[0] : caja) || {};

      return json(res, 200, {
        ok: true,
        repartidor: yo[0] || { id: sesion.id, nombre: sesion.nombre },
        pedidos: conHistorial,
        entregados_hoy: c.entregados || 0,
        ganancias,
        caja: {
          entregados: c.entregados || 0,
          cobrado_efectivo: c.cobrado_efectivo || 0,
          ya_pagados: c.ya_pagados || 0,
          monto_ya_pagado: c.monto_ya_pagado || 0,
          a_rendir: c.a_rendir || 0,
        },
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

      // ── Lo tengo, voy para allá ──────────────────────────────
      if (b.accion === 'retirar') {
        const id = Number(b.pedido_id);
        const mios = await seleccionar('pedidos', {
          select: 'id,estado',
          id: `eq.${id}`,
          repartidor_id: `eq.${sesion.id}`,
        });
        if (!mios[0]) return json(res, 404, { ok: false, error: 'Ese pedido no es tuyo' });
        await actualizar('pedidos', { id: `eq.${id}` }, {
          estado: 'en_camino',
          retirado_at: new Date().toISOString(),
          asignado_vence_at: null,
        });
        return json(res, 200, { ok: true });
      }

      // ── Entregado y cobrado ──────────────────────────────────
      // Es el momento en que la venta existe. Hasta acá el pedido era una
      // promesa: si no se cobra, no hay venta, no hay comision para el
      // kiosco y no cuenta para las promos.
      if (b.accion === 'entregar') {
        const id = Number(b.pedido_id);
        const mios = await seleccionar('pedidos', {
          select: 'id,total,estado',
          id: `eq.${id}`,
          repartidor_id: `eq.${sesion.id}`,
        });
        if (!mios[0]) return json(res, 404, { ok: false, error: 'Ese pedido no es tuyo' });

        const r = await rpc('cerrar_venta', {
          p_pedido_id: id,
          p_cobrado: Number.isFinite(Number(b.cobrado)) ? Math.round(Number(b.cobrado)) : null,
          p_metodo: b.metodo || null,
        });
        const e = Array.isArray(r) ? r[0] : r;
        if (!e || !e.ok) {
          return json(res, 409, { ok: false, error: e ? e.motivo : 'No se pudo cerrar' });
        }

        // Si cobro de menos, queda registrado como incidente: es plata que
        // falta y tiene que aparecer en algun lado, no perderse.
        if (e.diferencia < 0) {
          try {
            await rpc('pedir_auxilio', {
              p_repartidor_id: sesion.id,
              p_tipo: 'pago_parcial',
              p_detalle: b.detalle || null,
              p_pedido_id: id,
              p_lat: Number(b.lat) || null,
              p_lng: Number(b.lng) || null,
              p_esperaba: mios[0].total,
              p_cobro: e.cobrado,
            });
          } catch (_) {}
        }

        return json(res, 200, {
          ok: true, cobrado: e.cobrado, vuelto: e.vuelto, diferencia: e.diferencia,
        });
      }

      // ── Auxilio ──────────────────────────────────────────────
      if (b.accion === 'reportar_direccion') {
      const r = await rpc('reportar_direccion', {
        p_repartidor_id: sesion.id,
        p_direccion: String(b.direccion || ''),
        p_tipo: String(b.tipo || ''),
        p_nota: b.nota ? String(b.nota) : null,
        p_pedido_id: b.pedido_id ? Number(b.pedido_id) : null,
        p_lat: Number.isFinite(Number(b.lat)) ? Number(b.lat) : null,
        p_lng: Number.isFinite(Number(b.lng)) ? Number(b.lng) : null,
      });
      const e = (Array.isArray(r) ? r[0] : r) || {};
      return json(res, e.ok ? 200 : 400, { ok: !!e.ok, mensaje: e.motivo });
    }

    if (b.accion === 'auxilio') {
        const r = await rpc('pedir_auxilio', {
          p_repartidor_id: sesion.id,
          p_tipo: String(b.tipo || ''),
          p_detalle: b.detalle ? String(b.detalle).slice(0, 500) : null,
          p_pedido_id: b.pedido_id ? Number(b.pedido_id) : null,
          p_lat: Number.isFinite(Number(b.lat)) ? Number(b.lat) : null,
          p_lng: Number.isFinite(Number(b.lng)) ? Number(b.lng) : null,
          p_esperaba: null,
          p_cobro: null,
        });
        const e = Array.isArray(r) ? r[0] : r;
        return json(res, e && e.ok ? 200 : 400, {
          ok: !!(e && e.ok),
          urgente: !!(e && e.urgente),
          error: e && e.ok ? undefined : (e ? e.motivo : 'No se pudo'),
        });
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
