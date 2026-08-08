// api/despacho/puntos.js
//
//   PANEL (vos)
//   GET  /api/despacho/puntos                 → lista de puntos con su estado
//   GET  /api/despacho/puntos?pedido_id=123   → candidatos ordenados para ese pedido
//   GET  /api/despacho/puntos?red=1           → estado de la red + cascadas abiertas
//   POST /api/despacho/puntos                 → alta de punto
//   POST /api/despacho/puntos { id, ... }     → edicion (activar, radio, prioridad)
//   POST { accion:'pin', id, usuario, pin }   → darle acceso a un kiosco
//   POST { accion:'ofrecer', pedido_id }      → arrancar la ronda a mano
//   POST { accion:'rotar' }                   → cerrar vencidas y pasar al siguiente
//
//   KIOSCO (el kiosquero)
//   GET  /api/despacho/puntos?kiosco=1        → mi estado, mi oferta, mis faltantes
//   POST { accion:'latido', online }          → sigo acá / me prendo / me apago
//   POST { accion:'responder', pedido_id, respuesta, motivo }
//   POST { accion:'faltante', producto_id, nombre, falta }
//
// Todo lo del kiosco esta metido aca a proposito: Vercel deja 12 funciones
// en el plan gratuito y ya estan las 12 usadas. Un archivo nuevo tira el
// deploy entero abajo, no solo el endpoint nuevo.

import { seleccionar, actualizar, insertar, rpc, json, cors, cuerpo } from '../_lib/db.js';
import { exigirPanel, exigirKiosco } from '../_lib/auth.js';

const TIPOS = ['mami', 'kiosco_adherido', 'propio'];

// Acciones que puede pedir un kiosco. Todo lo demas exige sesion de panel.
const DE_KIOSCO = new Set(['latido', 'responder', 'faltante', 'mi_precio', 'borrar_precio', 'sugerir']);

