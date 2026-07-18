// api/precios.js — Vercel Serverless Function
// Proxy de lectura al Apps Script (planilla "Precios K24"). Evita CORS.
// Devuelve { ok, items:[[id, precioVenta, precioSugerido, activo], ...] }.
// La web usa esto para pisar precios y ocultar productos borrados/inactivos.

const SCRIPT_URL = 'https://script.google.com/macros/s/AKfycbz48Hs8pcO-ewcmnxaHrS-eBrcVk-llMdaCxjNyCXOdP99SahO7X84w-97bs_JvuzOL/exec';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  // Cache de 2 min (los cambios en la planilla se ven en la web a los ~2 min)
  res.setHeader('Cache-Control', 'public, max-age=120, s-maxage=120');
  try {
    const r = await fetch(SCRIPT_URL + '?action=precios', { redirect: 'follow' });
    const text = await r.text();
    let data;
    try { data = JSON.parse(text); } catch (e) { data = { ok: false, items: [] }; }
    return res.status(200).json(data);
  } catch (err) {
    return res.status(200).json({ ok: false, items: [], error: err.message });
  }
}
