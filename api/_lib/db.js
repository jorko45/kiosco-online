// api/_lib/db.js
// Cliente minimo de Supabase via PostgREST, con fetch nativo.
//
// Por que no usamos @supabase/supabase-js: el proyecto no tiene package.json
// y agregar dependencias obliga a un paso de build. PostgREST es una API REST
// comun y corriente; con fetch alcanza y sobra.
//
// ⚠ SUPABASE_SERVICE_KEY saltea RLS. Solo puede vivir en variables de entorno
//   de Vercel. Si aparece en el navegador, cualquiera lee y borra la base.

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_KEY;

export function dbConfigurada() {
  return Boolean(URL && KEY);
}

function base() {
  if (!URL || !KEY) {
    throw new Error(
      'Faltan SUPABASE_URL y/o SUPABASE_SERVICE_KEY en las variables de entorno de Vercel'
    );
  }
  return URL.replace(/\/$/, '');
}

async function pedir(ruta, { method = 'GET', body, prefer, params } = {}) {
  const qs = params ? '?' + new URLSearchParams(params).toString() : '';
  const headers = {
    apikey: KEY,
    Authorization: `Bearer ${KEY}`,
    'Content-Type': 'application/json',
  };
  if (prefer) headers.Prefer = prefer;

  const r = await fetch(`${base()}/rest/v1${ruta}${qs}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const texto = await r.text();
  let datos = null;
  if (texto) {
    try { datos = JSON.parse(texto); } catch { datos = texto; }
  }

  if (!r.ok) {
    // PostgREST devuelve { message, details, hint, code }.
    // Los errores que lanzamos con raise exception en los triggers
    // llegan en "message", asi que se pueden mostrar tal cual.
    const msg = (datos && (datos.message || datos.error)) || `Error ${r.status}`;
    const err = new Error(msg);
    err.status = r.status;
    err.detalle = datos;
    throw err;
  }
  return datos;
}

/** SELECT. Ej: seleccionar('pedidos', { estado: 'eq.nuevo', order: 'creado_at.desc' }) */
export function seleccionar(tabla, params = {}) {
  return pedir(`/${tabla}`, { params: { select: '*', ...params } });
}

/** INSERT. Devuelve la fila creada. */
export async function insertar(tabla, fila) {
  const r = await pedir(`/${tabla}`, {
    method: 'POST',
    body: fila,
    prefer: 'return=representation',
  });
  return Array.isArray(r) ? r[0] : r;
}

/** UPDATE con filtro. Devuelve las filas modificadas. */
export function actualizar(tabla, filtro, cambios) {
  return pedir(`/${tabla}`, {
    method: 'PATCH',
    params: filtro,
    body: cambios,
    prefer: 'return=representation',
  });
}

/** Llama a una funcion de Postgres (RPC). */
export function rpc(fn, args = {}) {
  return pedir(`/rpc/${fn}`, { method: 'POST', body: args });
}

/** Responde JSON con CORS y sin cache. */
export function json(res, status, cuerpo) {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  return res.status(status).json(cuerpo);
}

/** CORS + preflight. Devuelve true si ya respondio (OPTIONS). */
export function cors(req, res, metodos = 'GET, POST, OPTIONS') {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', metodos);
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') {
    res.status(204).end();
    return true;
  }
  return false;
}

/** Parsea el body venga como venga (Vercel a veces lo pasa string). */
export function cuerpo(req) {
  if (!req.body) return {};
  if (typeof req.body === 'string') {
    try { return JSON.parse(req.body); } catch { return {}; }
  }
  return req.body;
}
