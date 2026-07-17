// K24 — Google Apps Script (backend sobre Google Sheets)
// ⚠️ Este archivo ES el que está publicado. Preserva TODO lo existente
// (pedidos con numero correlativo, registro de usuarios, backups a Drive) y
// AGREGA el login con usuario/contrasena usando una hoja nueva "Cuentas".
//
// COMO ACTUALIZARLO:
//   1. Extensiones -> Apps Script -> pegá TODO este archivo (reemplazando).
//   2. Implementar -> Gestionar implementaciones -> editá la implementación
//      que usa la app (la que termina en ...HcoA3kBuK2rD7dWqdYZGw) -> Version:
//      "Nueva version" -> Implementar. Asi la URL /exec no cambia.

const SHEET_ID         = '1gvv0pL42qzu8L8gx2KlDvNkY87C6YCezyukGSAlq5fs';
const PEDIDOS_SHEET_ID = '1u7UOSYBziInDMKJfgL1VmeTipzTCRTQA60qfQ4YSO3A';
const BACKUP_FOLDER_ID = '1XsSdilbUH2V9FRSvXx7VtnMc1KqZmG3l';
const GITHUB_RAW_URL   = 'https://raw.githubusercontent.com/jorko45/kiosco-online/main/index.html';
const MAX_BACKUPS = 10;

// Hoja de cuentas para el login (usuario + contrasena). Se crea sola.
const CUENTAS_HEADERS = ['Fecha','Usuario','PassHash','Nombre','Telefono','Email','Direccion','Piso','Barrio','Referencia','Coords','Foto','Carrito','Deseos'];

