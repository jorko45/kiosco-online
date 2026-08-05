// api/crear-pago.js — Vercel Serverless Function
//
// Crea la preferencia de pago de Mercado Pago.
//
// ⚠ REGLA CENTRAL: el precio que cobra Mercado Pago NUNCA sale del navegador.
// Antes, esta funcion tomaba el campo "precio" que mandaba el cliente y armaba
// la orden con ese numero. Cualquiera podia abrir la consola y comprarse un
// Fernet a $1. Ahora cada producto se busca en la planilla de precios del lado
// del servidor y se cobra ESE valor.

import { mapaDePrecios, idDePlanilla } from './_lib/precios.js';

// Costos de envio validos. Tienen que coincidir con index.html:
//   $5.000 -> tarifa normal (DELIVERY_COSTO)
//   $2.000 -> con descuento por credito (DELIVERY_COSTO - DELIVERY_DESCUENTO)
// El credito vive en el localStorage del cliente, asi que el servidor no
// puede verificar que le corresponda. Lo que si puede —y hace— es no
// aceptar ningun otro monto: el peor abuso posible es pagar $2.000 en vez
// de $5.000, no $1.
const ENVIOS_VALIDOS = [5000, 2000];
const ENVIO = 5000;

// Diferencia tolerada entre lo que muestra la web y lo que dice la planilla.
// Cero: si no coinciden, algo esta mal y no se cobra a ciegas.
const TOLERANCIA = 0;

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Método no permitido' });

  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
    const { items } = body;

    if (!Array.isArray(items) || !items.length) {
      return res.status(400).json({ error: 'No hay productos en el pedido' });
    }
    if (items.length > 100) {
      return res.status(400).json({ error: 'Demasiados productos en el pedido' });
    }

    // ── Precios reales ────────────────────────────────────────────────
    const precios = await mapaDePrecios();

    // Si la planilla no responde, se sigue vendiendo con los precios del
    // navegador. Es una decision consciente: perder todas las ventas
    // mientras Google Sheets esta caido es peor que la ventana de riesgo.
    // Queda en el log para poder detectarlo.
    const validando = Boolean(precios);
    if (!validando) {
      console.error('[crear-pago] SIN VALIDACION DE PRECIOS: la planilla no respondió');
    }

    const mpItems = [];
    let totalServidor = 0;
    let totalCliente = 0;

    for (const it of items) {
      const cantidad = Math.floor(Number(it.cantidad) || 0);
      const precioCliente = Math.round(Number(it.precio) || 0);
      const nombre = String(it.nombre || '').trim().slice(0, 250);

      if (!nombre || cantidad < 1 || cantidad > 999 || precioCliente < 0) {
        return res.status(400).json({ error: `Producto inválido: ${nombre || 'sin nombre'}` });
      }

      let precioFinal = precioCliente;

      if (String(it.id) === '__envio') {
        // El envio no esta en la planilla: se valida contra la lista blanca.
        if (ENVIOS_VALIDOS.includes(precioCliente)) {
          precioFinal = precioCliente;
        } else {
          precioFinal = ENVIO;
          console.warn('[crear-pago] envío alterado:', precioCliente, '→', ENVIO);
        }
        if (cantidad !== 1) {
          return res.status(400).json({ error: 'Envío inválido' });
        }
      } else if (validando) {
        const id = idDePlanilla(it.id);
        const real = id ? precios.get(id) : undefined;

        if (real === undefined) {
          // El producto no esta en la planilla o esta inactivo. La web filtra
          // esos productos, asi que llegar aca significa carrito viejo o
          // manipulacion. En cualquier caso, no se cobra.
          console.warn('[crear-pago] producto fuera de la lista:', it.id, nombre);
          return res.status(409).json({
            error: 'Algunos productos ya no están disponibles. Recargá la página y armá el pedido de nuevo.',
          });
        }

        if (Math.abs(real - precioCliente) > TOLERANCIA) {
          // Precio distinto: o la pagina quedo vieja (el scraper actualiza
          // todas las noches) o alguien lo manipulo. En los dos casos hay que
          // frenar: el cliente tiene que pagar lo que vio, no otra cosa.
          console.warn('[crear-pago] precio no coincide:', {
            id: it.id, nombre, cliente: precioCliente, planilla: real,
          });
          return res.status(409).json({
            error: 'Los precios se actualizaron mientras armabas el pedido. Recargá la página para ver los valores nuevos.',
          });
        }
        precioFinal = real;
      }

      totalCliente += precioCliente * cantidad;
      totalServidor += precioFinal * cantidad;

      mpItems.push({
        title: nombre,
        quantity: cantidad,
        unit_price: precioFinal,     // ← siempre el precio del servidor
        currency_id: 'ARS',
        picture_url: 'https://k24hs.com/img/k24-logo.png',
      });
    }

    if (totalServidor !== totalCliente) {
      console.warn('[crear-pago] total corregido:', totalCliente, '→', totalServidor);
    }
    if (totalServidor <= 0) {
      return res.status(400).json({ error: 'El total del pedido no es válido' });
    }

    const ACCESS_TOKEN = process.env.MP_ACCESS_TOKEN;
    if (!ACCESS_TOKEN) {
      return res.status(500).json({ error: 'Token de Mercado Pago no configurado' });
    }

    const siteUrl = 'https://k24hs.com';
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

    return res.status(200).json({ init_point: data.init_point, total: totalServidor });

  } catch (err) {
    console.error('[crear-pago]', err.message);
    return res.status(500).json({ error: 'Error interno', detalle: err.message });
  }
}
