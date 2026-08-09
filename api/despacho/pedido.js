// api/despacho/pedido.js — POST /api/despacho/pedido
// Crea un pedido. Lo llama el checkout del sitio (publico, sin login).
//
// ⚠ TAMBIEN ATIENDE LAS ACCIONES DE REFERIDOS, y no por prolijidad sino
// por un limite real: el plan Hobby de Vercel permite 12 funciones
// serverless por deploy, y este proyecto ya tiene 12. Un archivo aparte
// para referidos hacia fallar el deploy entero con "No more than 12
// Serverless Functions". Estan juntas porque las dos son publicas y del
// mismo flujo de compra: si el pedido manda {accion}, se trata como
// referidos; si no, se crea el pedido.

import { insertar, actualizar, rpc, json, cors, cuerpo, dbConfigurada } from '../_lib/db.js';
import { geocodificar } from '../_lib/geo.js';

/** Las funciones de Postgres que devuelven TABLE llegan como array. */
const primera = (r) => (Array.isArray(r) ? r[0] || null : r || null);

// ── Referidos ──────────────────────────────────────────────────────────
//
// ⚠ POR QUE LA VALIDACION VIVE EN EL SERVIDOR
// Los envios gratis se guardan en el localStorage del cliente y con eso
// alcanza, porque para hacerse trampa hay que gastar $50.000 igual. Con
// referidos no: cualquiera abre una ventana de incognito y se "recomienda"
// a si mismo. La unica forma de que el descuento signifique algo es
// contrastarlo contra la tabla de pedidos, que el cliente no puede tocar.

// Probar codigos al voleo es barato para el atacante (31^4 combinaciones
// no son tantas) y caro para la base. Es por instancia de Vercel: no es
// una defensa perfecta, pero corta el caso obvio del script probando.
const INTENTOS_MAX = 12;
const VENTANA_MS = 60_000;
const intentos = new Map();

function demasiadosIntentos(ip) {
  const ahora = Date.now();
  const previo = intentos.get(ip);
  if (!previo || ahora - previo.desde > VENTANA_MS) {
    intentos.set(ip, { desde: ahora, n: 1 });
    return false;
  }
  previo.n += 1;
  if (intentos.size > 5000) intentos.clear();   // que el Map no crezca sin techo
  return previo.n > INTENTOS_MAX;
}

function ipDe(req) {
  const h = req.headers || {};
  return String(h['x-forwarded-for'] || h['x-real-ip'] || 'sin-ip').split(',')[0].trim();
}

async function accionesReferidos(req, res, b) {
  const accion = String(b.accion || '').trim();
  const telefono = String(b.telefono || '').trim();

  try {
    switch (accion) {
      // Devuelve null si el telefono todavia no compro nunca: el codigo es
      // un premio por ser cliente, no algo que cualquiera pueda pedir.
      case 'mi_codigo': {
        const codigo = await rpc('codigo_de', { p_telefono: telefono });
        return json(res, 200, { ok: true, codigo: codigo || null });
      }

      case 'resumen': {
        const r = primera(await rpc('resumen_referidos', { p_telefono: telefono }));
        return json(res, 200, {
          ok: true,
          codigo:         r?.codigo || null,
          amigos:         r?.amigos_totales || 0,
          amigos_pagados: r?.amigos_pagados || 0,
          premios:        r?.premios_libres || 0,
          ganado:         r?.ganado_total || 0,
        });
      }

      // Solo consulta, no reserva nada: el canje real va cuando el pedido
      // existe, porque entre que el cliente escribe el codigo y confirma
      // la compra puede pasar cualquier cosa.
      case 'validar': {
        if (demasiadosIntentos(ipDe(req))) {
          return json(res, 429, { ok: false, motivo: 'Probaste muchos códigos. Esperá un minuto.' });
        }
        const r = primera(await rpc('validar_referido', {
          p_codigo: String(b.codigo || '').trim(),
          p_telefono: telefono,
          p_subtotal: Math.max(0, Math.round(Number(b.subtotal) || 0)),
        }));
        return json(res, 200, {
          ok: Boolean(r?.ok),
          descuento: r?.descuento || 0,
          motivo: r?.motivo || 'No se pudo validar el código',
        });
      }

      case 'premios': {
        const n = await rpc('premios_de', { p_telefono: telefono });
        return json(res, 200, { ok: true, premios: Number(n) || 0 });
      }

      default:
        return json(res, 400, { ok: false, error: 'Accion desconocida' });
    }
  } catch (e) {
    console.error('[referido]', accion, e.message);
    return json(res, 500, { ok: false, error: 'No se pudo procesar el pedido de referidos' });
  }
}

/**
 * Cuanto descuento le corresponde a este pedido.
 *
 * ⚠ El monto lo decide SIEMPRE la base, nunca el navegador. Del cliente
 * solo se acepta el codigo que escribio; cuanto vale ese codigo, si le
 * corresponde y si ya lo uso son preguntas que se contestan contra la
 * tabla de pedidos, que es el unico lugar donde el cliente no escribe.
 *
 * Son dos descuentos distintos y se pueden acumular:
 *   - referido: el que trae un codigo en su PRIMERA compra
 *   - premio:   el que recomendo y su amigo ya recibio el pedido
 */
