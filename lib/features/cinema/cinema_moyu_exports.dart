import 'dart:convert';
import 'dart:typed_data';

const cinemaMoyuExportLimit = 64 * 1024 * 1024;

bool cinemaIsMoyuUrl(String? value) {
  final uri = Uri.tryParse(value ?? '');
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host == '1in8b.life' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;
}

class CinemaMoyuExport {
  const CinemaMoyuExport(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
  factory CinemaMoyuExport.decode(List<dynamic> args) {
    if (args.length != 2 || args[0] is! String || args[1] is! String) {
      throw const FormatException('无法读取网页导出文件');
    }
    final data = args[1] as String;
    if (data.length > ((cinemaMoyuExportLimit + 2) ~/ 3) * 4 + 300) {
      throw const FormatException('导出文件超过64MB，请使用浏览器保存');
    }
    final match = RegExp(
      r'^data:(image/png|image/jpeg|image/webp|image/gif|video/mp4|video/webm|application/json|text/plain)(?:;[^\r\n]{0,256})?;base64,',
    ).firstMatch(data);
    if (match == null) throw const FormatException('暂不支持这种导出文件');
    final bytes = base64Decode(data.substring(match.end));
    if (bytes.isEmpty || bytes.length > cinemaMoyuExportLimit) {
      throw const FormatException('导出文件为空或超过64MB');
    }
    final extension = switch (match[1]) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      'video/mp4' => 'mp4',
      'video/webm' => 'webm',
      'application/json' => 'json',
      _ => 'txt',
    };
    var stem = (args[0] as String)
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[\x00-\x1f\x7f:]'), '')
        .trim();
    if (stem.contains('.')) stem = stem.substring(0, stem.lastIndexOf('.'));
    stem = stem.replaceAll(RegExp(r'^\.+'), '').trim();
    if (stem.isEmpty) stem = '1in8b';
    if (stem.length > 100) stem = stem.substring(0, 100);
    return CinemaMoyuExport('$stem.$extension', bytes);
  }
}

// Only exports a clicked download from this public site's own main document.
// No website data leaves the device; the user chooses the output file.
const cinemaMoyuExportBridge = r'''
(() => {
 if(location.origin !== 'https://1in8b.life') return;
 let busy=false;
 document.addEventListener('click',async event=>{
  const link=event.target && event.target.closest && event.target.closest('a[download]');
  if(!link || busy) return;
  const href=link.href || '';
  if(!href.startsWith('blob:https://1in8b.life/') && !href.startsWith('data:')) return;
  event.preventDefault();
  if(navigator.userActivation && !navigator.userActivation.isActive) return;
  busy=true;
  try {
   const response=await fetch(href);
   const blob=await response.blob();
   if(blob.size>64*1024*1024) throw new Error('导出文件超过64MB，请使用浏览器保存');
   const data=await new Promise((resolve,reject)=>{
    const reader=new FileReader(); reader.onload=()=>resolve(reader.result);
    reader.onerror=()=>reject(new Error('无法读取导出文件')); reader.readAsDataURL(blob);
   });
   if(!window.flutter_inappwebview) throw new Error('保存功能尚未准备好，请重试');
   await window.flutter_inappwebview.callHandler('nakuMoyuExport',link.download||'1in8b',data);
  } catch(error) { window.alert(error.message || '保存失败，请重试'); }
  finally {busy=false;}
 },true);
})();
''';
