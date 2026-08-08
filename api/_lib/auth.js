// api/_lib/auth.js
// Tokens firmados con HMAC, sin dependencias.
//
// Modelo de acceso:
//   · PANEL DE DESPACHO  → clave unica (ADMIN_PASSWORD) que devuelve un token
//   · REPARTIDOR         → telefono + PIN que devuelve un token con su id
//   · CLIENTE            → sin login; token de seguimiento por pedido
//
// El token es <payload_base64url>.<firma>. No es un JWT completo y no hace
// falta que lo sea: solo tiene que ser imposible de falsificar sin el secreto
// y llevar una fecha de vencimiento.

import { createHmac, timingSafeEqual, randomBytes } from 'node:crypto';

const SECRETO = process.env.DESPACHO_SECRET;

function secreto() {
  if (!SECRETO || SECRETO.length < 16) {
    throw new Error(
      'Falta DESPACHO_SECRET (minimo 16 caracteres) en las variables de entorno de Vercel'
    );
  }
  return SECRETO;
}

const b64url = (buf) =>
  Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

const deB64url = (s) =>
  Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');

function firmar(datos) {
  return b64url(createHmac('sha256', secreto()).update(datos).digest());
}

/** Genera un token. horas = validez. */
export function crearToken(payload, horas = 12) {
  const cuerpo = { ...payload, exp: Date.now() + horas * 3600_000 };
  const datos = b64url(JSON.stringify(cuerpo));
  return `${datos}.${firmar(datos)}`;
}

/** Verifica y devuelve el payload, o null si no sirve. */
export function leerToken(token) {
  if (typeof token !== 'string' || !token.includes('.')) return null;
  const [datos, firma] = token.split('.');
  if (!datos || !firma) return null;

  // Comparacion en tiempo constante: evita filtrar la firma por timing.
  const esperada = Buffer.from(firmar(datos));
  const recibida = Buffer.from(firma);
  if (esperada.length !== recibida.length) return null;
  if (!timingSafeEqual(esperada, recibida)) return null;

  let payload;
  try { payload = JSON.parse(deB64url(datos)); } catch { return null; }
  if (!payload.exp || Date.now() > payload.exp) return null;
  return payload;
}

/** Saca el token del header Authorization: Bearer xxx */
export function tokenDe(req) {
  const h = req.headers.authorization || '';
  return h.startsWith('Bearer ') ? h.slice(7) : null;
}

/** Exige sesion de panel. Devuelve el payload o responde 401 y devuelve null. */
export function exigirPanel(req, res) {
  const p = leerToken(tokenDe(req));
  if (!p || p.rol !== 'panel') {
    res.status(401).json({ ok: false, error: 'No autorizado' });
    return null;
  }
  return p;
}

/** Exige sesion de repartidor. Devuelve el payload o responde 401. */
export function exigirRepartidor(req, res) {
  const p = leerToken(tokenDe(req));
  if (!p || p.rol !== 'repartidor' || !p.id) {
    res.status(401).json({ ok: false, error: 'No autorizado' });
    return null;
  }
  return p;
}

/**
 * Exige sesion de kiosco. Devuelve el payload o responde 401.
 *
 * El token lleva el id del PUNTO, no de una persona: en un kiosco hay
 * turnos, y quien esta en el mostrador a las 3 de la manana no es el mismo
 * que firmo el convenio. Lo que importa es que mostrador es.
 */
export function exigirKiosco(req, res) {
  const p = leerToken(tokenDe(req));
  if (!p || p.rol !== 'kiosco' || !p.punto_id) {
    res.status(401).json({ ok: false, error: 'No autorizado' });
    return null;
  }
  return p;
}

/** Acepta panel o repartidor. */
export function exigirSesion(req, res) {
  const p = leerToken(tokenDe(req));
  if (!p || !['panel', 'repartidor'].includes(p.rol)) {
    res.status(401).json({ ok: false, error: 'No autorizado' });
    return null;
  }
  return p;
}

/** Compara la clave del panel sin filtrar longitud por timing. */
export function claveValida(intento) {
  const real = process.env.ADMIN_PASSWORD;
  if (!real) throw new Error('Falta ADMIN_PASSWORD en las variables de entorno de Vercel');
  // Se recortan los espacios de los dos lados. Pegar el valor en Vercel arrastra
  // a veces un salto de linea invisible, y entonces la clave correcta nunca entra.
  const a = createHmac('sha256', secreto()).update(String(intento ?? '').trim()).digest();
  const b = createHmac('sha256', secreto()).update(String(real).trim()).digest();
  return timingSafeEqual(a, b);
}

/**
 * Freno de intentos, en memoria del proceso.
 *
 * ⚠ Limitacion real: las funciones serverless de Vercel se reparten entre
 * varias instancias y se reciclan, asi que esto NO es un rate-limit robusto.
 * Frena el goteo de intentos contra una misma instancia, que es el caso comun
 * de alguien probando PINes a mano. Si en algun momento hay repartidores
 * externos, hay que moverlo a la base o a Upstash.
 */
const intentos = new Map();

export function frenarIntentos(clave, maximo = 8, ventanaMs = 10 * 60_000) {
  const ahora = Date.now();
  const reg = intentos.get(clave);
  if (!reg || ahora > reg.hasta) {
    intentos.set(clave, { n: 1, hasta: ahora + ventanaMs });
    return true;
  }
  reg.n += 1;
  if (reg.n > maximo) return false;
  return true;
}

export function limpiarIntentos(clave) {
  intentos.delete(clave);
}

/** Token opaco para links de seguimiento, por si hace falta regenerarlo. */
export function tokenAleatorio(bytes = 16) {
  return randomBytes(bytes).toString('hex');
}
