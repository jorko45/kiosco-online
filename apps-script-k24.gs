// K24 — Google Apps Script (backend sobre Google Sheets)
// Maneja 3 cosas en tu planilla:
//   1) Usuarios → registro de cada persona (1 fila por usuario/telefono, con
//      su ultimo carrito, lista de deseos, y usuario+contrasena)
//   2) Pedidos  → historial de compras (WhatsApp y MercadoPago)
//   3) Estado   → devolver carrito/deseos/perfil para sincronizar entre
//      dispositivos (cuando alguien entra en otro telefono)
//
// COMO INSTALARLO / ACTUALIZARLO:
//   1. Abri tu Google Sheet de K24.
//   2. Menu  Extensiones -> Apps Script.
//   3. Selecciona todo (Ctrl+A), borralo y pega TODO este archivo. Guarda.
//   4. Boton  Implementar -> Gestionar implementaciones -> editar (lapiz) ->
//      Version: "Nueva version" -> Implementar. (Asi la URL /exec sigue igual.)
//
// Las hojas "Usuarios", "Pedidos" y "Estado" se crean solas si no existen.

// Si el script NO esta pegado dentro de la planilla, poné el ID aca:
var SHEET_ID = ''; // dejalo vacio si lo pegaste desde la planilla

function _ss() {
  return SHEET_ID ? SpreadsheetApp.openById(SHEET_ID) : SpreadsheetApp.getActiveSpreadsheet();
}

function _hoja(nombre, headers) {
  var ss = _ss();
  var sh = ss.getSheetByName(nombre);
  if (!sh) {
    sh = ss.insertSheet(nombre);
    sh.appendRow(headers);
    sh.setFrozenRows(1);
  }
  return sh;
}

