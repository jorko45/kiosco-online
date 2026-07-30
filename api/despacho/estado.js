// api/despacho/estado.js — POST /api/despacho/estado
// Cambia el estado de un pedido y/o le asigna repartidor.
//
//   { pedido_id, estado }                        → cambia estado
//   { pedido_id, repartidor_id }                 → asigna (y pasa a 'asignado')
//   { pedido_id, estado:'cancelado', motivo }    → cancela
//   { pedido_id, estado:'entregado', receptor }  → entrega con constancia
//
// Las transiciones invalidas las rechaza el trigger de la base, no este
// archivo. Asi la regla vale aunque alguien toque los datos desde otro lado.

import { actualizar, seleccionar, json, cors, cuerpo } from '../_lib/db.js';
import { exigirSesion } from '../_lib/auth.js';

const ESTADOS = ['confirmado', 'preparando', 'asignado', 'en_camino', 'entregado', 'cancelado'];

// Un repartidor solo puede mover SUS pedidos y solo hacia adelante.
const PERMITIDO_REPARTIDOR = ['en_camino', 'entregado'];

export default async function handler(req, res) {
  if (cors(req, res, 'POST, OPTIONS')) return;
  if (req.method !== 'POST') return json(res, 405, { ok: false, error: 'Metodo no permitido' });

  const sesion = exigirSesion(req, res);
  if (!sesion) return;

  const b = cuerpo(req);
  const pedidoId = Number(b.pedido_id);
  if (!Number.isInteger(pedidoId) || pedidoId <= 0) {
    return json(res, 400, { ok: false, error: 'pedido_id invalido' });
  }

  try {
    const filas = await seleccionar('pedidos', {
      select: 'id,codigo,estado,repartidor_id',
      id: `eq.${pedidoId}`,
    });
    const pedido = filas[0];
    if (!pedido) return json(res, 404, { ok: false, error: 'Pedido inexistente' });

    // Queda registrado en la auditoria quien hizo el cambio.
    // Sin esto todos los eventos figuran como "sistema" y no sirve para
    // responder un reclamo.
    const cambios = {
      ultimo_actor: sesion.rol === 'panel' ? 'panel' : `repartidor:${sesion.id}`,
    };

    // ── Punto de preparacion (solo panel) ──────────────────────────
    if (b.punto_id !== undefined) {
      if (sesion.rol !== 'panel') {
        return json(res, 403, { ok: false, error: 'Solo el panel puede elegir el punto' });
      }
      if (b.punto_id === null) {
        cambios.punto_id = null;
        cambios.punto_asignado_at = null;
      } else {
        const pts = await seleccionar('puntos_preparacion', {
          select: 'id,activo',
          id: `eq.${b.punto_id}`,
        });
        if (!pts[0] || !pts[0].activo) {
          return json(res, 400, { ok: false, error: 'Punto de preparacion inexistente o inactivo' });
        }
        cambios.punto_id = b.punto_id;
        cambios.punto_asignado_at = new Date().toISOString();
      }
    }

    // ── Asignacion (solo panel) ────────────────────────────────────
    if (b.repartidor_id !== undefined) {
      if (sesion.rol !== 'panel') {
        return json(res, 403, { ok: false, error: 'Solo el panel puede asignar repartidores' });
      }
      if (b.repartidor_id === null) {
        cambios.repartidor_id = null;
        cambios.asignado_at = null;
        // Al desasignar volvemos a preparando (el trigger valida que se pueda)
        if (!b.estado) cambios.estado = 'preparando';
      } else {
        const reps = await seleccionar('repartidores', {
          select: 'id,activo',
          id: `eq.${b.repartidor_id}`,
        });
        if (!reps[0] || !reps[0].activo) {
          return json(res, 400, { ok: false, error: 'Repartidor inexistente o inactivo' });
        }
        cambios.repartidor_id = b.repartidor_id;
        if (!b.estado && ['nuevo', 'confirmado', 'preparando'].includes(pedido.estado)) {
          cambios.estado = 'asignado';
        }
      }
    }

    // ── Cambio de estado ───────────────────────────────────────────
    if (b.estado !== undefined) {
      if (!ESTADOS.includes(b.estado)) {
        return json(res, 400, { ok: false, error: `Estado invalido: ${b.estado}` });
      }
      if (sesion.rol === 'repartidor') {
        if (pedido.repartidor_id !== sesion.id) {
          return json(res, 403, { ok: false, error: 'Ese pedido no es tuyo' });
        }
        if (!PERMITIDO_REPARTIDOR.includes(b.estado)) {
          return json(res, 403, {
            ok: false,
            error: `Como repartidor solo podés marcar: ${PERMITIDO_REPARTIDOR.join(' o ')}`,
          });
        }
      }
      cambios.estado = b.estado;

      if (b.estado === 'cancelado') {
        const motivo = String(b.motivo || '').trim().slice(0, 300);
        if (!motivo) return json(res, 400, { ok: false, error: 'Falta el motivo de cancelacion' });
        cambios.cancelado_motivo = motivo;
      }
      if (b.estado === 'entregado') {
        if (b.receptor) cambios.entrega_receptor = String(b.receptor).trim().slice(0, 120);
        if (b.nota) cambios.entrega_nota = String(b.nota).trim().slice(0, 300);
        if (b.pagado === true) cambios.pagado = true;
      }
    }

    // ultimo_actor siempre esta, asi que no cuenta como cambio real.
    const cambiosReales = Object.keys(cambios).filter((k) => k !== 'ultimo_actor');
    if (!cambiosReales.length) {
      return json(res, 400, { ok: false, error: 'No se indico ningun cambio' });
    }

    const actualizados = await actualizar('pedidos', { id: `eq.${pedidoId}` }, cambios);
    return json(res, 200, { ok: true, pedido: actualizados[0] });
  } catch (e) {
    // Los errores del trigger de transiciones llegan aca con un mensaje
    // claro en castellano; los mostramos tal cual al panel.
    const esReglaDeNegocio = /Transicion invalida|sin repartidor asignado/.test(e.message || '');
    if (esReglaDeNegocio) {
      return json(res, 409, { ok: false, error: e.message });
    }
    console.error('[despacho] estado:', e.message, e.detalle || '');
    return json(res, 500, { ok: false, error: 'No se pudo actualizar el pedido' });
  }
}
