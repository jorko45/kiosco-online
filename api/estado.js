// api/estado.js — Vercel Serverless Function
// Proxy de lectura al Apps Script (evita CORS al leer desde el navegador).
// Devuelve { encontrado, perfil, carrito, deseos } para sincronizar entre
// dispositivos.

const SCRIPT_URL = 'https://script.google.com/macros/s/AKfycbxHw92ciow84P-SFFgABT4i04OH21qbaTuOsXM0PPbG2pxA6BcoA3kBuK2rD7dWqdYZGw/exec';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Cache-Control', 'no-store');

  const telefono = (req.query.telefono || '').toString();
  const email = (req.query.email || '').toString();
  if (!telefono && !email) {
    return res.status(200).json({ ok: true, encontrado: false });
  }

  try {
    const url = SCRIPT_URL + '?action=estado'
      + '&telefono=' + encodeURIComponent(telefono)
      + '&email=' + encodeURIComponent(email);
    const r = await fetch(url, { redirect: 'follow' });
    const text = await r.text();
    let data;
    try { data = JSON.parse(text); } catch (e) { data = { ok: false, encontrado: false }; }
    return res.status(200).json(data);
  } catch (err) {
    return res.status(200).json({ ok: false, encontrado: false, error: err.message });
  }
}
