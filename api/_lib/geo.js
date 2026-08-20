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
 * Las direcciones se escriben como se hablan: "Colón 1200 esq. Fragueiro",
 * "Rondeau 165 local 3", "Av. Sabattini casi Richieri". Nominatim entiende
 * calle y numero; el resto le sobra y le hace fallar la busqueda entera.
 *
 * Se prueba de mas especifico a mas general. Alcanza con llegar a la
 * cuadra: el reparto lo termina una persona que sabe leer un numero.
 */
function variantes(dir) {
  const base = /c[oó]rdoba/i.test(dir) ? dir : `${dir}, Córdoba, Argentina`;
  const salida = [base];

  // Sacar lo que no es calle ni numero
  let limpia = dir
    .replace(/\b(esq\.?|esquina|casi|entre|y)\s+.*/i, '')
    .replace(/\b(local|depto|dpto|piso|of\.?|oficina|casa|lote|mz|manzana)\s*\S*/gi, '')
    .replace(/\bb[°ºo]\.?\s*/gi, '')
    .replace(/[,;]+\s*$/, '')
    .trim();
  if (limpia.length >= 5 && limpia.toLowerCase() !== dir.toLowerCase()) {
    salida.push(`${limpia}, Córdoba, Argentina`);
  }

  // Solo calle y numero, que es lo que Nominatim resuelve mejor
  const m = /([a-zá-úñ'.\s]+?)\s*(\d{1,5})\b/i.exec(limpia || dir);
  if (m) {
    const corta = `${m[1].trim()} ${m[2]}, Córdoba, Argentina`;
    if (!salida.some((s) => s.toLowerCase() === corta.toLowerCase())) salida.push(corta);
  }
  return salida;
}

/**
 * Una consulta a Nominatim. Devuelve {lat,lng} o null.
 *
 * El primer intento acota la busqueda a Cordoba (bounded=1). Si no
 * encuentra nada, se repite sin acotar y se verifica el resultado a mano:
 * bounded=1 descarta direcciones legitimas que caen justo en el borde de
 * la caja, y esas son barrios enteros de las afueras.
 */
async function preguntar(consulta) {
  for (const acotado of [true, false]) {
    try {
      const url =
        `${NOMINATIM}?format=jsonv2&limit=5&countrycodes=ar` +
        (acotado ? `&viewbox=${encodeURIComponent(VIEWBOX)}&bounded=1` : '') +
        `&q=${encodeURIComponent(consulta)}`;

      const ctrl = new AbortController();
      const corte = setTimeout(() => ctrl.abort(), 6000);
      const r = await fetch(url, {
        headers: { 'User-Agent': UA, 'Accept-Language': 'es' },
        signal: ctrl.signal,
      });
      clearTimeout(corte);
      if (!r.ok) {
        // 403 o 429 = Nominatim nos esta frenando. Insistir empeora las
        // cosas, asi que se corta y se deja que el alta siga sin mapa.
        if (r.status === 403 || r.status === 429) {
          console.warn('[geo] nominatim nos frenó:', r.status);
          return null;
        }
        continue;
      }

      const datos = await r.json();
      if (!Array.isArray(datos)) continue;
      for (const d of datos) {
        const la = Number(d.lat), ln = Number(d.lon);
        // Se verifica siempre, acotado o no: un resultado fuera de Cordoba
        // es peor que ninguno, porque mandaria el pedido al nodo
        // equivocado sin que nadie lo note.
        if (Number.isFinite(la) && Number.isFinite(ln) && dentroDeCordoba(la, ln)) {
          return { lat: la, lng: ln };
        }
      }
    } catch (e) {
      console.warn('[geo] nominatim falló:', e.message);
    }
  }
  return null;
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

  // 2) Nominatim, con varios intentos
  let lat = null, lng = null;
  for (const consulta of variantes(dir)) {
    const r = await preguntar(consulta);
    if (r) { lat = r.lat; lng = r.lng; break; }
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
