// api/registrar-usuario.js — Vercel Serverless Function
// Recibe los datos del usuario y los guarda en Google Sheets

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Método no permitido' });

  const SHEET_URL = process.env.GOOGLE_SHEET_URL;
  if (!SHEET_URL) {
    // Si no está configurado, igual devolvemos OK para no bloquear la compra
    return res.status(200).json({ ok: true, msg: 'Sin configurar' });
  }

  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;

    const resp = await fetch(SHEET_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });

    const data = await resp.json();
    return res.status(200).json(data);

  } catch (err) {
    // Error silencioso — no bloqueamos la compra si falla el registro
    return res.status(200).json({ ok: false, error: err.message });
  }
}
