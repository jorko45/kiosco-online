# K24 · Sistema de despacho de flota

Reemplaza el "pedido = mensaje de WhatsApp" por un pedido de verdad: con código,
estado, repartidor asignado, historial y seguimiento para el cliente.

---

## Qué son las tres pantallas

| Pantalla | URL | Quién entra | Cómo |
|---|---|---|---|
| Panel de despacho | `/despacho.html` | Vos / quien atiende | Clave única |
| App del repartidor | `/repartidor.html` | Cada repartidor | Teléfono + PIN |
| Seguimiento | `/seguimiento.html?t=…` | El cliente | Sin login, link por pedido |

---

## Cómo viaja un pedido

```
  El cliente compra en k24hs.com
            ↓
      [ nuevo ]          ← aparece en el panel y suena la alerta
            ↓  confirmás
   [ confirmado ]
            ↓  lo armás
   [ preparando ]
            ↓  asignás repartidor
    [ asignado ]         ← le aparece en el celular al repartidor
            ↓  el repartidor toca "Retiré el pedido"
    [ en_camino ]        ← acá arranca el seguimiento en vivo del cliente
            ↓  toca "Entregué"
    [ entregado ]
```

Desde cualquier estado se puede pasar a `cancelado`, siempre con motivo.

Las transiciones inválidas las rechaza la base de datos, no la app. Así la regla
vale aunque alguien toque los datos desde otro lado o haya un bug en el front.

---

## Instalación

### 1 · Crear el proyecto en Supabase

