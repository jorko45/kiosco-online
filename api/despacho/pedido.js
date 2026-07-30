// api/despacho/pedido.js — POST /api/despacho/pedido
// Crea un pedido. Lo llama el checkout del sitio (publico, sin login).

import { insertar, json, cors, cuerpo, dbConfigurada } from '../_lib/db.js';
import { geocodificar } from '../_lib/geo.js';

const MAX_ITEMS = 100;
const TOPE_TOTAL = 5_000_000; // freno de cordura: nadie pide 5 millones de pesos

export default async function handler(req, res) {
  if (cors(req, res, 'POST, OPTIONS')) return;
  if (req.method !== 'POST') return json(res, 405, { ok: false, error: 'Metodo no permitido' });

  // Si todavia no hay base configurada, no rompemos la compra:
  // el sitio sigue funcionando por WhatsApp como hasta ahora.
  if (!dbConfigurada()) {
    return json(res, 200, { ok: false, sin_configurar: true, error: 'Despacho no configurado' });
  }

  const b = cuerpo(req);

  // ── Validacion ──────────────────────────────────────────────────
  const direccion = String(b.direccion || '').trim();
  if (direccion.length < 5) {
    return json(res, 400, { ok: false, error: 'Falta la direccion de entrega' });
  }

  const items = Array.isArray(b.items) ? b.items : [];
  if (!items.length) return json(res, 400, { ok: false, error: 'El pedido no tiene productos' });
  if (items.length > MAX_ITEMS) return json(res, 400, { ok: false, error: 'Demasiados productos' });

  const limpios = [];
  let subtotal = 0;
  for (const it of items) {
    const nombre = String(it.name ?? it.nombre ?? '').trim().slice(0, 200);
    const qty = Number(it.qty ?? it.cantidad);
    const precio = Number(it.price ?? it.precio);
    if (!nombre || !Number.isFinite(qty) || !Number.isFinite(precio)) {
      return json(res, 400, { ok: false, error: 'Producto con datos invalidos' });
    }
    if (qty < 1 || qty > 999 || precio < 0) {
      return json(res, 400, { ok: false, error: `Cantidad o precio fuera de rango en "${nombre}"` });
    }
    const q = Math.floor(qty);
    const p = Math.round(precio);
    limpios.push({ nombre, size: String(it.size ?? '').slice(0, 60), qty: q, precio: p });
    subtotal += q * p;
  }

  const envio = Math.max(0, Math.round(Number(b.envio) || 0));
  const total = subtotal + envio;

  if (total > TOPE_TOTAL) {
    return json(res, 400, { ok: false, error: 'El total supera el limite permitido' });
  }

  // El total lo recalcula el servidor. Si el cliente mando otro, avisamos
  // en el log pero mandamos el nuestro: nunca se confia en el navegador.
  if (b.total != null && Math.abs(Number(b.total) - total) > 1) {
    console.warn('[despacho] total del cliente distinto del calculado', {
      cliente: Number(b.total), servidor: total,
    });
  }

  const metodo = ['efectivo', 'mercadopago', 'transferencia'].includes(b.metodo_pago)
    ? b.metodo_pago
    : null;

  // ── Coordenadas ─────────────────────────────────────────────────
  // Si el cliente compartio ubicacion, usamos esa (es la buena).
  // Si escribio la direccion a mano, la geocodificamos: sin coordenadas
  // no hay forma de elegir el punto de preparacion mas cercano.
  let lat = Number.isFinite(Number(b.lat)) ? Number(b.lat) : null;
  let lng = Number.isFinite(Number(b.lng)) ? Number(b.lng) : null;
  let origenCoords = lat !== null ? 'cliente' : null;

  if (lat === null || lng === null) {
    const g = await geocodificar(direccion);
    if (g) {
      lat = g.lat;
      lng = g.lng;
      origenCoords = g.origen;
    }
  }

  const fila = {
    estado: 'nuevo',
    ultimo_actor: 'cliente',
    cliente_nombre: String(b.cliente_nombre || '').trim().slice(0, 120) || null,
    cliente_telefono: String(b.cliente_telefono || '').trim().slice(0, 40) || null,
    cliente_email: String(b.cliente_email || '').trim().slice(0, 160) || null,
    direccion: direccion.slice(0, 300),
    direccion_notas: String(b.direccion_notas || '').trim().slice(0, 300) || null,
    lat,
    lng,
    items: limpios,
    subtotal,
    envio,
    total,
    metodo_pago: metodo,
    pagado: false,
    mp_payment_id: b.mp_payment_id ? String(b.mp_payment_id).slice(0, 80) : null,
    // Con cuanto paga: solo si es efectivo y cubre el total.
    // La base tiene un check por si acaso, pero mejor no llegar a el.
    paga_con:
      metodo === 'efectivo' && Number.isFinite(Number(b.paga_con)) && Number(b.paga_con) >= total
        ? Math.round(Number(b.paga_con))
        : null,
  };

  try {
    const p = await insertar('pedidos', fila);
    if (!origenCoords) {
      // No es un error, pero conviene que quede en el log: si esto se
      // repite mucho, la asignacion automatica no va a poder funcionar.
      console.warn('[despacho] pedido sin coordenadas:', p.codigo, direccion);
    }
    return json(res, 201, {
      ok: true,
      pedido: {
        id: p.id,
        codigo: p.codigo,
        estado: p.estado,
        total: p.total,
        ubicado: Boolean(origenCoords),
        seguimiento: `/seguimiento.html?t=${p.token_seguimiento}`,
      },
    });
  } catch (e) {
    console.error('[despacho] error creando pedido:', e.message, e.detalle || '');
    // Devolvemos 200 con ok:false a proposito: el front no debe bloquear
    // la compra porque falle el despacho. Cae al flujo de WhatsApp.
    return json(res, 200, { ok: false, error: 'No se pudo registrar el pedido' });
  }
}
