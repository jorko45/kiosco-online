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
const CUENTAS_HEADERS = ['Fecha','Usuario','PassHash','Nombre','Telefono','Email','Direccion','Piso','Barrio','Referencia','Coords','Foto','Carrito','Deseos','Mayor18'];

// Hoja donde quedan registradas las solicitudes de arrepentimiento (Res. 424/2020)
const ARREP_HEADERS = ['Fecha','Nombre','Telefono','Email','Pedido','Motivo','Estado'];
function _hojaArrepentimientos(){
  var ss = _hojaCuentas().getParent();           // misma planilla que Cuentas
  var sh = ss.getSheetByName('Arrepentimientos');
  if (!sh) {
    sh = ss.insertSheet('Arrepentimientos');
    sh.appendRow(ARREP_HEADERS);
    sh.getRange(1,1,1,ARREP_HEADERS.length).setFontWeight('bold').setBackground('#cc0000').setFontColor('#ffffff');
    sh.setFrozenRows(1);
  }
  return sh;
}

// ===== BUZON DEL CLIENTE ==================================================
// Hoja "Buzon": mensajes que le quedan guardados a cada cliente.
// Destinatario = usuario o telefono del cliente, o "*" para todos.
// Para mandarle un mensaje a alguien, escribi una fila a mano en la planilla
// (Fecha, Destinatario, Tipo, Titulo, Texto) — el Id se genera solo.
const BUZON_HEADERS = ['Fecha','Destinatario','Tipo','Titulo','Texto','Id','LeidoPor'];
function _hojaBuzon(){
  var ss = _hojaCuentas().getParent();
  var sh = ss.getSheetByName('Buzon');
  if (!sh) {
    sh = ss.insertSheet('Buzon');
    sh.appendRow(BUZON_HEADERS);
    sh.getRange(1,1,1,BUZON_HEADERS.length).setFontWeight('bold').setBackground('#1a73e8').setFontColor('#ffffff');
    sh.setFrozenRows(1);
    sh.setColumnWidth(4, 260); sh.setColumnWidth(5, 420);
  }
  return sh;
}
function _buzonAgregar(destinatario, tipo, titulo, texto){
  try {
    var id = 'm' + new Date().getTime() + Math.floor(Math.random()*1000);
    _hojaBuzon().appendRow([
      new Date().toLocaleString('es-AR'),
      String(destinatario || '*'), tipo || 'aviso',
      titulo || '', texto || '', id, ''
    ]);
    return id;
  } catch(e){ return ''; }
}
// Devuelve los mensajes de un cliente (los suyos + los generales), mas nuevos primero.
function _buzonLeer(usuario, telefono){
  var sh = _hojaBuzon();
  var n = sh.getLastRow();
  if (n < 2) return [];
  var vals = sh.getRange(2,1,n-1,BUZON_HEADERS.length).getValues();
  var yo = [String(usuario||'').trim().toLowerCase(), String(telefono||'').trim().toLowerCase()]
             .filter(function(x){ return x; });
  var out = [];
  for (var i=0;i<vals.length;i++){
    var v = vals[i];
    var dest = String(v[1]||'*').trim().toLowerCase();
    var mio = (dest === '*' || dest === '' || yo.indexOf(dest) !== -1);
    if (!mio) continue;
    var id = String(v[5]||'') || ('r' + (i+2));
    var leidoPor = String(v[6]||'').toLowerCase();
    var leido = false;
    for (var j=0;j<yo.length;j++){ if (leidoPor.indexOf(yo[j]) !== -1) leido = true; }
    out.push({ id:id, fecha:String(v[0]||''), tipo:String(v[2]||'aviso'),
               titulo:String(v[3]||''), texto:String(v[4]||''), leido:leido });
  }
  return out.reverse().slice(0, 120);
}

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
  // Si se agregaron columnas nuevas (ej: Mayor18), completar el encabezado
  try { if (sh.getLastColumn() < CUENTAS_HEADERS.length) {
    sh.getRange(1,1,1,CUENTAS_HEADERS.length).setValues([CUENTAS_HEADERS]);
  } } catch(e) {}
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
    perfil:{ usuario:r[1], nombre:r[3], telefono:r[4], email:r[5], direccion:r[6], piso:r[7], barrio:r[8], referencia:r[9], foto:r[11]||'',
             mayor18: (r[14]===true || String(r[14]||'').toUpperCase()==='SI') },
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
    data.deseos ? JSON.stringify(data.deseos) : '',
    data.mayor18 ? 'SI' : 'NO'
  ];
  var f = usuario ? _filaPorUsuario(sh, usuario) : _filaPorContacto(sh, data.telefono, data.email);
  if(f!==-1){
    var actual=sh.getRange(f,1,1,CUENTAS_HEADERS.length).getValues()[0];
    if(!data.passHash) fila[2]=actual[2]||'';   // preservar clave
    if(!data.foto)     fila[11]=actual[11]||''; // preservar foto
    if(data.mayor18===undefined || data.mayor18===null) fila[14]=actual[14]||''; // preservar +18
    if(!usuario)       fila[1]=actual[1]||'';   // preservar usuario
    sh.getRange(f,1,1,fila.length).setValues([fila]);
    return _jsonOut({ok:true, updated:true});
  }
  if(usuario && _filaPorUsuario(sh,usuario)!==-1){
    return _jsonOut({ok:false, motivo:'usuario_ocupado'});
  }
  sh.appendRow(fila);
  _buzonAgregar(usuario || data.telefono, 'cuenta',
    '🎉 ¡Bienvenido a k24hs, ' + (data.nombre || '') + '!',
    'Tu cuenta quedó creada. Acá te van a quedar guardados tus pedidos, promos y novedades. Guardá tus productos favoritos con el ❤️ y pedí las 24hs.');
  return _jsonOut({ok:true, created:true});
}

