// api/despacho/login.js — POST /api/despacho/login
// Dos modos:
//   { rol: 'panel',      clave: '...' }
//   { rol: 'repartidor', telefono: '...', pin: '...' }

import { rpc, json, cors, cuerpo, dbConfigurada } from '../_lib/db.js';
import { crearToken, claveValida, frenarIntentos, limpiarIntentos } from '../_lib/auth.js';

/** Devuelve la lista de variables de entorno que faltan, para poder decirlo. */
function faltantes(rol) {
  const f = [];
  if (!process.env.DESPACHO_SECRET || process.env.DESPACHO_SECRET.length < 16) {
    f.push('DESPACHO_SECRET (minimo 16 caracteres)');
  }
  if (rol === 'panel' && !process.env.ADMIN_PASSWORD) f.push('ADMIN_PASSWORD');
  if (['repartidor','kiosco','kiosco_alta','repartidor_alta'].includes(rol)) {
    if (!process.env.SUPABASE_URL) f.push('SUPABASE_URL');
    if (!process.env.SUPABASE_SERVICE_KEY) f.push('SUPABASE_SERVICE_KEY');
  }
  return f;
}

export default async function handler(req, res) {
  if (cors(req, res, 'POST, OPTIONS')) return;
  if (req.method !== 'POST') return json(res, 405, { ok: false, error: 'Metodo no permitido' });

  const b = cuerpo(req);

  // Antes de nada: si falta configuracion, decirlo claro en vez de un 500 opaco.
  // Los nombres de las variables no son secretos; los valores nunca se exponen.
  const falta = faltantes(b.rol);
  if (falta.length) {
    return json(res, 503, {
      ok: false,
      sin_configurar: true,
      error: 'Falta configurar en Vercel: ' + falta.join(', '),
      faltantes: falta,
    });
  }
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

    // ── Kiosco adherido ────────────────────────────────────────────
    // El PIN identifica al MOSTRADOR, no a una persona. En un kiosco hay
    // turnos y quien atiende a la madrugada no es quien firmo el convenio.
    if (b.rol === 'kiosco') {
      if (!dbConfigurada()) {
        return json(res, 503, { ok: false, error: 'Despacho no configurado' });
      }
      const usuario = String(b.usuario || '').trim();
      const pin = String(b.pin || '').trim();
      if (!usuario || !pin) {
        return json(res, 400, { ok: false, error: 'Faltan usuario y PIN' });
      }
      if (!frenarIntentos(`kio:${usuario}`)) {
        return json(res, 429, { ok: false, error: 'Demasiados intentos. Esperá 10 minutos.' });
      }

      const filas = await rpc('verificar_pin_punto', { p_usuario: usuario, p_pin: pin });
      const k = Array.isArray(filas) ? filas[0] : filas;
      if (!k || !k.id) {
        // Mismo mensaje para usuario inexistente y PIN malo.
        return json(res, 401, { ok: false, error: 'Usuario o PIN incorrecto' });
      }

      limpiarIntentos(`kio:${usuario}`);
      return json(res, 200, {
        ok: true,
        token: crearToken({ rol: 'kiosco', punto_id: k.id, nombre: k.nombre }, 16),
        rol: 'kiosco',
        // lat/lng van para que la pantalla sepa si el kiosco esta ubicado.
        // Sin esto le mostraria el aviso de "ubicá tu kiosco" a todos.
        punto: { id: k.id, nombre: k.nombre, tipo: k.tipo, online: k.online,
                 lat: k.lat, lng: k.lng },
        sin_ubicar: k.lat === null || k.lat === undefined,
      });
    }

    // ── Alta de un kiosco, sin que nadie lo habilite ───────────────
    // Es un endpoint publico a proposito: la idea es que un kiosquero se
    // registre un domingo a las 3 AM sin depender de que alguien mire.
    // Lo que lo protege no es una aprobacion manual sino que no recibe
    // pedidos hasta tener direccion ubicable, horario y 10 productos
    // cargados con precio. Un registro trucho no carga 10 precios.
    if (b.rol === 'kiosco_alta') {
      if (!dbConfigurada()) {
        return json(res, 503, { ok: false, error: 'Despacho no configurado' });
      }
      // Freno por IP: un endpoint abierto sin esto es una invitacion.
      if (!frenarIntentos(`alta:${ip}`, 5)) {
        return json(res, 429, { ok: false, error: 'Demasiados intentos. Probá más tarde.' });
      }

      const direccion = String(b.direccion || '').trim();
      let lat = Number(b.lat), lng = Number(b.lng);

      // Si el navegador ya mandó la ubicación, se usa esa y no se
      // molesta a nadie: el kiosquero está parado adentro del kiosco, no
      // hay dato más exacto que ese.
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
        lat = null; lng = null;
        try {
          const { geocodificar } = await import('../_lib/geo.js');
          const g = await geocodificar(direccion);
          if (g) { lat = g.lat; lng = g.lng; }
        } catch (e) {
          console.warn('[despacho] geocodificar falló:', e.message);
        }
      }

      // Y si no se pudo ubicar, se registra IGUAL. Antes esto cortaba el
      // alta, que era redundante y dejaba gente afuera: punto_listo ya
      // exige coordenadas para recibir pedidos, así que un kiosco sin
      // ubicar no recibe nada hasta resolverlo. Puede entrar, cargar sus
      // precios, y ubicarse desde el celular cuando quiera.

      const r = await rpc('registrar_kiosco', {
        p_nombre: String(b.nombre || ''),
        p_direccion: direccion,
        p_lat: lat,
        p_lng: lng,
        p_usuario: String(b.usuario || ''),
        p_pin: String(b.pin || ''),
        p_telefono: b.telefono ? String(b.telefono) : null,
        p_radio_km: Number(b.radio_km) > 0 ? Number(b.radio_km) : 5,
      });
      const e = Array.isArray(r) ? r[0] : r;
      if (!e || !e.ok) {
        return json(res, 400, { ok: false, error: e ? e.motivo : 'No se pudo registrar' });
      }

      limpiarIntentos(`alta:${ip}`);
      return json(res, 201, {
        ok: true,
        token: crearToken({ rol: 'kiosco', punto_id: e.punto_id, nombre: b.nombre }, 16),
        rol: 'kiosco',
        punto: {
          id: e.punto_id, nombre: String(b.nombre || ''),
          tipo: 'kiosco_adherido', online: false,
          lat, lng,
        },
        sin_ubicar: lat === null,
        mensaje: e.motivo,
      });
    }

    // ── Alta de un repartidor ──────────────────────────────────────
    // Publica como la del kiosco, pero con una diferencia importante:
    // el kiosco entra y arranca solo, el repartidor NO. Queda pendiente
    // hasta que Joe le mire los papeles. Un kiosco que miente pierde una
    // venta; un repartidor sin seguro que choca es otra cosa.
    if (b.rol === 'repartidor_alta') {
      if (!dbConfigurada()) {
        return json(res, 503, { ok: false, error: 'Despacho no configurado' });
      }
      if (!frenarIntentos(`repalta:${ip}`, 5)) {
        return json(res, 429, { ok: false, error: 'Demasiados intentos. Probá más tarde.' });
      }

      const r = await rpc('registrar_repartidor', {
        p_nombre: String(b.nombre || ''),
        p_telefono: String(b.telefono || ''),
        p_pin: String(b.pin || ''),
        p_dni: b.dni ? String(b.dni) : null,
        p_email: b.email ? String(b.email) : null,
        p_vehiculo: String(b.vehiculo || 'moto'),
        p_patente: b.patente ? String(b.patente) : null,
        p_consiente: b.consiente === true,
      });
      const e = Array.isArray(r) ? r[0] : r;
      if (!e || !e.ok) {
        return json(res, 400, { ok: false, error: e ? e.motivo : 'No se pudo registrar' });
      }

      limpiarIntentos(`repalta:${ip}`);
      // Entra igual, para poder cargar los papeles. Lo que no puede
      // todavia es recibir pedidos: eso lo decide repartidor_habilitado.
      return json(res, 201, {
        ok: true,
        token: crearToken({ rol: 'repartidor', id: e.repartidor_id, nombre: String(b.nombre || '') }, 16),
        rol: 'repartidor',
        repartidor: { id: e.repartidor_id, nombre: String(b.nombre || ''), en_turno: false },
        pendiente: true,
      });
    }

    return json(res, 400, { ok: false, error: 'Rol invalido' });
  } catch (e) {
    console.error('[despacho] login:', e.message);
    return json(res, 500, { ok: false, error: 'Error al iniciar sesion' });
  }
}
