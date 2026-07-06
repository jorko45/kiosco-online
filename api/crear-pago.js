// api/crear-pago.js — Vercel Serverless Function

export default async function handler(req, res) {
  // CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Método no permitido' });

  try {
    // Vercel a veces pasa el body como string
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
    const { items } = body;

    if (!items || !items.length) {
      return res.status(400).json({ error: 'No hay productos en el pedido' });
    }

    const mpItems = items.map((it) => ({
      title: String(it.nombre),
      quantity: Number(it.cantidad) || 1,
      unit_price: Number(it.precio),
      currency_id: 'ARS',
      picture_url: 'https://kiosco-online.vercel.app/img/k24-logo.png',
    }));

    const ACCESS_TOKEN = process.env.MP_ACCESS_TOKEN;

    if (!ACCESS_TOKEN) {
      return res.status(500).json({ error: 'Token de Mercado Pago no configurado' });
    }

    const siteUrl = 'https://kiosco-online.vercel.app';

    const preference = {
      items: mpItems,
      back_urls: {
        success: `${siteUrl}/?pago=exitoso`,
        failure: `${siteUrl}/?pago=fallido`,
        pending: `${siteUrl}/?pago=pendiente`,
      },
      auto_return: 'approved',
      statement_descriptor: 'K24 KIOSCO',
    };

    const resp = await fetch('https://api.mercadopago.com/checkout/preferences', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${ACCESS_TOKEN}`,
      },
      body: JSON.stringify(preference),
    });

    const data = await resp.json();

    if (!resp.ok) {
      return res.status(resp.status).json({ error: 'Error de Mercado Pago', detalle: data });
    }

    return res.status(200).json({ init_point: data.init_point });

  } catch (err) {
    return res.status(500).json({ error: 'Error interno', detalle: err.message });
  }
}
