// api/_lib/precios.js
// Lista de precios autoritativa, leida del lado del servidor.
//
// POR QUE EXISTE
// El navegador manda el precio de cada producto al crear la orden de pago.
// Eso es imposible de confiar: cualquiera puede abrir la consola y mandar
// una Coca a $1. Este modulo trae los precios REALES desde la misma planilla
// que usa la web, para poder contrastarlos antes de cobrar.
//
// Es exactamente la misma fuente que /api/precios, asi que si la planilla
// dice $3.200, tanto la vitrina como el cobro dicen $3.200.

const SCRIPT_URL =
  'https://script.google.com/macros/s/AKfycbz48Hs8pcO-ewcmnxaHrS-eBrcVk-llMdaCxjNyCXOdP99SahO7X84w-97bs_JvuzOL/exec';

// La planilla tiene ~2.000 productos. Si vienen menos de 500 algo se rompio
// (planilla vacia, permisos, Apps Script caido) y NO hay que creerle: seria
// peor rechazar compras validas por una lista incompleta.
const MINIMO_FILAS = 500;

// Cache en memoria del proceso. Vercel reutiliza instancias entre llamadas,
// asi que la mayoria de los pedidos no vuelven a salir a la planilla.
const TTL_MS = 120_000;
let cache = { at: 0, mapa: null };

/**
 * Devuelve un Map id -> precio, o null si la lista no es confiable.
 * Nunca lanza.
 */
export async function mapaDePrecios() {
  if (cache.mapa && Date.now() - cache.at < TTL_MS) return cache.mapa;

  try {
    const ctrl = new AbortController();
    const corte = setTimeout(() => ctrl.abort(), 6000);
    const r = await fetch(`${SCRIPT_URL}?action=precios`, {
      redirect: 'follow',
      signal: ctrl.signal,
    });
    clearTimeout(corte);
    if (!r.ok) return cache.mapa;               // si hay cache viejo, mejor eso que nada

    const datos = await r.json();
    const filas = datos && Array.isArray(datos.items) ? datos.items : [];
    if (filas.length < MINIMO_FILAS) {
      console.warn('[precios] lista sospechosamente corta:', filas.length);
      return cache.mapa;
    }

    const mapa = new Map();
    for (const it of filas) {
      const id = String(it[0]);
      const activo = String(it[3]) === '1';
      if (!activo) continue;
      // Mismo criterio que usa la web al pisar precios: si hay precio
      // sugerido lo usa, si no el de venta. Si difiere, habria falsos
      // rechazos en cada compra.
      const precio = (Number(it[2]) > 0 ? Number(it[2]) : Number(it[1])) || 0;
      if (precio > 0) mapa.set(id, precio);
    }

    cache = { at: Date.now(), mapa };
    return mapa;
  } catch (e) {
    console.warn('[precios] no se pudo leer la planilla:', e.message);
    return cache.mapa;
  }
}

/**
 * Traduce la clave del carrito al identificador de la planilla.
 *
 *   'gon_3040340'   -> '3040340'          (productos de gondola, planos)
 *   'coca-cola_1'   -> 'coca-cola__1'     (productos con variantes)
 *
 * La web arma las claves con UN guion bajo y la planilla usa DOS. El id de
 * marca puede tener guiones bajos propios, asi que se parte por el ULTIMO.
 */
export function idDePlanilla(clave) {
  const k = String(clave || '');
  if (!k) return null;

  // Ya viene en formato de planilla (llego como srcId): no tocar.
  // Si se le aplicara la conversion quedaria 'marca___1' y no se encontraria.
  if (k.includes('__')) return k;

  // Productos de gondola: la clave del carrito es 'gon_' + id de planilla.
  if (k.startsWith('gon_')) return k.slice(4);

  // Id plano de la planilla (llego como srcId de un producto suelto).
  if (!k.includes('_')) return k;

  // Clave de variante: 'marca_3' -> 'marca__3'. El id de marca puede tener
  // guiones bajos propios, asi que se parte por el ULTIMO.
  const corte = k.lastIndexOf('_');
  if (corte <= 0) return k;
  return k.slice(0, corte) + '__' + k.slice(corte + 1);
}
