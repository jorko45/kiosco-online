// api/despacho/login.js — POST /api/despacho/login
// Dos modos:
//   { rol: 'panel',      clave: '...' }
//   { rol: 'repartidor', telefono: '...', pin: '...' }

import { rpc, json, cors, cuerpo, dbConfigurada } from '../_lib/db.js';
import { crearToken, claveValida, frenarIntentos, limpiarIntentos } from '../_lib/auth.js';

export default async function handler(req, res) {
  if (cors(req, res, 'POST, OPTIONS')) return;
  if (req.method !== 'POST') return json(res, 405, { ok: false, error: 'Metodo no permitido' });

  const b = cuerpo(req);
  const ip =
    (req.headers['x-forwarded-for'] || '').split(',')[0].trim() ||
    req.socket?.remoteAddress ||
    'desconocida';

  try {
    // ── Panel de despacho ──────────────────────────────────────────
    if (b.rol === 'panel') {
      if (!frenarIntentos(`panel:${ip}`)) {
        return json(res, 429, { ok: false, error: 'Demasiados intentos. Esperá 10 minutos.' });
      }
      if (!claveValida(b.clave)) {
        return json(res, 401, { ok: false, error: 'Clave incorrecta' });
      }
      limpiarIntentos(`panel:${ip}`);
      return json(res, 200, {
        ok: true,
        token: crearToken({ rol: 'panel' }, 12),
        rol: 'panel',
      });
    }

    // ── Repartidor ─────────────────────────────────────────────────
    if (b.rol === 'repartidor') {
      if (!dbConfigurada()) {
        return json(res, 503, { ok: false, error: 'Despacho no configurado' });
      }
      const telefono = String(b.telefono || '').trim();
      const pin = String(b.pin || '').trim();
      if (!telefono || !pin) {
        return json(res, 400, { ok: false, error: 'Faltan telefono y PIN' });
      }
      if (!frenarIntentos(`rep:${telefono}`)) {
        return json(res, 429, { ok: false, error: 'Demasiados intentos. Esperá 10 minutos.' });
      }

      const filas = await rpc('verificar_pin', { p_telefono: telefono, p_pin: pin });
      const rep = Array.isArray(filas) ? filas[0] : filas;
      if (!rep || !rep.id) {
        // Mismo mensaje para telefono inexistente y PIN malo:
        // no le decimos a nadie que numeros existen.
        return json(res, 401, { ok: false, error: 'Telefono o PIN incorrecto' });
      }

      limpiarIntentos(`rep:${telefono}`);
      return json(res, 200, {
        ok: true,
        token: crearToken({ rol: 'repartidor', id: rep.id, nombre: rep.nombre }, 16),
        rol: 'repartidor',
        repartidor: { id: rep.id, nombre: rep.nombre, en_turno: rep.en_turno },
      });
    }

    return json(res, 400, { ok: false, error: 'Rol invalido' });
  } catch (e) {
    console.error('[despacho] login:', e.message);
    return json(res, 500, { ok: false, error: 'Error al iniciar sesion' });
  }
}