// ── PLANILLA DE PRECIOS (costo / margen / MP / precio venta) ──
var PRECIOS_HEADERS = ['ID','Sección','Categoría','Producto','Costo','Margen %','MP %','Precio Sugerido','Precio Venta','Activo'];
function _hojaPrecios(){
  var props = PropertiesService.getScriptProperties();
  var id = props.getProperty('PRECIOS_SHEET_ID');
  var ss = null;
  if (id) { try { ss = SpreadsheetApp.openById(id); } catch(e) { ss = null; } }
  if (!ss) { ss = SpreadsheetApp.create('precios editable google'); props.setProperty('PRECIOS_SHEET_ID', ss.getId()); }
  try{ if(ss.getName()!=='precios editable google') ss.rename('precios editable google'); }catch(e){} // renombrar planilla precios
  var sh = ss.getSheets()[0];
  if (sh.getLastRow() === 0) {
    sh.appendRow(PRECIOS_HEADERS);
    sh.getRange(1,1,1,PRECIOS_HEADERS.length).setFontWeight('bold').setBackground('#cc0000').setFontColor('#ffffff');
    sh.setFrozenRows(1);
    sh.setColumnWidth(1,110); sh.setColumnWidth(4,320);
  }
  return sh;
}

function doPost(e) {
  try {
    var data = JSON.parse(e.postData.contents);

    // Vaciar la planilla de precios (deja el encabezado)
    if (data.action === 'precios_reset') {
      var spr = _hojaPrecios();
      var lr0 = spr.getLastRow();
      if (lr0 > 1) spr.getRange(2,1,lr0-1,PRECIOS_HEADERS.length).clearContent();
      return _jsonOut({ ok:true, cleared:true });
    }

    // Cargar un lote de productos a la planilla de precios
    // data.rows = [[id,seccion,categoria,producto,costo,margen,mp,precioVenta], ...]
    if (data.action === 'precios_append') {
      var spa = _hojaPrecios();
      var rows = data.rows || [];
      if (rows.length) {
        var start = spa.getLastRow() + 1;
        var vals = rows.map(function(r){
          return [ r[0], r[1], r[2], r[3],
            (r[4]===''||r[4]==null)?'':Number(r[4]),
            (r[5]===''||r[5]==null)?'':Number(r[5]),
            (r[6]===''||r[6]==null)?'':Number(r[6]),
            '', Number(r[7])||0, 'SI' ];
        });
        spa.getRange(start,1,vals.length,PRECIOS_HEADERS.length).setValues(vals);
        var fs = [];
        for (var i=0;i<vals.length;i++){ var rr=start+i; fs.push(['=IF(E'+rr+'>0,MROUND(E'+rr+'*(1+F'+rr+'/100)*(1+G'+rr+'/100),50),"")']); }
        spa.getRange(start,8,fs.length,1).setFormulas(fs);
      }
      return _jsonOut({ ok:true, total: spa.getLastRow()-1 });
    }

    // Solicitud de arrepentimiento (Res. 424/2020) -> hoja "Arrepentimientos"
    if (data.action === 'arrepentimiento') {
      _hojaArrepentimientos().appendRow([
        new Date().toLocaleString('es-AR'),
        data.nombre || '', data.telefono || '', data.email || '',
        data.pedido || '', data.motivo || '', 'PENDIENTE'
      ]);
      _buzonAgregar(data.usuario || data.telefono, 'cuenta',
        '↩️ Recibimos tu solicitud de arrepentimiento',
        'Pedido: ' + (data.pedido || '-') + '. Te contactamos para resolverlo. Tenés 10 días corridos desde que recibiste la compra (Res. 424/2020).');
      return _jsonOut({ ok:true });
    }

    // ===== BUZON =====
    // Leer los mensajes guardados de un cliente
    if (data.action === 'buzon') {
      return _jsonOut({ ok:true, items: _buzonLeer(data.usuario, data.telefono) });
    }
    // Mandar un mensaje (a un cliente o a todos con destinatario "*")
    if (data.action === 'buzon_enviar') {
      var _mid = _buzonAgregar(data.destinatario, data.tipo || 'aviso', data.titulo, data.texto);
      return _jsonOut({ ok:true, id:_mid });
    }
    // Marcar como leidos
    if (data.action === 'buzon_leido') {
      var quien = String(data.usuario || data.telefono || '').trim().toLowerCase();
      var ids = data.ids || [];
      if (quien && ids.length) {
        var shb = _hojaBuzon(), nb = shb.getLastRow();
        if (nb > 1) {
          var rng = shb.getRange(2,1,nb-1,BUZON_HEADERS.length), vv = rng.getValues(), cambio = false;
          for (var bi=0; bi<vv.length; bi++){
            var bid = String(vv[bi][5]||'') || ('r' + (bi+2));
            if (ids.indexOf(bid) === -1) continue;
            var lp = String(vv[bi][6]||'');
            if (lp.toLowerCase().indexOf(quien) === -1){
              vv[bi][6] = lp ? (lp + ',' + quien) : quien;
              if (!vv[bi][5]) vv[bi][5] = bid;
              cambio = true;
            }
          }
          if (cambio) rng.setValues(vv);
        }
      }
      return _jsonOut({ ok:true });
    }

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
      _buzonAgregar(data.usuario || data.telefono, 'pedido',
        '🛒 Pedido #' + numPedido + ' recibido',
        'Total: $' + (data.total || '-') + '. ' + (data.productos || '') +
        '\nTe avisamos cuando salga el reparto. Envíos de 8 a 21hs.');
      return _jsonOut({ ok:true, pedido: numPedido });
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

    // Catálogo de precios para la web: [id, precioVenta, precioSugerido, activo]
    if ((p.action||'') === 'precios') {
      var spg = _hojaPrecios();
      var lrg = spg.getLastRow();
      if (lrg < 2) return _jsonOut({ ok:true, items:[] });
      var vg = spg.getRange(2,1,lrg-1,PRECIOS_HEADERS.length).getValues();
      var items = [];
      for (var i=0;i<vg.length;i++){
        var r = vg[i]; var id = r[0]; if (id==='' || id==null) continue;
        var act = String(r[9]||'').toUpperCase().trim();
        var activo = (act===''||act==='SI'||act==='TRUE'||act==='1'||act==='VERDADERO') ? 1 : 0;
        items.push([ String(id), Number(r[8])||0, Number(r[7])||0, activo ]);
      }
      return _jsonOut({ ok:true, items:items });
    }

    // Rellenar Costo/Margen/MP a partir del Precio Venta actual (costo hacia atrás:
    // costo = precio / (1+margen)/(1+MP) con margen 25% y MP 6.6%). Solo se corre 1 vez.
    if ((p.action||'') === 'rellenar_costos') {
      var spc = _hojaPrecios();
      var lrc = spc.getLastRow();
      if (lrc < 2) return _jsonOut({ ok:true, filled:0 });
      var ventas = spc.getRange(2,9,lrc-1,1).getValues(); // col I (Precio Venta)
      var egm = [];
      for (var i=0;i<ventas.length;i++){
        var v = Number(ventas[i][0])||0;
        egm.push([ v>0?Math.round(v/1.3325):'', v>0?25:'', v>0?6.6:'' ]);
      }
      spc.getRange(2,5,egm.length,3).setValues(egm); // cols E(Costo) F(Margen) G(MP)
      return _jsonOut({ ok:true, filled: egm.length });
    }

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