async function calcularDescuento(codigo, telefono, subtotal) {
  const r = { referido: 0, premio: 0, codigo: null, total: 0 };
  if (!telefono) return r;

  if (codigo) {
    try {
      const v = primera(await rpc('validar_referido', {
        p_codigo: codigo, p_telefono: telefono, p_subtotal: subtotal,
      }));
      if (v?.ok) {
        r.referido = Number(v.descuento) || 0;
        r.codigo = codigo;
      }
    } catch (e) {
      // Que falle el descuento no puede hacer fallar la compra.
      console.warn('[despacho] no se pudo validar el referido:', e.message);
    }
  }

  try {
    const n = Number(await rpc('premios_de', { p_telefono: telefono })) || 0;
    if (n > 0) {
      r.premio = Number(await rpc('param', {
        p_clave: 'ref_descuento_dueno', p_default: 3000,
      })) || 0;
    }
  } catch (e) {
    console.warn('[despacho] no se pudieron leer los premios:', e.message);
  }

  r.total = r.referido + r.premio;
  return r;
}

const MAX_ITEMS = 100;
const TOPE_TOTAL = 5_000_000; // freno de cordura: nadie pide 5 millones de pesos

export default async function handler(req, res) {
  if (cors(req, res, 'POST, OPTIONS')) return;
  if (req.method !== 'POST') return json(res, 405, { ok: false, error: 'Metodo no permitido' });

  // Si todavia no hay base configurada, no rompemos la compra:
  // el sitio sigue funcionando por WhatsApp como hasta ahora.
  if (!dbConfigurada()) {
    return json(res, 200, { ok: false, sin_configurar: true, error: 'Despacho no configurado' });
  }

  const b = cuerpo(req);

  // Referidos: mismo endpoint, distinta accion (ver nota del encabezado).
  if (b.accion) return await accionesReferidos(req, res, b);

  // ── Validacion ──────────────────────────────────────────────────
  const direccion = String(b.direccion || '').trim();
  if (direccion.length < 5) {
    return json(res, 400, { ok: false, error: 'Falta la direccion de entrega' });
  }

  const items = Array.isArray(b.items) ? b.items : [];
  if (!items.length) return json(res, 400, { ok: false, error: 'El pedido no tiene productos' });
  if (items.length > MAX_ITEMS) return json(res, 400, { ok: false, error: 'Demasiados productos' });

  const limpios = [];
  let subtotal = 0;
  for (const it of items) {
    const nombre = String(it.name ?? it.nombre ?? '').trim().slice(0, 200);
    const qty = Number(it.qty ?? it.cantidad);
    const precio = Number(it.price ?? it.precio);
    if (!nombre || !Number.isFinite(qty) || !Number.isFinite(precio)) {
      return json(res, 400, { ok: false, error: 'Producto con datos invalidos' });
    }
    if (qty < 1 || qty > 999 || precio < 0) {
      return json(res, 400, { ok: false, error: `Cantidad o precio fuera de rango en "${nombre}"` });
    }
    const q = Math.floor(qty);
    const p = Math.round(precio);
    limpios.push({ nombre, size: String(it.size ?? '').slice(0, 60), qty: q, precio: p });
    subtotal += q * p;
  }

  const envio = Math.max(0, Math.round(Number(b.envio) || 0));

  const telefono = String(b.cliente_telefono || '').trim();
  const codigoPedido = String(b.codigo_referido || '').trim().toUpperCase() || null;

  // Descuentos: el navegador propone un codigo, la base decide el monto.
  const desc = await calcularDescuento(codigoPedido, telefono, subtotal);
  // Nunca por debajo de cero: si algun dia los descuentos superan al pedido,
  // el pedido pasa a valer $0, no negativo.
  const descuento = Math.min(desc.total, subtotal + envio);
  const total = subtotal + envio - descuento;

  if (subtotal + envio > TOPE_TOTAL) {
    return json(res, 400, { ok: false, error: 'El total supera el limite permitido' });
  }

  // El total lo recalcula el servidor. Si el cliente mando otro, avisamos
  // en el log pero mandamos el nuestro: nunca se confia en el navegador.
  if (b.total != null && Math.abs(Number(b.total) - total) > 1) {
    console.warn('[despacho] total del cliente distinto del calculado', {
      cliente: Number(b.total), servidor: total,
    });
  }

  const metodo = ['efectivo', 'mercadopago', 'transferencia'].includes(b.metodo_pago)
    ? b.metodo_pago
    : null;

  // ── Coordenadas ─────────────────────────────────────────────────
  // Si el cliente compartio ubicacion, usamos esa (es la buena).
  // Si escribio la direccion a mano, la geocodificamos: sin coordenadas
  // no hay forma de elegir el punto de preparacion mas cercano.
  let lat = Number.isFinite(Number(b.lat)) ? Number(b.lat) : null;
  let lng = Number.isFinite(Number(b.lng)) ? Number(b.lng) : null;
  let origenCoords = lat !== null ? 'cliente' : null;

  if (lat === null || lng === null) {
    const g = await geocodificar(direccion);
    if (g) {
      lat = g.lat;
      lng = g.lng;
      origenCoords = g.origen;
    }
  }

  const fila = {
    estado: 'nuevo',
    ultimo_actor: 'cliente',
    cliente_nombre: String(b.cliente_nombre || '').trim().slice(0, 120) || null,
    cliente_telefono: String(b.cliente_telefono || '').trim().slice(0, 40) || null,
    cliente_email: String(b.cliente_email || '').trim().slice(0, 160) || null,
    direccion: direccion.slice(0, 300),
    direccion_notas: String(b.direccion_notas || '').trim().slice(0, 300) || null,
    lat,
    lng,
    items: limpios,
    subtotal,
    envio,
    descuento,
    referido_codigo: desc.referido > 0 ? desc.codigo : null,
    total,
    metodo_pago: metodo,
    pagado: false,
    mp_payment_id: b.mp_payment_id ? String(b.mp_payment_id).slice(0, 80) : null,
    // Con cuanto paga: solo si es efectivo y cubre el total.
    // La base tiene un check por si acaso, pero mejor no llegar a el.
    paga_con:
      metodo === 'efectivo' && Number.isFinite(Number(b.paga_con)) && Number(b.paga_con) >= total
        ? Math.round(Number(b.paga_con))
        : null,
  };

  try {
    const p = await insertar('pedidos', fila);
    if (!origenCoords) {
      // No es un error, pero conviene que quede en el log: si esto se
      // repite mucho, la asignacion automatica no va a poder funcionar.
      console.warn('[despacho] pedido sin coordenadas:', p.codigo, direccion);
    }

    // ── Consumir los descuentos ─────────────────────────────────────
    // Recien acá se pueden marcar como usados, porque el canje necesita
    // el id del pedido. Entre la validacion de arriba y este momento
    // pudo entrar otro pedido del mismo telefono, asi que las funciones
    // vuelven a validar y pueden decir que no. Si eso pasa, corregimos
    // el pedido: es preferible cobrarle bien a regalar un descuento que
    // no le correspondia.
    let aplicado = 0;
    if (desc.referido > 0) {
      try {
        const c = primera(await rpc('canjear_referido', {
          p_codigo: desc.codigo, p_telefono: telefono, p_pedido_id: p.id,
        }));
        if (c?.ok) aplicado += Number(c.descuento) || 0;
        else console.warn('[despacho] el referido no se pudo canjear:', c?.motivo);
      } catch (e) {
        console.warn('[despacho] error canjeando el referido:', e.message);
      }
    }
    if (desc.premio > 0) {
      try {
        aplicado += Number(await rpc('usar_premio', {
          p_telefono: telefono, p_pedido_id: p.id,
        })) || 0;
      } catch (e) {
        console.warn('[despacho] error usando el premio:', e.message);
      }
    }

    let totalFinal = p.total;
    if (aplicado !== descuento) {
      const corregido = subtotal + envio - aplicado;
      console.warn('[despacho] descuento corregido:', {
        codigo: p.codigo, esperado: descuento, aplicado,
      });
      try {
        await actualizar('pedidos', { id: `eq.${p.id}` }, {
          descuento: aplicado,
          total: corregido,
          referido_codigo: aplicado > 0 ? fila.referido_codigo : null,
        });
        totalFinal = corregido;
      } catch (e) {
        console.error('[despacho] no se pudo corregir el descuento:', e.message);
      }
    }

    // ── Arrancar la ronda de la red ────────────────────────────────
    // El pedido tiene que salir a buscar kiosco YA. Si esperamos al cron
    // se pierde hasta un minuto, y un minuto de un pedido de kiosco es
    // mucho. El cron queda igual como red de seguridad por si esto falla.
    //
    // Sin coordenadas no hay a quien ofrecerselo: la asignacion es por
    // cercania. Ese caso cae en el panel para asignarlo a mano.
    if (origenCoords) {
      try {
        await rpc('ofrecer_pedido', { p_pedido_id: p.id });
      } catch (e) {
        // Que no salga ofrecido no puede voltear la compra: el pedido ya
        // esta guardado y el cron lo va a levantar en menos de un minuto.
        console.warn('[despacho] no se pudo ofrecer el pedido:', e.message);
      }
    }

    return json(res, 201, {
      ok: true,
      pedido: {
        id: p.id,
        codigo: p.codigo,
        estado: p.estado,
        descuento: aplicado,
        total: totalFinal,
        ubicado: Boolean(origenCoords),
        seguimiento: `/seguimiento.html?t=${p.token_seguimiento}`,
      },
    });
  } catch (e) {
    console.error('[despacho] error creando pedido:', e.message, e.detalle || '');
    // Devolvemos 200 con ok:false a proposito: el front no debe bloquear
    // la compra porque falle el despacho. Cae al flujo de WhatsApp.
    return json(res, 200, { ok: false, error: 'No se pudo registrar el pedido' });
  }
}
