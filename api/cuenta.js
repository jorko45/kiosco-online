// api/cuenta.js — Vercel Serverless Function
// Proxy para las operaciones de cuenta (login, check_usuario, registrar).
// El navegador habla con este endpoint (mismo origen) y acá reenviamos al
// Apps Script por POST, devolviendo el JSON. Evita problemas de CORS al leer
// la respuesta del Apps Script directamente desde el browser.

const SCRIPT_URL = 'https://script.google.com/macros/s/AKfycbxHw92ciow84P-SFFgABT4i04OH21qbaTuOsXM0PPbG2pxA6BcoA3kBuK2rD7dWqdYZGw/exec';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Cache-Control', 'no-store');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') {
    return res.status(405).json({ ok: false, error: 'Método no permitido' });
  }

  try {
    const body = typeof req.body === 'string' ? req.body : JSON.stringify(req.body || {});
    const r = await fetch(SCRIPT_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
      redirect: 'follow',
    });
    const text = await r.text();
    let data;
    try { data = JSON.parse(text); } catch (e) { data = { ok: false, error: 'respuesta no válida' }; }
    return res.status(200).json(data);
  } catch (err) {
    return res.status(200).json({ ok: false, error: err.message });
  }
}
