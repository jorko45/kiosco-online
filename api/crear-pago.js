// api/crear-pago.js — Vercel Serverless Function

export default async function handler(req, res) {
  // Solo POST
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Método no permitido' });
  }

  try {
    const { items } = req.body;

    if (!items || !items.length) {
      return res.status(400).json({ error: 'No hay productos en el pedido' });
    }

    const mpItems = items.map((it) => ({
      title: it.nombre,
      quantity: it.cantidad,
      unit_price: Number(it.precio),
      currency_id: 'ARS',
    }));

    const ACCESS_TOKEN = process.env.MP_ACCESS_TOKEN;
    const siteUrl = process.env.VERCEL_URL
      ? `https://${process.env.VERCEL_URL}`
      : 'https://fluffy-tartufo-81a96a.netlify.app';

    const body = {
      items: mpItems,
      back_urls: {
        success: `${siteUrl}/?pago=exitoso`,
        failure: `${siteUrl}/?pago=fallido`,
        pending: `${siteUrl}/?pago=pendiente`,
      },
      auto_return: 'approved',
    };

    const resp = await fetch('https://api.mercadopago.com/checkout/preferences', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${ACCESS_TOKEN}`,
      },
      body: JSON.stringify(body),
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