export default async function handler(req, res) {
  if (cors(req, res, 'GET, POST, OPTIONS')) return;

  // ── Rama del kiosco ──────────────────────────────────────────────
  const esKiosco =
    (req.method === 'GET' && req.query.kiosco) ||
    (req.method === 'POST' && DE_KIOSCO.has(String((cuerpo(req) || {}).accion || '')));

  if (esKiosco) {
    const ses = exigirKiosco(req, res);
    if (!ses) return;
    try {
      return await manejarKiosco(req, res, ses);
    } catch (e) {
      console.error('[puntos] kiosco:', e.message);
      return json(res, 500, { ok: false, error: 'Error del servidor' });
    }
  }

  if (!exigirPanel(req, res)) return;

  try {
    // ── GET ────────────────────────────────────────────────────────
    if (req.method === 'GET') {
      // ── Estado de la red, para tu consola ──────────────────────
      // ── Precios de la red y sugerencias ───────────────────────
      if (req.query.precios) {
        const [precios, ranking, sugerencias] = await Promise.all([
          seleccionar('v_precios_red', { order: 'producto.asc,precio.asc' }),
          seleccionar('v_kiosco_competitividad', { order: 'desvio_pct.asc' }),
          seleccionar('punto_sugerencias', {
            select: 'id,punto_id,tipo,nombre,precio,nota,estado,creado_at',
            estado: 'in.(nueva,vista)',
            order: 'creado_at.desc',
          }),
        ]);
        return json(res, 200, { ok: true, precios, ranking, sugerencias });
      }

      if (req.query.red) {
        const [puntos, cascada, sinAsignar] = await Promise.all([
          seleccionar('puntos_preparacion', {
            select: 'id,nombre,tipo,activo,online,ultimo_latido,usuario,lat,lng,radio_km,prioridad',
            order: 'nombre.asc',
          }),
          seleccionar('v_cascada', { order: 'pedido_id.desc,orden.asc', limit: '80' }),
          seleccionar('pedidos', {
            select: 'id,codigo,subtotal,creado_at,estado',
            punto_id: 'is.null',
            estado: 'in.(nuevo,confirmado)',
            order: 'creado_at.asc',
          }),
        ]);

        const faltantes = await seleccionar('punto_faltantes', {
          select: 'punto_id,producto_id,nombre,desde',
          order: 'desde.desc',
        });
        const porPunto = {};
        for (const f of faltantes) (porPunto[f.punto_id] ||= []).push(f);

        return json(res, 200, {
          ok: true,
          puntos: puntos.map((p) => ({ ...p, faltantes: porPunto[p.id] || [] })),
          cascada,
          sin_asignar: sinAsignar,
        });
      }

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

      // ── Darle acceso a un kiosco ───────────────────────────────
      // El PIN lo elegis vos y viaja una sola vez. En la base queda
      // hasheado con bcrypt: no hay forma de volver a leerlo, ni para vos.
      if (b.accion === 'pin') {
        if (!b.id) return json(res, 400, { ok: false, error: 'Falta el punto' });
        const r = await rpc('poner_pin_punto', {
          p_punto_id: b.id,
          p_usuario: String(b.usuario || ''),
          p_pin: String(b.pin || ''),
        });
        const e = Array.isArray(r) ? r[0] : r;
        return json(res, e && e.ok ? 200 : 400, {
          ok: !!(e && e.ok),
          error: e && e.ok ? undefined : (e ? e.motivo : 'No se pudo'),
        });
      }

      // ── Arrancar la ronda a mano ───────────────────────────────
      if (b.accion === 'ofrecer') {
        const id = Number(b.pedido_id);
        if (!Number.isFinite(id)) return json(res, 400, { ok: false, error: 'Falta el pedido' });
        const r = await rpc('ofrecer_pedido', { p_pedido_id: id });
        const e = Array.isArray(r) ? r[0] : r;
        return json(res, 200, {
          ok: !!(e && e.ok),
          punto: e ? e.nombre : null,
          vence_at: e ? e.vence_at : null,
          motivo: e ? e.motivo : null,
        });
      }

      // ── Cerrar vencidas y pasar al siguiente ───────────────────
      // Lo llama la consola cada pocos segundos. Sin esto un pedido cuya
      // oferta vencio se queda quieto para siempre: no hay cron.
      if (b.accion === 'rotar') {
        const n = await rpc('rotar_ofertas_vencidas', {});
        return json(res, 200, { ok: true, rotados: Number(n) || 0 });
      }

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


// ═══════════════════════════════════════════════════════════════════════
//  LA PANTALLA DEL KIOSCO
//
//  Un kiosco adherido es proveedor y competencia a la vez: le vende a los
//  mismos vecinos. Por eso de aca no sale NUNCA el nombre, el telefono ni
//  la direccion del cliente. Solo que juntar y cuanto va a cobrar.
// ═══════════════════════════════════════════════════════════════════════
async function manejarKiosco(req, res, ses) {
  const puntoId = ses.punto_id;

  if (req.method === 'GET') {
    // Mi lista de precios, en pantalla aparte para no cargarla siempre.
    if (req.query.precios) {
      const mios = await seleccionar('punto_precios', {
        select: 'id,nombre,precio,producto_id,actualizado_at',
        punto_id: `eq.${puntoId}`,
        order: 'nombre.asc',
      });
      return json(res, 200, { ok: true, precios: mios });
    }

    const [punto, ofertas, faltantes] = await Promise.all([
      seleccionar('puntos_preparacion', {
        select: 'id,nombre,tipo,online,ultimo_latido,activo',
        id: `eq.${puntoId}`,
      }),
      seleccionar('v_oferta_para_kiosco', { punto_id: `eq.${puntoId}` }),
      seleccionar('punto_faltantes', {
        select: 'producto_id,nombre,desde',
        punto_id: `eq.${puntoId}`,
        order: 'desde.desc',
      }),
    ]);

    const p = punto[0] || {};
    const oferta = ofertas[0] || null;

    // Lo que ya acepto y todavia no salio, para que sepa que esta preparando.
    const enPreparacion = await seleccionar('pedidos', {
      select: 'id,codigo,items,estado,pago_al_punto',
      punto_id: `eq.${puntoId}`,
      estado: 'in.(confirmado,preparando,asignado)',
      order: 'creado_at.asc',
    });

    return json(res, 200, {
      ok: true,
      punto: { id: p.id, nombre: p.nombre, tipo: p.tipo, online: !!p.online, activo: !!p.activo },
      oferta,
      preparando: enPreparacion,
      faltantes,
    });
  }

  if (req.method !== 'POST') {
    return json(res, 405, { ok: false, error: 'Método no permitido' });
  }

  const b = cuerpo(req);

  // ── Sigo acá ───────────────────────────────────────────────────
  if (b.accion === 'latido') {
    const r = await rpc('latido_punto', {
      p_punto_id: puntoId,
      p_online: b.online === undefined ? null : Boolean(b.online),
    });
    const e = Array.isArray(r) ? r[0] : r;
    return json(res, 200, { ok: true, online: !!(e && e.online), conectado: !!(e && e.conectado) });
  }

  // ── Tomo el pedido / lo dejo pasar ─────────────────────────────
  if (b.accion === 'responder') {
    const pedidoId = Number(b.pedido_id);
    if (!Number.isFinite(pedidoId)) {
      return json(res, 400, { ok: false, error: 'Falta el pedido' });
    }
    if (!['acepto', 'rechazo'].includes(b.respuesta)) {
      return json(res, 400, { ok: false, error: 'Respuesta inválida' });
    }

    const r = await rpc('responder_oferta', {
      p_pedido_id: pedidoId,
      p_punto_id: puntoId,
      p_respuesta: b.respuesta,
      p_motivo: b.motivo ? String(b.motivo).slice(0, 200) : null,
    });
    const e = Array.isArray(r) ? r[0] : r;

    // Rechazado: el pedido no puede quedarse esperando a que alguien mire
    // la consola. Se le ofrece al siguiente en el acto.
    if (b.respuesta === 'rechazo' && e && e.ok) {
      try { await rpc('ofrecer_pedido', { p_pedido_id: pedidoId }); } catch (_) {}
    }
    return json(res, e && e.ok ? 200 : 409, {
      ok: !!(e && e.ok),
      motivo: e ? e.motivo : 'No se pudo registrar la respuesta',
    });
  }

  // ── Se me acabó / ya tengo ─────────────────────────────────────
  if (b.accion === 'faltante') {
    const prod = String(b.producto_id || '').trim();
    if (!prod) return json(res, 400, { ok: false, error: 'Falta el producto' });

    if (b.falta === false) {
      await fetchDelete('punto_faltantes', { punto_id: `eq.${puntoId}`, producto_id: `eq.${prod}` });
      return json(res, 200, { ok: true, falta: false });
    }
    // upsert a mano: si ya estaba marcado no pasa nada
    try {
      await insertar('punto_faltantes', {
        punto_id: puntoId,
        producto_id: prod,
        nombre: b.nombre ? String(b.nombre).slice(0, 200) : null,
      });
    } catch (e) {
      if (!/duplicate|conflict|23505/i.test(e.message || '')) throw e;
    }
    return json(res, 200, { ok: true, falta: true });
  }

  // ── A cuánto lo vendo yo ───────────────────────────────────────
  // Su precio de mostrador. No cambia lo que paga el cliente en el sitio:
  // sirve para ver quien compra bien y quien compra mal dentro de la red.
  if (b.accion === 'mi_precio') {
    const r = await rpc('guardar_precio_punto', {
      p_punto_id: puntoId,
      p_nombre: String(b.nombre || '').slice(0, 200),
      p_precio: Math.round(Number(b.precio) || 0),
      p_producto_id: b.producto_id ? String(b.producto_id).slice(0, 80) : null,
    });
    const e = Array.isArray(r) ? r[0] : r;
    return json(res, e && e.ok ? 200 : 400, {
      ok: !!(e && e.ok),
      error: e && e.ok ? undefined : (e ? e.motivo : 'No se pudo'),
    });
  }

  if (b.accion === 'borrar_precio') {
    const id = Number(b.id);
    if (!Number.isFinite(id)) return json(res, 400, { ok: false, error: 'Falta el id' });
    // El filtro por punto_id no es decorativo: sin el, un kiosco podria
    // borrar la lista de otro pasando un id cualquiera.
    await fetchDelete('punto_precios', { id: `eq.${id}`, punto_id: `eq.${puntoId}` });
    return json(res, 200, { ok: true });
  }

  // ── Te propongo algo ───────────────────────────────────────────
  if (b.accion === 'sugerir') {
    const tipo = ['falta_en_catalogo', 'para_oferta', 'otro'].includes(b.tipo) ? b.tipo : 'otro';
    const nombre = String(b.nombre || '').trim();
    if (nombre.length < 2) return json(res, 400, { ok: false, error: 'Escribí qué producto' });
    await insertar('punto_sugerencias', {
      punto_id: puntoId,
      tipo,
      nombre: nombre.slice(0, 200),
      precio: Number(b.precio) > 0 ? Math.round(Number(b.precio)) : null,
      nota: b.nota ? String(b.nota).slice(0, 500) : null,
    });
    return json(res, 200, { ok: true });
  }

  return json(res, 400, { ok: false, error: 'Acción desconocida' });
}


/** Borrado por PostgREST. db.js no expone uno, y para esto alcanza. */
async function fetchDelete(tabla, filtro) {
  const base = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_KEY;
  const qs = new URLSearchParams(filtro).toString();
  const r = await fetch(`${base}/rest/v1/${tabla}?${qs}`, {
    method: 'DELETE',
    headers: { apikey: key, Authorization: `Bearer ${key}`, Prefer: 'return=minimal' },
  });
  if (!r.ok) throw new Error(`DELETE ${tabla}: ${r.status}`);
}
