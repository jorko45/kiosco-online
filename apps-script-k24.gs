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

/**
 * Acciones que pueden romper la planilla y por lo tanto piden secreto.
 *
 * La URL de este script esta a la vista en el codigo de k24hs.com: tiene
 * que estarlo, porque el navegador del cliente la usa para guardar pedidos.
 * Eso significa que cualquiera que mire el fuente la tiene. Mientras las
 * acciones destructivas no pidieran nada, un POST de tres lineas vaciaba
 * la lista de precios entera.
 *
 * Las acciones del cliente (guardar_pedido, comercio, zona_pedida...) NO
 * llevan secreto: las manda el navegador y ahi no hay donde esconderlo.
 * Esas solo agregan filas, no borran nada.
 */
var ACCIONES_PROTEGIDAS = [
  'precios_reset', 'precios_append', 'precios_costos',
  'precios_activo', 'precios_pintar'
];

function _secretoOk(data) {
  var esperado = PropertiesService.getScriptProperties().getProperty('K24_SECRETO');
  // Sin secreto configurado no se bloquea nada: asi esto se puede publicar
  // sin romper el actualizador que ya esta corriendo. En cuanto cargues la
  // propiedad K24_SECRETO en Configuracion del proyecto, empieza a exigirlo.
  if (!esperado) return true;
  return String((data && data.secreto) || '') === esperado;
}

