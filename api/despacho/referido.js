// api/despacho/referido.js — POST /api/despacho/referido
//
// Todo lo del programa de referidos, en un solo endpoint con "accion".
// Es publico (sin login): lo llama el checkout del sitio.
//
// ⚠ POR QUE LA VALIDACION VIVE ACA Y NO EN EL NAVEGADOR
// Los envios gratis se guardan en el localStorage del cliente y con eso
// alcanza, porque para hacerse trampa hay que gastar $50.000 igual. Con
// referidos no: cualquiera abre una ventana de incognito y se "recomienda"
// a si mismo. La unica forma de que el descuento signifique algo es
// contrastarlo contra la tabla de pedidos, que el cliente no puede tocar.
//
// El monto del descuento NUNCA sale del navegador: lo decide la base.

import { rpc, json, cors, cuerpo, dbConfigurada } from '../_lib/db.js';

// Un intento de canje es barato de mandar y caro de procesar, asi que
// conviene frenar la fuerza bruta sobre los codigos (31^4 combinaciones
// no son tantas). Es por instancia de Vercel: no es una defensa perfecta,
// pero corta el caso obvio de alguien probando codigos desde un script.
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
  // Evitar que el Map crezca sin techo si la instancia vive mucho.
  if (intentos.size > 5000) intentos.clear();
  return previo.n > INTENTOS_MAX;
}

function ipDe(req) {
  const h = req.headers || {};
  return String(h['x-forwarded-for'] || h['x-real-ip'] || 'sin-ip').split(',')[0].trim();
}

/** Las funciones de Postgres que devuelven TABLE llegan como array de filas. */
function primera(r) {
  return Array.isArray(r) ? (r[0] || null) : (r || null);
}

export default async function handler(req, res) {
  if (cors(req, res, 'POST, OPTIONS')) return;
  if (req.method !== 'POST') return json(res, 405, { ok: false, error: 'Metodo no permitido' });

  // Sin base configurada el sitio sigue vendiendo, solo que sin referidos.
  if (!dbConfigurada()) {
    return json(res, 200, { ok: false, sin_configurar: true });
  }

  const b = cuerpo(req);
  const accion = String(b.accion || '').trim();
  const telefono = String(b.telefono || '').trim();

  try {
    switch (accion) {
      // ── Mi codigo ────────────────────────────────────────────────
      // Devuelve null si el telefono todavia no compro nunca: el codigo
      // es un premio por ser cliente, no algo que cualquiera pueda pedir.
      case 'mi_codigo': {
        const codigo = await rpc('codigo_de', { p_telefono: telefono });
        return json(res, 200, { ok: true, codigo: codigo || null });
      }

      // ── Como me viene yendo ──────────────────────────────────────
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

      // ── ¿Sirve este codigo? ──────────────────────────────────────
      // Solo consulta, no reserva nada. El canje real va despues, cuando
      // el pedido existe: entre que el cliente escribe el codigo y
      // confirma la compra puede pasar cualquier cosa.
      case 'validar': {
        if (demasiadosIntentos(ipDe(req))) {
          return json(res, 429, { ok: false, error: 'Probaste muchos codigos. Esperá un minuto.' });
        }
        const r = primera(await rpc('validar_referido', {
          p_codigo: String(b.codigo || '').trim(),
          p_telefono: telefono,
          p_subtotal: Math.max(0, Math.round(Number(b.subtotal) || 0)),
        }));
        return json(res, 200, {
          ok: Boolean(r?.ok),
          descuento: r?.descuento || 0,
          motivo: r?.motivo || 'No se pudo validar el codigo',
        });
      }

      // ── Premios que ya me gane ───────────────────────────────────
      // Solo cuentan los referidos cuyo pedido llego a entregado: si el
      // premio se diera al confirmar, bastaria pedir y cancelar para
      // fabricar descuentos.
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
