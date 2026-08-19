// ═══════════════════════════════════════════════════════════════════
//  Lector de listas de precios
//
//  Convierte el texto suelto de un PDF, un Excel copiado o un mensaje
//  de WhatsApp en filas de (producto, precio).
//
//  ESTE ARCHIVO ES LA COPIA DE REFERENCIA, PARA PODER PROBARLO CON
//  NODE. El mismo codigo va embebido en kiosco.html. Si cambia uno,
//  cambian los dos.
//
//  REGLA DE ORO: esto se equivoca. Siempre. Las listas vienen en
//  cualquier formato y ninguna heuristica las cubre todas. Por eso el
//  resultado NUNCA se guarda directo: se muestra en una tabla editable
//  y el kiosquero confirma. Un precio mal leido es plata.
// ═══════════════════════════════════════════════════════════════════

// Un numero argentino: 1.500 · 1.500,50 · 1500 · $ 2.399,99
const NUM = /(?:\$\s*)?(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:,\d{1,2})?)/g;

function aNumero(txt) {
  if (!txt) return 0;
  let s = String(txt).replace(/\$/g, '').trim();
  // Formato argentino: el punto separa miles, la coma decimales.
  if (s.includes('.') && s.includes(',')) s = s.replace(/\./g, '').replace(',', '.');
  else if (s.includes('.') && /\.\d{3}\b/.test(s)) s = s.replace(/\./g, '');
  else if (s.includes(',')) s = s.replace(',', '.');
  const n = parseFloat(s);
  return Number.isFinite(n) ? n : 0;
}

// Lineas que no son productos: encabezados, totales, pie de pagina.
const RUIDO = /^(lista|precios?|vigenc|actualiz|total|subtotal|iva|pagina|p[aá]g\.?\s*\d|tel[eé]fono|whatsapp|direcci[oó]n|www\.|http|cuit|razon social|hoja \d)/i;

/**
 * @param {string} texto  el contenido crudo
 * @returns {{filas: Array<{nombre:string, precio:number}>, descartadas: number}}
 */
function leerLista(texto) {
  const filas = [];
  let descartadas = 0;
  const vistos = new Set();

  for (let linea of String(texto || '').split(/\r?\n/)) {
    linea = linea.replace(/\s+/g, ' ').trim();
    if (linea.length < 3) continue;
    if (RUIDO.test(linea)) { descartadas++; continue; }

    const nums = linea.match(NUM);
    if (!nums || !nums.length) { descartadas++; continue; }

    // El precio es el ULTIMO numero de la linea. En casi todas las listas
    // el producto va a la izquierda y el precio a la derecha; y cuando el
    // nombre lleva numeros (500 ml, x12, 2 lt) esos quedan antes.
    const crudo = nums[nums.length - 1];
    const precio = aNumero(crudo);

    // Lo que queda sacando ese numero es el nombre.
    const corte = linea.lastIndexOf(crudo);
    // El orden importa: primero se juntan los espacios, despues se sacan
    // los separadores del final. Al reves, un "- " con espacio detras no
    // matchea el ancla de fin y queda pegado al nombre.
    let nombre = (linea.slice(0, corte) + ' ' + linea.slice(corte + crudo.length))
      .replace(/\$/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .replace(/[\s.\-–—_·|:]+$/g, '')
      .trim();

    // Un precio de menos de 10 pesos casi seguro es una cantidad mal leida
    // ("x 6 un"), no un precio. Preferimos descartarlo a cargar basura.
    if (!nombre || nombre.length < 2 || precio < 10) { descartadas++; continue; }

    const clave = nombre.toLowerCase();
    if (vistos.has(clave)) { descartadas++; continue; }
    vistos.add(clave);

    filas.push({ nombre: nombre.slice(0, 200), precio: Math.round(precio) });
  }

  return { filas, descartadas };
}

if (typeof module !== 'undefined') module.exports = { leerLista, aNumero };