function doPost(e) {
  try {
    var data = JSON.parse(e.postData.contents);

    if (ACCIONES_PROTEGIDAS.indexOf(data.action) !== -1 && !_secretoOk(data)) {
      return _jsonOut({ ok:false, error:'Esta accion necesita el secreto del proyecto' });
    }

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

    // Actualizar SOLO la columna Costo desde las paginas de los proveedores.
    // Los margenes (col F) no se tocan: el Precio Sugerido se recalcula solo.
    // data.rows = [[id, costo], ...]
    if (data.action === 'precios_costos') {
      var shc = _hojaPrecios(), lrc = shc.getLastRow();
      if (lrc < 2) return _jsonOut({ ok:true, actualizados:0 });
      var idsc = shc.getRange(2,1,lrc-1,1).getValues(), posc = {};
      for (var ic=0; ic<idsc.length; ic++){ var kc = String(idsc[ic][0]||'').trim(); if (kc) posc[kc] = ic; }
      var costos = shc.getRange(2,5,lrc-1,1).getValues();
      var margenes = shc.getRange(2,6,lrc-1,1).getValues();   // col F (margen %)
      var mps      = shc.getRange(2,7,lrc-1,1).getValues();   // col G (MP %)
      var sugAct   = shc.getRange(2,8,lrc-1,1).getValues();   // col H (precio sugerido actual)
      // Freno de seguridad: no aplicamos un costo si el precio saltaria mas de este %
      var TOPE = (data.tope!==undefined) ? Number(data.tope) : 0.30;
      var rowsc = data.rows || [], nAct = 0, nSin = 0, nIgual = 0, nFrenados = 0, tocadas = {}, frenados = [];
      for (var jc=0; jc<rowsc.length; jc++){
        var idc = String(rowsc[jc][0]||'').trim(), cc = Number(rowsc[jc][1]) || 0;
        if (!(idc in posc) || cc <= 0) { nSin++; continue; }
        var fc = posc[idc];
        if (Number(costos[fc][0]) === cc) { nIgual++; continue; }
        // ¿cuanto cambiaria el precio de venta con este costo nuevo?
        var margen = Number(margenes[fc][0]) || 0, mp = Number(mps[fc][0]) || 0;
        var nuevoSug = Math.round(cc * (1 + margen/100) * (1 + mp/100) / 50) * 50;
        var viejoSug = Number(sugAct[fc][0]) || 0;
        if (TOPE > 0 && viejoSug > 0 && Math.abs(nuevoSug - viejoSug) / viejoSug > TOPE) {
          nFrenados++;
          if (frenados.length < 60) frenados.push({ id: idc, de: viejoSug, a: nuevoSug });
          continue;   // NO tocamos el costo: queda como estaba
        }
        costos[fc][0] = cc; tocadas[fc] = 1; nAct++;
      }
      if (nAct) {
        shc.getRange(2,5,lrc-1,1).setValues(costos);
        // Si a alguna fila le falta la formula del Precio Sugerido, se la reponemos.
        // (No pisamos las que tengan un valor puesto a mano.)
        var fH = shc.getRange(2,8,lrc-1,1).getFormulas(), vH = shc.getRange(2,8,lrc-1,1).getValues();
        Object.keys(tocadas).forEach(function(k){
          var i2 = Number(k);
          if (!fH[i2][0] && (vH[i2][0] === '' || vH[i2][0] == null)) {
            var rr = i2 + 2;
            shc.getRange(rr,8).setFormula('=IF(E'+rr+'>0,MROUND(E'+rr+'*(1+F'+rr+'/100)*(1+G'+rr+'/100),50),"")');
          }
        });
      }
      return _jsonOut({ ok:true, actualizados:nAct, sinCambio:nIgual, sinFila:nSin, frenados:nFrenados, detalleFrenados:frenados });
    }

    // Marcar filas como Activo SI / NO. data.ids = [...], data.activo = 'SI'|'NO'
    if (data.action === 'precios_activo') {
      var sha = _hojaPrecios(), lra = sha.getLastRow();
      if (lra < 2) return _jsonOut({ ok:true, marcados:0 });
      var idsa = sha.getRange(2,1,lra-1,1).getValues(), posa = {};
      for (var ia=0; ia<idsa.length; ia++){ var ka = String(idsa[ia][0]||'').trim(); if (ka) posa[ka] = ia; }
      var cola = sha.getRange(2,10,lra-1,1).getValues();
      var valor = (String(data.activo||'NO').toUpperCase() === 'SI') ? 'SI' : 'NO';
      var lista = data.ids || [], nM = 0;
      for (var ja=0; ja<lista.length; ja++){
        var ida = String(lista[ja]||'').trim();
        if (!(ida in posa)) continue;
        if (String(cola[posa[ida]][0]).toUpperCase() === valor) continue;
        cola[posa[ida]][0] = valor; nM++;
      }
      if (nM) sha.getRange(2,10,lra-1,1).setValues(cola);
      return _jsonOut({ ok:true, marcados:nM });
    }

    // Pinta la planilla segun lo que REALMENTE le pasa a cada fila cuando
    // corre el actualizador. Las listas las manda actualizar_precios.py:
    //   data.anclas       = congeladas a proposito (naranja)
    //   data.sinProveedor = nadie publica su precio (gris)
    //   el resto          = se actualiza sola (sin color)
    if (data.action === 'precios_pintar') {
      var shq = _hojaPrecios(), lrq = shq.getLastRow();
      if (lrq < 2) return _jsonOut({ ok:true, pintadas:0 });
      var idsq = shq.getRange(2,1,lrq-1,1).getValues();
      var esAncla = {}, esSinProv = {};
      (data.anclas || []).forEach(function(x){ esAncla[String(x).trim()] = 1; });
      (data.sinProveedor || []).forEach(function(x){ esSinProv[String(x).trim()] = 1; });
      var colores = [], nA = 0, nS = 0;
      for (var iq=0; iq<idsq.length; iq++){
        var idq = String(idsq[iq][0]||'').trim(), color = null;
        if (esAncla[idq])        { color = '#FFE0B2'; nA++; }   // naranja
        else if (esSinProv[idq]) { color = '#ECEFF1'; nS++; }   // gris
        var filaq = [];
        for (var cq=0; cq<PRECIOS_HEADERS.length; cq++) filaq.push(color);
        colores.push(filaq);
      }
      shq.getRange(2,1,lrq-1,PRECIOS_HEADERS.length).setBackgrounds(colores);
      try {
        shq.getRange(1, PRECIOS_HEADERS.length+2)
           .setValue('Naranja = ANCLA, congelada a proposito  ·  Gris = sin proveedor  ·  Sin color = se actualiza sola')
           .setFontWeight('bold');
      } catch(e2){}
      return _jsonOut({ ok:true, anclas:nA, sinProveedor:nS, automaticas: idsq.length - nA - nS });
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

    // Alta de comercio interesado en la red -> hoja "Comercios"
    if (data.action === 'comercio') {
      var ssx = _hojaCuentas().getParent();
      var shx = ssx.getSheetByName('Comercios');
      if (!shx) {
        shx = ssx.insertSheet('Comercios');
        shx.appendRow(['Fecha','Comercio','Rubro','Zona/Barrio','Telefono','Contacto','Mensaje','Estado']);
        shx.getRange(1,1,1,8).setFontWeight('bold').setBackground('#0a7d3c').setFontColor('#ffffff');
        shx.setFrozenRows(1);
        shx.setColumnWidth(2,200); shx.setColumnWidth(7,320);
      }
      shx.appendRow([
        new Date().toLocaleString('es-AR'),
        data.comercio || '', data.rubro || '', data.zona || '',
        data.telefono || '', data.contacto || '', data.mensaje || '', 'NUEVO'
      ]);
      return _jsonOut({ ok:true });
    }

    // Pedido de cobertura desde una zona a la que todavia no llegamos -> hoja "Zonas pedidas"
    if (data.action === 'zona_pedida') {
      var ssz = _hojaCuentas().getParent();
      var shz = ssz.getSheetByName('Zonas pedidas');
      if (!shz) {
        shz = ssz.insertSheet('Zonas pedidas');
        shz.appendRow(['Fecha','Localidad','Tipo','Nombre','Telefono','Mensaje','Estado']);
        shz.getRange(1,1,1,7).setFontWeight('bold').setBackground('#1a73e8').setFontColor('#ffffff');
        shz.setFrozenRows(1);
        shz.setColumnWidth(2,220); shz.setColumnWidth(6,320);
      }
      shz.appendRow([
        new Date().toLocaleString('es-AR'),
        data.localidad || '', data.tipo || '', data.nombre || '',
        data.telefono || '', data.mensaje || '', 'NUEVO'
      ]);
      return _jsonOut({ ok:true });
    }

    // Registro de búsquedas -> hoja "Busquedas" (ranking, suma veces)
    if (data.action === 'buscar_log') {
      var q = String(data.q || '').trim().toLowerCase();
      if (!q || q.length < 3) return _jsonOut({ ok:true });
      var ssb = _hojaCuentas().getParent();
      var shb = ssb.getSheetByName('Busquedas');
      if (!shb) {
        shb = ssb.insertSheet('Busquedas');
        shb.appendRow(['Busqueda','Veces','Resultados','Ultima vez']);
        shb.getRange(1,1,1,4).setFontWeight('bold').setBackground('#6a1b9a').setFontColor('#ffffff');
        shb.setFrozenRows(1); shb.setColumnWidth(1,240);
      }
      var lr = shb.getLastRow();
      var fila = 0;
      if (lr > 1) {
        var qs = shb.getRange(2,1,lr-1,1).getValues();
        for (var i=0;i<qs.length;i++){ if (String(qs[i][0]).toLowerCase() === q) { fila = i+2; break; } }
      }
      var hits = Number(data.hits) || 0;
      if (fila) {
        var veces = (Number(shb.getRange(fila,2).getValue()) || 0) + 1;
        shb.getRange(fila,2).setValue(veces);
        shb.getRange(fila,3).setValue(hits);
        shb.getRange(fila,4).setValue(new Date().toLocaleString('es-AR'));
      } else {
        shb.appendRow([q, 1, hits, new Date().toLocaleString('es-AR')]);
      }
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

    // Una accion que no existe NO puede terminar escribiendo en el log de
    // usuarios. Antes caia ahi de cabeza y devolvia "Illegal spreadsheet id",
    // que manda a buscar el problema a la planilla cuando en realidad lo que
    // pasa es que esta publicada una version vieja del script.
    if (data.action) {
      return _jsonOut({ ok:false, accionDesconocida:true,
        error:'Este Apps Script no conoce la accion "' + data.action + '". '
            + 'Suele significar que quedo publicada una version vieja: pega de nuevo '
            + 'apps-script-k24.gs y actualiza la implementacion existente.' });
    }

    // ── Registro de usuario (posteo sin accion — LOG historico) ──
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

    // OJO: 'pintar_manuales' quedo obsoleto y se saco a proposito.
    //
    // Pintaba de naranja toda fila con "__" en el id, dando por hecho que
    // esas eran las manuales. Era cierto mientras mapa_marcas.json estuvo
    // vacio. Al restaurarlo, 216 de esas filas pasaron a actualizarse solas
    // y el color siguio diciendo lo contrario: un cartel que miente es peor
    // que no tener cartel.
    //
    // Ahora pinta 'precios_pintar' (abajo, en doPost), que recibe la lista
    // desde actualizar_precios.py — el unico que sabe de verdad a quien toca.

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
