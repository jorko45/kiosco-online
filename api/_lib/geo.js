// api/_lib/geo.js
// Convierte una direccion escrita a mano en coordenadas, usando Nominatim
// (OpenStreetMap). Gratis y sin API key.
//
// POR QUE HACE FALTA
// Las coordenadas del pedido solo existen si el cliente toco "obtener
// ubicacion". La mayoria escribe la direccion y listo. Sin coordenadas no
// se puede calcular que punto de preparacion queda mas cerca, asi que la
// asignacion automatica nunca podria funcionar.
//
// REGLAS DE USO DE NOMINATIM (importante respetarlas o bloquean la IP):
//   · maximo 1 consulta por segundo
//   · User-Agent identificable y real
//   · no hacer cargas masivas
// Con 20-60 pedidos por dia estamos muy por debajo del limite, y ademas
// el cache en base hace que la mayoria ni salga a internet.

import { rpc } from './db.js';

const NOMINATIM = 'https://nominatim.openstreetmap.org/search';
const UA = 'k24hs-delivery/1.0 (https://k24hs.com)';

// Caja que contiene Cordoba Capital y alrededores inmediatos.
// Acota la busqueda para que "San Martin 100" no resuelva en Mendoza.
const VIEWBOX = '-64.35,-31.28,-64.05,-31.55';   // lon_min,lat_max,lon_max,lat_min
const LIMITES_CORDOBA = { latMin: -31.60, latMax: -31.25, lngMin: -64.40, lngMax: -64.00 };

function dentroDeCordoba(lat, lng) {
  return (
    lat >= LIMITES_CORDOBA.latMin && lat <= LIMITES_CORDOBA.latMax &&
    lng >= LIMITES_CORDOBA.lngMin && lng <= LIMITES_CORDOBA.lngMax
  );
}

/**
 * Devuelve { lat, lng, origen } o null.
 * origen: 'cache' | 'nominatim' | null
 *
 * Nunca lanza: si algo falla devuelve null y el pedido sigue su curso sin
 * coordenadas. Geocodificar es una mejora, no un requisito para vender.
 */
export async function geocodificar(direccion) {
  const dir = String(direccion || '').trim();
  if (dir.length < 5) return null;

  // 1) Cache
  try {
    const filas = await rpc('geo_buscar', { p_dir: dir });
    const c = Array.isArray(filas) ? filas[0] : filas;
    if (c) {
      // Ya se consulto antes: si no se encontro, no volvemos a preguntar.
      if (!c.encontrada) return null;
      return { lat: c.lat, lng: c.lng, origen: 'cache' };
    }
  } catch (e) {
    console.warn('[geo] cache no disponible:', e.message);
  }

  // 2) Nominatim
  let lat = null, lng = null;
  try {
    const consulta = /c[oó]rdoba/i.test(dir) ? dir : `${dir}, Córdoba, Argentina`;
    const url =
      `${NOMINATIM}?format=jsonv2&limit=1&countrycodes=ar` +
      `&viewbox=${encodeURIComponent(VIEWBOX)}&bounded=1` +
      `&q=${encodeURIComponent(consulta)}`;

    const ctrl = new AbortController();
    const corte = setTimeout(() => ctrl.abort(), 4000);   // no colgar el checkout
    const r = await fetch(url, {
      headers: { 'User-Agent': UA, 'Accept-Language': 'es' },
      signal: ctrl.signal,
    });
    clearTimeout(corte);

    if (r.ok) {
      const datos = await r.json();
      if (Array.isArray(datos) && datos[0]) {
        const la = Number(datos[0].lat);
        const ln = Number(datos[0].lon);
        // Aunque acotamos la busqueda, verificamos: un resultado fuera de
        // Cordoba es peor que ninguno, porque enviaria el pedido al nodo
        // equivocado sin que nadie lo note.
        if (Number.isFinite(la) && Number.isFinite(ln) && dentroDeCordoba(la, ln)) {
          lat = la; lng = ln;
        }
      }
    }
  } catch (e) {
    console.warn('[geo] nominatim falló:', e.message);
  }

  // 3) Guardar el resultado, incluso si no se encontro: asi no volvemos a
  //    preguntar por la misma direccion imposible una y otra vez.
  try {
    await rpc('geo_guardar', { p_dir: dir, p_lat: lat, p_lng: lng });
  } catch (e) {
    console.warn('[geo] no se pudo cachear:', e.message);
  }

  return lat === null ? null : { lat, lng, origen: 'nominatim' };
}