function _jsonOut(o){
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
function _norm(s){ return String(s||'').trim().toLowerCase(); }
function _parse(s){ try{ return s ? JSON.parse(s) : null; }catch(e){ return null; } }

function _hojaCuentas(){
  // Planilla propia para las cuentas. Se crea sola la primera vez (queda en el
  // Drive de la cuenta como "K24 Cuentas") y su ID se guarda en las propiedades
  // del script, para no depender de IDs hardcodeados.
  var props = PropertiesService.getScriptProperties();
  var id = props.getProperty('CUENTAS_SHEET_ID');
  var ss = null;
  if (id) { try { ss = SpreadsheetApp.openById(id); } catch (e) { ss = null; } }
  if (!ss) {
    ss = SpreadsheetApp.create('K24 Cuentas');
    props.setProperty('CUENTAS_SHEET_ID', ss.getId());
  }
  var sh = ss.getSheetByName('Cuentas');
  if (!sh) {
    sh = ss.getSheets()[0];
    sh.setName('Cuentas');
  }
  if (sh.getLastRow() === 0) { sh.appendRow(CUENTAS_HEADERS); sh.setFrozenRows(1); }
  return sh;
}
function _filaPorUsuario(sh, usuario){
  var u=_norm(usuario); if(!u) return -1;
  var d=sh.getDataRange().getValues();
  for(var i=1;i<d.length;i++){ if(_norm(d[i][1])===u) return i+1; }
  return -1;
}
function _filaPorContacto(sh, tel, email){
  tel=String(tel||'').trim(); email=_norm(email);
  if(!tel && !email) return -1;
  var d=sh.getDataRange().getValues();
  for(var i=1;i<d.length;i++){
    if(tel && String(d[i][4]).trim()===tel) return i+1;
    if(email && _norm(d[i][5])===email) return i+1;
  }
  return -1;
}
function _cuentaObj(r){
  return {
    perfil:{ usuario:r[1], nombre:r[3], telefono:r[4], email:r[5], direccion:r[6], piso:r[7], barrio:r[8], referencia:r[9], foto:r[11]||'' },
    carrito:_parse(r[12]),
    deseos:_parse(r[13])
  };
}

// Alta/actualizacion de una cuenta. Preserva PassHash y Foto si no vienen.
function _guardarCuenta(data){
  var sh=_hojaCuentas();
  var usuario=String(data.usuario||'').trim();
  var fila=[
    new Date().toLocaleString('es-AR'),
    usuario, String(data.passHash||''),
    data.nombre||'', data.telefono||'', data.email||'', data.direccion||'',
    data.piso||'', data.barrio||'', data.referencia||'',
    data.coords ? (data.coords.lat+','+data.coords.lng) : '',
    data.foto||'',
    data.carrito ? JSON.stringify(data.carrito) : '',
    data.deseos ? JSON.stringify(data.deseos) : ''
  ];
  var f = usuario ? _filaPorUsuario(sh, usuario) : _filaPorContacto(sh, data.telefono, data.email);
  if(f!==-1){
    var actual=sh.getRange(f,1,1,CUENTAS_HEADERS.length).getValues()[0];
    if(!data.passHash) fila[2]=actual[2]||'';   // preservar clave
    if(!data.foto)     fila[11]=actual[11]||''; // preservar foto
    if(!usuario)       fila[1]=actual[1]||'';   // preservar usuario
    sh.getRange(f,1,1,fila.length).setValues([fila]);
    return _jsonOut({ok:true, updated:true});
  }
  if(usuario && _filaPorUsuario(sh,usuario)!==-1){
    return _jsonOut({ok:false, motivo:'usuario_ocupado'});
  }
  sh.appendRow(fila);
  return _jsonOut({ok:true, created:true});
}

function doPost(e) {
  try {
    var data = JSON.parse(e.postData.contents);

    // Guardar pedido en hoja Pedidos K24 (numero correlativo)
    if (data.action === 'guardar_pedido') {
      var sheet = SpreadsheetApp.openById(PEDIDOS_SHEET_ID).getActiveSheet();
      var numPedido = sheet.getLastRow();
      sheet.appendRow([
        new Date().toLocaleString('es-AR'),
        numPedido,
        'NUEVO',
        data.nombre || '',
        data.telefono || '',
        data.direccion || '',
        data.barrio || '',
        data.productos || '',
        data.total || '',
        'WhatsApp',
        data.notas || ''
      ]);
      return _jsonOut({ ok:true });
    }

    // Login: valida usuario + passHash contra la hoja Cuentas
    if (data.action === 'login') {
      var shl=_hojaCuentas();
      var fl=_filaPorUsuario(shl, data.usuario);
      if(fl===-1) return _jsonOut({ok:true, encontrado:false});
      var rl=shl.getRange(fl,1,1,CUENTAS_HEADERS.length).getValues()[0];
      var hash=String(rl[2]||'');
      if(!hash || hash!==String(data.passHash||'')) return _jsonOut({ok:true, encontrado:true, auth:false});
      var ol=_cuentaObj(rl); ol.ok=true; ol.encontrado=true; ol.auth=true;
      return _jsonOut(ol);
    }

    // Disponibilidad de nombre de usuario
    if (data.action === 'check_usuario') {
      var shc=_hojaCuentas();
      return _jsonOut({ok:true, disponible:_filaPorUsuario(shc, data.usuario)===-1});
    }

    // Registro / actualizacion de cuenta (login con usuario/contrasena)
    if (data.action === 'registrar') {
      return _guardarCuenta(data);
    }

    // ── Registro de usuario (accion por defecto — LOG historico, sin tocar) ──
    var sheet = SpreadsheetApp.openById(SHEET_ID).getActiveSheet();
    var coords = data.coords ? 'https://maps.google.com/?q=' + data.coords.lat + ',' + data.coords.lng : '';
    sheet.appendRow([new Date().toLocaleString('es-AR'), data.nombre||'', data.telefono||'', data.direccion||'', data.piso||'', data.barrio||'', data.referencia||'', coords]);
    // Si el cliente ya tiene login (manda usuario), mantenemos su cuenta al dia
    if (data.usuario) { _guardarCuenta(data); }
    return _jsonOut({ ok:true });

  } catch(err) {
    return _jsonOut({ ok:false, error:err.message });
  }
}

// GET: estado para sincronizar entre dispositivos (perfil + carrito + deseos)
//   .../exec?action=estado&telefono=3510000000   (o &email=...)
function doGet(e) {
  try {
    var p = (e && e.parameter) || {};
    if ((p.action||'') !== 'estado') {
      return _jsonOut({ ok:true, msg:'K24 backend activo' });
    }
    var sh=_hojaCuentas();
    var f=_filaPorContacto(sh, p.telefono, p.email);
    if(f===-1) return _jsonOut({ ok:true, encontrado:false });
    var r=sh.getRange(f,1,1,CUENTAS_HEADERS.length).getValues()[0];
    var o=_cuentaObj(r); o.ok=true; o.encontrado=true;
    return _jsonOut(o);
  } catch(err) {
    return _jsonOut({ ok:false, encontrado:false, error:err.message });
  }
}

function testBasic() {
  return 'OK: ' + new Date().toISOString();
}

function backupIndexHtml() {
  var response = UrlFetchApp.fetch(GITHUB_RAW_URL);
  var content = response.getContentText('UTF-8');

  var now = new Date();
  var timestamp = Utilities.formatDate(now, 'America/Argentina/Cordoba', 'yyyy-MM-dd_HH-mm');
  var filename = 'index_' + timestamp + '.html';

  var folder = DriveApp.getFolderById(BACKUP_FOLDER_ID);
  folder.createFile(filename, content, MimeType.HTML);

  // Borrar backups viejos si hay mas de MAX_BACKUPS
  var files = folder.getFilesByType(MimeType.HTML);
  var fileList = [];
  while (files.hasNext()) fileList.push(files.next());
  fileList.sort(function(a,b){ return a.getDateCreated() - b.getDateCreated(); });
  while (fileList.length > MAX_BACKUPS) {
    fileList.shift().setTrashed(true);
  }
  Logger.log('Backup OK: ' + filename);
}
