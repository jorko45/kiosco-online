// api/precios.js — Vercel Serverless Function
// Lee la planilla de Google (publicada como CSV) y devuelve un mapa
// { clave: precio_final }. La app usa esto para pisar los precios del catálogo.

const CSV_URL = 'https://docs.google.com/spreadsheets/d/e/2PACX-1vRyz-uylzs2IB9Pd05aCJ1ytnDPbaI47jZ9WM2GRRlxjXN7QMZxQLiMmoxjZoZ59w/pub?gid=164874261&single=true&output=csv';

// Parser CSV que respeta comillas
function parseCSV(text) {
  const rows = [];
  let row = [], field = '', inQ = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQ) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; }
        else inQ = false;
      } else field += c;
    } else {
      if (c === '"') inQ = true;
      else if (c === ',') { row.push(field); field = ''; }
      else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
      else if (c === '\r') { /* ignore */ }
      else field += c;
    }
  }
  if (field.length || row.length) { row.push(field); rows.push(row); }
  return rows;
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Cache-Control', 'public, max-age=300, s-maxage=300'); // 5 min de cache

  try {
    const r = await fetch(CSV_URL, { redirect: 'follow' });
    const text = await r.text();
    const rows = parseCSV(text);

    // Buscar la fila de encabezados (la que tiene "Clave")
    let hi = -1;
    for (let i = 0; i < rows.length; i++) {
      if ((rows[i][0] || '').trim().toLowerCase() === 'clave') { hi = i; break; }
    }
    const map = {};
    if (hi >= 0) {
      const head = rows[hi].map(h => (h || '').trim().toLowerCase());
      const iClave = head.indexOf('clave');
      let iFinal = head.indexOf('precio final');
      if (iFinal < 0) iFinal = head.length - 1; // fallback: última columna
      for (let i = hi + 1; i < rows.length; i++) {
        const sku = (rows[i][iClave] || '').trim();
        const precio = parseInt(String(rows[i][iFinal] || '').replace(/[^\d]/g, ''), 10);
        if (sku && precio > 0) map[sku] = precio;
      }
    }
    return res.status(200).json({ ok: true, count: Object.keys(map).length, precios: map });
  } catch (err) {
    return res.status(200).json({ ok: false, precios: {}, error: err.message });
  }
}