function _json(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

// Encabezados de la hoja Usuarios (Usuario y PassHash al final para no romper
// planillas viejas que ya tenian las 11 primeras columnas).
var USUARIOS_HEADERS = [
  'Fecha', 'Nombre', 'Telefono', 'Email', 'Direccion',
  'Barrio', 'Referencia', 'Evento', 'Carrito', 'Deseos', 'Foto',
  'Usuario', 'PassHash'
];
var COL_USUARIO = 11;   // indice 0-based
var COL_PASSHASH = 12;

function _hojaUsuarios() {
  var sh = _hoja('Usuarios', USUARIOS_HEADERS);
  if (sh.getLastColumn() < USUARIOS_HEADERS.length) {
    sh.getRange(1, 1, 1, USUARIOS_HEADERS.length).setValues([USUARIOS_HEADERS]);
  }
  return sh;
}

function _norm(s) { return String(s || '').trim().toLowerCase(); }

// POST: registrar usuario / login / check / guardar pedido
function doPost(e) {
  try {
    var body = JSON.parse(e.postData.contents);
    var action = body.action || body.tipo || '';
    if (action === 'guardar_pedido' || action === 'pedido') return _guardarPedido(body);
    if (action === 'login') return _login(body);
    if (action === 'check_usuario') return _checkUsuario(body);
    return _guardarUsuario(body);
  } catch (err) {
    return _json({ ok: false, error: String(err) });
  }
}

// Busca la fila (1-based de la hoja) de un usuario por nombre de usuario, o -1.
function _buscarPorUsuario(sh, usuario) {
  var u = _norm(usuario);
  if (!u) return -1;
  var datos = sh.getDataRange().getValues();
  for (var i = 1; i < datos.length; i++) {
    if (_norm(datos[i][COL_USUARIO]) === u) return i + 1;
  }
  return -1;
}

// Disponibilidad de un nombre de usuario.
function _checkUsuario(b) {
  var sh = _hojaUsuarios();
  return _json({ ok: true, disponible: _buscarPorUsuario(sh, b.usuario) === -1 });
}

// Login: valida usuario + passHash. Devuelve el perfil para sincronizar.
function _login(b) {
  var sh = _hojaUsuarios();
  var fila = _buscarPorUsuario(sh, b.usuario);
  if (fila === -1) return _json({ ok: true, encontrado: false });
  var r = sh.getRange(fila, 1, 1, USUARIOS_HEADERS.length).getValues()[0];
  var hashGuardado = String(r[COL_PASSHASH] || '');
  if (!hashGuardado || hashGuardado !== String(b.passHash || '')) {
    return _json({ ok: true, encontrado: true, auth: false });
  }
  return _json({
    ok: true, encontrado: true, auth: true,
    perfil: {
      usuario: r[COL_USUARIO], nombre: r[1], telefono: r[2], email: r[3],
      direccion: r[4], barrio: r[5], referencia: r[6], foto: r[10] || ''
    },
    carrito: _parse(r[8]),
    deseos: _parse(r[9])
  });
}

// Usuarios: 1 fila por usuario (o telefono si no hay usuario).
function _guardarUsuario(b) {
  var sh = _hojaUsuarios();
  var tel = String(b.telefono || '').trim();
  var usuario = String(b.usuario || '').trim();
  var fila = [
    b.fecha || new Date().toISOString(),
    b.nombre || '', tel, b.email || '', b.direccion || '',
    b.barrio || '', b.referencia || '', b.evento || 'registro',
    b.carrito ? JSON.stringify(b.carrito) : '',
    b.deseos ? JSON.stringify(b.deseos) : '',
    b.foto || '',
    usuario,
    String(b.passHash || '')
  ];
  var datos = sh.getDataRange().getValues();
  for (var i = 1; i < datos.length; i++) {
    var matchU = usuario !== '' && _norm(datos[i][COL_USUARIO]) === _norm(usuario);
    var matchT = usuario === '' && tel !== '' && String(datos[i][2]).trim() === tel;
    if (matchU || matchT) {
      if (!b.foto) fila[10] = datos[i][10] || '';                 // preservar foto
      if (!b.passHash) fila[COL_PASSHASH] = datos[i][COL_PASSHASH] || '';  // preservar clave
      if (!usuario) fila[COL_USUARIO] = datos[i][COL_USUARIO] || '';
      sh.getRange(i + 1, 1, 1, fila.length).setValues([fila]);
      return _json({ ok: true, updated: true });
    }
  }
  // Registro nuevo: si el usuario ya existe, rechazar
  if (usuario !== '' && _buscarPorUsuario(sh, usuario) !== -1) {
    return _json({ ok: false, motivo: 'usuario_ocupado' });
  }
  sh.appendRow(fila);
  return _json({ ok: true, created: true });
}

// Pedidos: una fila por compra (historial)
function _guardarPedido(b) {
  var sh = _hoja('Pedidos', [
    'Fecha', 'Nombre', 'Telefono', 'Direccion', 'Barrio',
    'Productos', 'Total', 'Canal', 'Notas'
  ]);
  sh.appendRow([
    b.fecha || new Date().toISOString(),
    b.nombre || '', b.telefono || '', b.direccion || '', b.barrio || '',
    b.productos || b.detalle || '', b.total || '',
    b.canal || (String(b.notas || '').indexOf('MercadoPago') >= 0 ? 'mercadopago' : 'whatsapp'),
    b.notas || ''
  ]);
  return _json({ ok: true });
}

// GET: obtener estado (perfil + carrito + deseos) por telefono o email
//   .../exec?action=estado&telefono=3510000000
function doGet(e) {
  try {
    var p = e.parameter || {};
    if ((p.action || '') !== 'estado') {
      return _json({ ok: true, msg: 'K24 backend activo' });
    }
    var tel = String(p.telefono || '').trim();
    var email = String(p.email || '').trim().toLowerCase();
    var sh = _ss().getSheetByName('Usuarios');
    if (!sh) return _json({ ok: true, encontrado: false });
    var datos = sh.getDataRange().getValues();
    for (var i = 1; i < datos.length; i++) {
      var r = datos[i];
      var matchTel = tel && String(r[2]).trim() === tel;
      var matchMail = email && String(r[3]).trim().toLowerCase() === email;
      if (matchTel || matchMail) {
        return _json({
          ok: true, encontrado: true,
          perfil: {
            usuario: r[COL_USUARIO] || '',
            nombre: r[1], telefono: r[2], email: r[3],
            direccion: r[4], barrio: r[5], referencia: r[6],
            foto: r[10] || ''
          },
          carrito: _parse(r[8]),
          deseos: _parse(r[9])
        });
      }
    }
    return _json({ ok: true, encontrado: false });
  } catch (err) {
    return _json({ ok: false, error: String(err) });
  }
}

function _parse(s) {
  try { return s ? JSON.parse(s) : null; } catch (e) { return null; }
}
