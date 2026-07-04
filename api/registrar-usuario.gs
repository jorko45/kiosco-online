// K24 — Apps Script para guardar registros de usuarios
// 1. Pegá este código en Apps Script (Extensiones → Apps Script)
// 2. Cambiá SHEET_ID por el ID de tu Google Sheet
// 3. Desplegá como app web: Implementar → Nueva implementación
//    - Tipo: App web
//    - Ejecutar como: Yo
//    - Acceso: Cualquier persona
// 4. Copiá la URL de implementación y guardala como variable de entorno
//    GOOGLE_SHEET_URL en Vercel

const SHEET_ID = 'TU_SHEET_ID_ACA'; // ← cambiá esto

function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    const sheet = SpreadsheetApp.openById(SHEET_ID).getActiveSheet();

    // Si es la primera fila, agregar encabezados
    if (sheet.getLastRow() === 0) {
      sheet.appendRow(['Fecha', 'Nombre', 'Teléfono', 'Dirección', 'Piso', 'Barrio', 'Referencia', 'Coordenadas']);
    }

    const coords = data.coords
      ? `https://maps.google.com/?q=${data.coords.lat},${data.coords.lng}`
      : '';

    sheet.appendRow([
      new Date().toLocaleString('es-AR'),
      data.nombre     || '',
      data.telefono   || '',
      data.direccion  || '',
      data.piso       || '',
      data.barrio     || '',
      data.referencia || '',
      coords,
    ]);

    return ContentService
      .createTextOutput(JSON.stringify({ ok: true }))
      .setMimeType(ContentService.MimeType.JSON);

  } catch (err) {
    return ContentService
      .createTextOutput(JSON.stringify({ ok: false, error: err.message }))
      .setMimeType(ContentService.MimeType.JSON);
  }
}

// Para probar manualmente desde Apps Script
function testPost() {
  doPost({ postData: { contents: JSON.stringify({
    nombre: 'Test Usuario',
    telefono: '351 000 0000',
    direccion: 'Av. Test 123',
    piso: '1A',
    barrio: 'Centro',
    referencia: 'Esquina test',
    coords: { lat: -31.4201, lng: -64.1888 }
  })}});
}
