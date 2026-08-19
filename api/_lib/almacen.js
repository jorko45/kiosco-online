// api/_lib/almacen.js — archivos privados en Supabase Storage
//
// Va en _lib y no en api/ a proposito: los archivos que empiezan con _ no
// cuentan como funciones en Vercel, y el plan Hobby permite 12. Ya estamos
// en 12.
//
// EL BUCKET ES PRIVADO Y NO SE NEGOCIA
// Aca adentro hay licencias de conducir y polizas con nombre, DNI y
// domicilio. Un bucket publico significa que cualquiera con el link ve el
// documento de una persona, y los links se filtran solos: quedan en
// historiales, en capturas, en mensajes reenviados.
//
// Por eso no existe una funcion que devuelva una URL permanente. Para ver
// un archivo hay que pedir una firma que dura minutos y se vence.

const BUCKET = 'documentos';

function base() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_KEY;
  if (!url || !key) throw new Error('Falta configurar SUPABASE_URL o SUPABASE_SERVICE_KEY');
  return { url: url.replace(/\/+$/, ''), key };
}

function cabeceras(key, extra = {}) {
  return { apikey: key, Authorization: `Bearer ${key}`, ...extra };
}

/** Crea el bucket privado si todavia no existe. Es idempotente. */
export async function asegurarBucket() {
  const { url, key } = base();
  const r = await fetch(`${url}/storage/v1/bucket`, {
    method: 'POST',
    headers: cabeceras(key, { 'Content-Type': 'application/json' }),
    body: JSON.stringify({
      id: BUCKET,
      name: BUCKET,
      public: false,                 // <- lo importante
      file_size_limit: 6 * 1024 * 1024,
      allowed_mime_types: ['image/jpeg', 'image/png', 'image/webp', 'application/pdf'],
    }),
  });
  // 409 = ya existe, que es exactamente lo que queremos la segunda vez.
  if (!r.ok && r.status !== 409) {
    const t = await r.text();
    throw new Error(`No se pudo preparar el almacen: ${t.slice(0, 200)}`);
  }
  return BUCKET;
}

/**
 * Sube un archivo que vino como data URL desde el navegador.
 * Devuelve la ruta interna, nunca una URL publica.
 */
export async function guardarArchivo(ruta, dataUrl) {
  const m = /^data:([\w/+.-]+);base64,(.+)$/s.exec(String(dataUrl || ''));
  if (!m) throw new Error('El archivo no llegó en un formato que podamos leer');

  const tipo = m[1];
  const permitidos = ['image/jpeg', 'image/png', 'image/webp', 'application/pdf'];
  if (!permitidos.includes(tipo)) {
    throw new Error('Solo aceptamos fotos (JPG, PNG) o PDF');
  }

  const bytes = Buffer.from(m[2], 'base64');
  if (bytes.length > 6 * 1024 * 1024) {
    throw new Error('El archivo es muy grande. Sacá la foto con menos calidad.');
  }

  await asegurarBucket();
  const { url, key } = base();

  const r = await fetch(`${url}/storage/v1/object/${BUCKET}/${ruta}`, {
    method: 'POST',
    headers: cabeceras(key, { 'Content-Type': tipo, 'x-upsert': 'true' }),
    body: bytes,
  });
  if (!r.ok) {
    const t = await r.text();
    throw new Error(`No se pudo guardar el archivo: ${t.slice(0, 200)}`);
  }
  return ruta;
}

/**
 * Link temporal para mirar un documento. Por defecto 5 minutos: alcanza
 * para abrirlo y revisarlo, y no sobrevive a que alguien reenvie el link.
 */
export async function linkTemporal(ruta, segundos = 300) {
  const { url, key } = base();
  const r = await fetch(`${url}/storage/v1/object/sign/${BUCKET}/${ruta}`, {
    method: 'POST',
    headers: cabeceras(key, { 'Content-Type': 'application/json' }),
    body: JSON.stringify({ expiresIn: segundos }),
  });
  if (!r.ok) return null;
  const d = await r.json();
  return d?.signedURL ? `${url}/storage/v1${d.signedURL}` : null;
}

/** Borra un archivo. Lo usa el borrado automatico a los 90 dias. */
export async function borrarArchivo(ruta) {
  const { url, key } = base();
  const r = await fetch(`${url}/storage/v1/object/${BUCKET}/${ruta}`, {
    method: 'DELETE',
    headers: cabeceras(key),
  });
  return r.ok;
}