[supabase.com](https://supabase.com) → New project. Región **South America (São Paulo)**,
que es la más cercana a Córdoba y baja bastante la latencia.

Guardate la contraseña de la base cuando te la muestre: no se vuelve a ver.

### 2 · Crear las tablas

SQL Editor → New query → pegar **todo** `sql/01_esquema.sql` → Run.
Repetir con `sql/02_mantenimiento.sql`.

Los dos son idempotentes: se pueden correr de nuevo sin romper nada.

### 3 · Variables de entorno en Vercel

Project Settings → Environment Variables. Las cuatro, en Production y Preview:

| Variable | De dónde sale |
|---|---|
| `SUPABASE_URL` | Supabase → Settings → API → Project URL |
| `SUPABASE_SERVICE_KEY` | Supabase → Settings → API → **service_role** |
| `ADMIN_PASSWORD` | La inventás vos. Es la clave del panel. |
| `DESPACHO_SECRET` | Cadena aleatoria larga. Firma los tokens de sesión. |

Para generar el secreto, en la consola del navegador:

```js
crypto.randomUUID() + crypto.randomUUID()
```

> ⚠️ **`SUPABASE_SERVICE_KEY` saltea todas las reglas de seguridad de la base.**
> Solo puede vivir en las variables de entorno de Vercel. Nunca en el HTML,
> nunca en el repo, nunca en un mensaje. Si se filtra, cualquiera lee y borra todo.
> La que empieza con `anon` no sirve acá y tampoco hay que ponerla en el front.

Después de cargarlas hay que **redeployar** para que las tome.

### 4 · Cargar los repartidores

SQL Editor, uno por repartidor:

```sql
select crear_repartidor('Nombre Apellido', '3513260094', '1234');
```

El teléfono es el usuario y el PIN va hasheado con bcrypt — en la tabla no queda
el PIN en claro.

Para cambiar un PIN:

```sql
update repartidores
   set pin_hash = crypt('5678', gen_salt('bf'))
 where telefono = '3513260094';
```

Para dar de baja a alguien sin borrar su historial:

```sql
update repartidores set activo = false where telefono = '3513260094';
```

### 5 · Probar antes de usarlo en serio

1. Entrá a `/despacho.html` con tu `ADMIN_PASSWORD`
2. Hacé una compra de prueba en el sitio — tiene que aparecer sola en el panel
3. Confirmá → Preparando → asignate un repartidor
4. Abrí `/repartidor.html` en el celular, entrá con teléfono y PIN
5. Abrí el turno, tocá "Retiré el pedido"
6. Abrí el link de seguimiento y comprobá que el mapa muestre la moto
7. Tocá "Entregué"

Si el paso 2 no pasa, mirá los logs en Vercel → Deployments → Functions.

---

## Costo

Con 20–60 pedidos por día, el plan gratis de Supabase alcanza de sobra:
500 MB de base y 5 GB de tráfico.

Lo único que crece rápido son las posiciones GPS, y para eso está
`limpiar_posiciones()` en `02_mantenimiento.sql`. **Programala con pg_cron**
(instrucciones en ese mismo archivo) o la tabla se va a comer el espacio en
unos meses.

---

## Límites conocidos

Estas son cosas que sé que no están resueltas. Prefiero listarlas a que
aparezcan de golpe en producción.

**1 · El GPS de una PWA se corta con la pantalla apagada.**
Es una limitación del navegador, no del código. La app pide `wakeLock` para
que la pantalla no se duerma, pero si el repartidor bloquea el celular o
cambia de app un rato largo, el seguimiento se congela hasta que vuelva.
La única solución completa es una app nativa. Con 1–3 repartidores conviene
convivir con esto antes que meterse en Play Store.

**2 · El freno de intentos de login es débil.**
Está en memoria del proceso, y Vercel reparte las llamadas entre varias
instancias. Frena a alguien probando PINes a mano, no a un ataque en serio.
Si en algún momento hay repartidores que no son de tu confianza directa,
hay que moverlo a la base o a Upstash.

**3 · Los precios del pedido vienen del navegador.** ⚠️
El servidor recalcula el total a partir de los items, pero **no verifica que
el precio de cada producto sea el real**. Alguien con conocimientos técnicos
podría enviar una Coca a $1.

Esto **ya pasa hoy** en `api/crear-pago.js`, que arma la orden de MercadoPago
con los precios que manda el navegador — no lo introduce este sistema. Pero
ahora que hay pedidos registrados conviene cerrarlo: el arreglo es que el
servidor lea la lista de `/api/precios` y valide cada item contra ella.
**Recomiendo hacerlo antes de escalar la publicidad**, porque más tráfico es
más probabilidad de que alguien lo pruebe.

**4 · No hay notificaciones push.**
El repartidor se entera de un pedido nuevo cuando la app refresca, cada 12
segundos con la pantalla abierta. Alcanza para una flota chica; para más
haría falta Web Push.

**5 · La asignación es manual.**
A propósito: con 1–3 repartidores, un humano decide mejor que un algoritmo.
La lógica está desacoplada, así que sumar asignación automática por cercanía
después no obliga a rehacer nada.

---

## Qué NO toca este sistema

Para que quede claro qué sigue funcionando igual que siempre:

- El sitio sigue vendiendo aunque el despacho esté caído. Si la API falla, el
  pedido cae al flujo de WhatsApp de siempre.
- Google Sheets sigue siendo la fuente de precios, cuentas y buzón. Solo los
  **pedidos** se mudan a Supabase.
- `SUBIR.bat`, el scraper de precios y la actualización diaria quedan intactos.

---

## Archivos

| Archivo | Qué es |
|---|---|
| `sql/01_esquema.sql` | Tablas, triggers, máquina de estados, RLS |
| `sql/02_mantenimiento.sql` | Limpieza de GPS, cierre de turnos, consultas útiles |
| `/despacho.html` | Panel de despacho |
| `/repartidor.html` | PWA del repartidor |
| `/seguimiento.html` | Seguimiento público |
| `/api/_lib/db.js` | Cliente de Supabase por REST |
| `/api/_lib/auth.js` | Tokens firmados y control de acceso |
| `/api/despacho/pedido.js` | Alta de pedido (público) |
| `/api/despacho/login.js` | Login de panel y de repartidor |
| `/api/despacho/cola.js` | Cola de despacho (panel) |
| `/api/despacho/estado.js` | Cambio de estado y asignación |
| `/api/despacho/repartidor.js` | Pedidos propios, turno y posición |
| `/api/despacho/seguimiento.js` | Vista pública por token |
