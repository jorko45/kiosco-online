# Resumen de trabajo — K24 (kiosco online 24hs, Córdoba)

*Sitio: https://k24hs.com · Repo: github.com/jorko45/kiosco-online*
*Documento generado el 29-jul-2026*

---

## Legales y verificación +18

- Casilla **"Soy mayor de 18 años"** en el registro, guardada en la cuenta.
- **Bloqueo de compra** de alcohol y tabaco para usuarios no verificados.
- **Botón y formulario de arrepentimiento** en el inicio, con su hoja en la planilla (Ley 24.240).

## Precios (la parte más grande)

- **Planilla única "precios editable google"** como fuente de verdad de todos los precios. Columnas: ID · Sección · Categoría · Producto · Costo · Margen % · MP % · Precio Sugerido · Precio Venta · Activo. La web los lee en vivo vía `/api/precios`.
- **Actualización automática diaria (23:00)** desde tu PC con el Programador de tareas de Windows: scrapea el Super Mami y la Distribuidora y actualiza solo los costos. El margen y el precio sugerido se recalculan solos.
- **Tres protecciones** en la actualización:
  - *Freno de seguridad*: no aplica un precio si saltaría más del **30%** (evita errores de mapeo).
  - *Reintentos* automáticos si el scrapeo falla.
  - *Salvaguarda*: si una fuente trae menos del 60% de lo esperado, no desactiva nada (no vacía el catálogo si el proveedor se cae).
- **Decisión: bebidas, cervezas, botellas y promos = manuales.** No hay fuente confiable para automatizarlas (el Mami no expone código de barras — probado). Esas **428 filas quedaron pintadas de naranja** en la planilla para distinguirlas de las que se actualizan solas.
- Correcciones de precios que estaban mal (Fernet, salchichas, Cepita) y **Excel de revisión de bebidas**.

## Chatbot, zonas y analítica

- **Arreglo del chatbot** que no se veía (problema de z-index / stacking). Ahora además se **oculta al abrir el carrito** y se puede **cerrar con una ✕** (con pestañita para reabrirlo).
- Sección **"¿Todavía no llegamos a tu zona?"** que registra demanda de ciudades fuera de cobertura en una hoja — sirve para decidir a dónde expandir el reparto.
- **Analítica**: contador de visitas (Vercel Web Analytics) y registro de búsquedas (para ver qué buscan los clientes y no tenés en stock).

## Carrito y caja

- **Carrito separado de la caja**: "🧾 Ir a pagar" abre una **página aparte** con el resumen del pedido y las opciones de pago (MercadoPago y WhatsApp).
- **Registro abierto a todos**: cualquiera puede crear cuenta, viva donde viva. La **compra se bloquea** solo si la dirección está fuera de Córdoba Capital (13 km del centro), ofreciéndole anotarse para cuando lleguen.

## Cositas técnicas

- Se endureció el flujo de **`subir.bat`** (rompía con el error "rigin" al hacer git pull sobre el .bat en ejecución).
- Se sacó la sugerencia **"admin"** del buscador (autocompletado del navegador).
- Se resolvió un conflicto de merge conservando toda la versión completa sin perder nada.
- `CONTEXTO_K24.md` se mantiene actualizado con todas las decisiones.

---

## Pendientes (manuales, solo los podés hacer vos)

1. **Activar Analytics** en el panel de Vercel → pestaña Analytics → Enable (un clic).
2. **Corregir a mano en la planilla** los precios de las filas naranjas (los packs de cerveza y el Fernet).
