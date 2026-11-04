import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import 'catalog.dart';

class DavEntry {
  DavEntry(this.uri,this.name,this.isDirectory,this.size);
  final Uri uri;final String name;final bool isDirectory;final int? size;
}
class WebDav {
  WebDav(Map<String,Object?> source) :
    root=Uri.parse(source['location'].toString().endsWith('/')?source['location'].toString():'${source['location']}/'),
    username=source['username']?.toString()??'',password=source['password']?.toString()??'';
  final Uri root;
  final String username,password;
  String get auth=>'Basic ${base64Encode(utf8.encode('$username:$password'))}';
  Uri fileUri(String relative)=>root.resolve(relative.split('/').map(Uri.encodeComponent).join('/'));
  Future<List<DavEntry>> list(Uri uri) async {
    final client=HttpClient()..connectionTimeout=const Duration(seconds:15);
    try{
      final request=await client.openUrl('PROPFIND',uri);
      request.headers.set('Depth','1');
      request.headers.contentType=ContentType('application','xml',charset:'utf-8');
      if(username.isNotEmpty)request.headers.set('Authorization',auth);
      request.write('<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:allprop/></d:propfind>');
      final response=await request.close();
      final body=await utf8.decodeStream(response);
      if(response.statusCode!=207)throw HttpException('PROPFIND HTTP ${response.statusCode}',uri:uri);
      final doc=XmlDocument.parse(body);
      final entries=<DavEntry>[];
      for(final item in doc.descendants.whereType<XmlElement>().where((e)=>e.name.local=='response')){
        final href=item.descendants.whereType<XmlElement>().where((e)=>e.name.local=='href').firstOrNull?.innerText;
        if(href==null)continue;
        final target=uri.resolve(href);
        if(target.path.replaceAll(RegExp(r'/$'),'')==uri.path.replaceAll(RegExp(r'/$'),''))continue;
        final segments=target.pathSegments.where((x)=>x.isNotEmpty).toList();
        if(segments.isEmpty)continue;
        final dir=item.descendants.whereType<XmlElement>().any((e)=>e.name.local=='collection');
        final length=item.descendants.whereType<XmlElement>().where((e)=>e.name.local=='getcontentlength').firstOrNull?.innerText;
        entries.add(DavEntry(target,segments.last,dir,int.tryParse(length??'')));
      }
      return entries;
    }finally{client.close(force:true);}
  }
}

class Scanner {
  static Future<int> scan(Map<String,Object?> source) async {
    final cat=Catalog.instance;
    final id=source['id'].toString();
    var count=0;
    cat.updateStatus('扫描中：${source['label']}',true);
    try{
      if(source['kind']=='local'){
        final folder=Directory(source['location'].toString());
        if(!await folder.exists())throw StateError('目录不存在');
        await for(final entity in folder.list(recursive:true,followLinks:false)){
          if(entity is! File || !Catalog.isVideo(entity.path))continue;
          final relative=p.relative(entity.path,from:folder.path).replaceAll('\\','/');
          if(!relative.contains('/'))continue;
          await cat.indexVideo(id,relative,(await entity.stat()).size);
          count++;
          if(count%100==0)cat.updateStatus('扫描到 $count 个视频',true);
        }
      } else {
        final dav=WebDav(source);
        final pending=<({Uri uri,String relative})>[(uri:dav.root,relative:'')];
        final visited=<String>{};
        while(pending.isNotEmpty){
          final directory=pending.removeLast();
          if(!visited.add(directory.uri.toString()))continue;
          final children=await dav.list(directory.uri);
          for(final entry in children){
            final relative=directory.relative.isEmpty?entry.name:'${directory.relative}/${entry.name}';
            if(entry.isDirectory){
              if(RegExp(r'^(CDs?|Scans?)$',caseSensitive:false).hasMatch(entry.name))continue;
              pending.add((uri:entry.uri,relative:relative));
            }else if(Catalog.isVideo(entry.name)&&relative.contains('/')){
              await cat.indexVideo(id,relative,entry.size);
              count++;
            }
          }
          if(visited.length%10==0)cat.updateStatus('已扫描 ${visited.length} 个目录、$count 个视频',true);
        }
      }
      await cat.reload();
      cat.updateStatus('扫描完成：$count 个视频');
      return count;
    }catch(e){cat.updateStatus('扫描失败：$e');rethrow;}
  }
}

/// Local loopback file broker for media and subtitle resources.
class StreamBroker {
  StreamBroker._();
  static final instance=StreamBroker._();
  HttpServer? _server;
  bool _listening=false;
  final Map<String,({Map<String,Object?> source,String path})> _tickets={};
  Future<Uri> issue(Map<String,Object?> source,String path) async {
    _server??=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
    if(!_listening){_listening=true;_server!.listen(_handle);}
    final ticket='${DateTime.now().microsecondsSinceEpoch}-${_tickets.length}';
    _tickets[ticket]=(source:source,path:path);
    return Uri.parse('http://127.0.0.1:${_server!.port}/file/$ticket');
  }
  Future<void> _handle(HttpRequest req) async {
    final ticket=req.uri.pathSegments.isEmpty?'':req.uri.pathSegments.last;
    final info=_tickets[ticket];
    if(info==null){req.response.statusCode=404;await req.response.close();return;}
    final client=HttpClient()..autoUncompress=false;
    try{
      final dav=WebDav(info.source);
      final upstream=await client.openUrl(req.method,dav.fileUri(info.path));
      if(dav.username.isNotEmpty)upstream.headers.set('Authorization',dav.auth);
      final range=req.headers.value(HttpHeaders.rangeHeader);
      if(range!=null)upstream.headers.set(HttpHeaders.rangeHeader,range);
      final response=await upstream.close();
      req.response.statusCode=response.statusCode;
      for(final header in ['content-length','content-range','accept-ranges','content-type','etag','last-modified']){
        final value=response.headers.value(header);
        if(value!=null)req.response.headers.set(header,value);
      }
      if(req.method!='HEAD')await req.response.addStream(response);
    }catch(e){req.response.statusCode=502;}
    finally{await req.response.close();client.close(force:true);}
  }
  Future<List<String>> subtitles(Map<String,Object?> source,String relative) async {
    if(source['kind']=='local'){
      final file=File(p.join(source['location'].toString(),relative.replaceAll('/',Platform.pathSeparator)));
      final folder=file.parent;
      if(!await folder.exists())return [];
      final stem=p.basenameWithoutExtension(file.path).toLowerCase();
      final entries=await folder.list().where((f)=>f is File).cast<File>().toList();
      return entries.where((f)=>Catalog.isSubtitle(f.path)&&p.basenameWithoutExtension(f.path).toLowerCase().startsWith(stem))
        .map((f)=>p.relative(f.path,from:source['location'].toString()).replaceAll('\\','/')).toList();
    }
    final dav=WebDav(source);
    final idx=relative.lastIndexOf('/');
    final dirname=idx<0?'':relative.substring(0,idx);
    final stem=p.posix.basenameWithoutExtension(relative).toLowerCase();
    final url=dirname.isEmpty?dav.root:dav.root.resolve('${dirname.split('/').map(Uri.encodeComponent).join('/')}/');
    final entries=await dav.list(url);
    return entries.where((e)=>!e.isDirectory&&Catalog.isSubtitle(e.name)&&p.posix.basenameWithoutExtension(e.name).toLowerCase().startsWith(stem))
      .map((e)=>dirname.isEmpty?e.name:'$dirname/${e.name}').toList();
  }
}
