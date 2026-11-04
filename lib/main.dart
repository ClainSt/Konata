import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'core/catalog.dart';
import 'core/metadata.dart';
import 'core/sources.dart';
import 'ui/watch_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Catalog.instance.initialize();
  Metadata.token=(await const FlutterSecureStorage().read(key:'tmdb_token'))??'';
  runApp(const CCPlayer());
}
class CCPlayer extends StatelessWidget {
  const CCPlayer({super.key});
  @override Widget build(BuildContext context)=>MaterialApp(
    title:'CCPlayer',debugShowCheckedModeBanner:false,
    theme:ThemeData(useMaterial3:true,colorScheme:ColorScheme.fromSeed(
      seedColor:const Color(0xff669dd6),brightness:Brightness.dark),
      scaffoldBackgroundColor:const Color(0xff111722),
      cardTheme:const CardThemeData(color:Color(0xff1d293a),elevation:0)),
    home:const LibraryPage());
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override State<LibraryPage> createState()=>_LibraryPageState();
}
class _LibraryPageState extends State<LibraryPage>{
  bool showSources=false;
  String filter='';
  @override Widget build(BuildContext context)=>AnimatedBuilder(
    animation:Catalog.instance,builder:(ctx,_) {
    final cat=Catalog.instance;
    final matches=cat.works.where((w)=>w['title'].toString().toLowerCase().contains(filter.toLowerCase())).toList();
    return Scaffold(appBar:AppBar(title:const Text('CCPlayer'),
      actions:[IconButton(onPressed:_add,tooltip:'添加媒体源',icon:const Icon(Icons.add_to_photos_outlined)),
        IconButton(onPressed:_settings,tooltip:'元数据设置',icon:const Icon(Icons.settings_outlined))]),
      body:Column(children:[
        if(cat.scanning)const LinearProgressIndicator(),
        Padding(padding:const EdgeInsets.all(12),child:Row(children:[
          ChoiceChip(label:const Text('海报墙'),selected:!showSources,onSelected:(_)=>setState(()=>showSources=false)),
          const SizedBox(width:8),
          ChoiceChip(label:Text('媒体源 ('+cat.sources.length.toString()+')'),selected:showSources,onSelected:(_)=>setState(()=>showSources=true)),
          const Spacer(),Text(cat.works.length.toString()+' 部作品') ])),
        if(!showSources)Padding(padding:const EdgeInsets.symmetric(horizontal:14),child:TextField(
          decoration:const InputDecoration(prefixIcon:Icon(Icons.search),hintText:'搜索动画',border:OutlineInputBorder()),
          onChanged:(v)=>setState(()=>filter=v))),
        Expanded(child:showSources?_sources(cat):matches.isEmpty?Center(child:Text(cat.sources.isEmpty?'请先添加媒体源':'暂无匹配作品')):
          LayoutBuilder(builder:(ctx,bounds)=>GridView.builder(
            padding:const EdgeInsets.all(14),itemCount:matches.length,
            gridDelegate:SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:(bounds.maxWidth/185).floor().clamp(2,9),
              childAspectRatio:0.64,crossAxisSpacing:12,mainAxisSpacing:16),
            itemBuilder:(ctx,i)=>_poster(matches[i])))),
        Padding(padding:const EdgeInsets.all(6),child:Text(cat.status,maxLines:1,
          overflow:TextOverflow.ellipsis,style:Theme.of(context).textTheme.bodySmall))
      ]));
  });
  Widget _poster(Map<String,Object?> work)=>InkWell(
    onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>WorkPage(workId:work['id'].toString()))),
    child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Expanded(child:ClipRRect(borderRadius:BorderRadius.circular(12),child:
        work['poster']!=null?Image.network(work['poster'].toString(),fit:BoxFit.cover,
          errorBuilder:(_,__,___)=>_blankPoster()):_blankPoster())),
      const SizedBox(height:8),
      Text(work['title'].toString(),maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w600)),
      Text((work['year']?.toString()??'')+(work['manual_lock']==1?' · 已手动绑定':''),
        style:Theme.of(context).textTheme.labelSmall)]));
  Widget _blankPoster()=>const ColoredBox(color:Color(0xff26364c),child:Center(
    child:Icon(Icons.movie_outlined,color:Color(0xff819ab9),size:46)));

  Widget _sources(Catalog cat)=>ListView(children:[
    for(final source in cat.sources)Card(child:ListTile(
      leading:Icon(source['kind']=='local'?Icons.folder:Icons.cloud_outlined),
      title:Text(source['label'].toString()),subtitle:Text(source['location'].toString(),
        maxLines:2,overflow:TextOverflow.ellipsis),
      trailing:Wrap(children:[
        IconButton(tooltip:'扫描',onPressed:cat.scanning?null:()async{
          try{await Scanner.scan(source);}catch(e){_message(e.toString());}
        },icon:const Icon(Icons.sync)),
        IconButton(tooltip:'移除',onPressed:()async{
          final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
            title:const Text('移除媒体源？'),content:const Text('仅清除索引，不删除源文件。'),
            actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('取消')),
              FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('移除'))]));
          if(ok==true)await Catalog.instance.removeSource(source['id'].toString());
        },icon:const Icon(Icons.delete_outline))]))),
    Center(child:FilledButton.icon(onPressed:_add,icon:const Icon(Icons.add),label:const Text('添加媒体源')))
  ]);
  Future<void> _add() async {
    final name=TextEditingController(),location=TextEditingController(),username=TextEditingController(),password=TextEditingController();
    String kind='webdav';
    final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,update)=>AlertDialog(
      title:const Text('添加媒体源'),
      content:SizedBox(width:460,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        SegmentedButton<String>(segments:const [
          ButtonSegment(value:'webdav',label:Text('WebDAV')),ButtonSegment(value:'local',label:Text('本地'))
        ],selected:{kind},onSelectionChanged:(v)=>update(()=>kind=v.first)),
        TextField(controller:name,decoration:const InputDecoration(labelText:'显示名称')),
        TextField(controller:location,decoration:InputDecoration(labelText:kind=='local'?'目录绝对路径':'WebDAV 根目录 URL')),
        if(kind=='webdav')...[
          TextField(controller:username,decoration:const InputDecoration(labelText:'用户名')),
          TextField(controller:password,obscureText:true,decoration:const InputDecoration(labelText:'密码')),
          const Text('预览版仅支持 Basic 鉴权；建议使用 HTTPS 测试连接，不要使用真实云盘凭证。',style:TextStyle(color:Colors.orangeAccent,fontSize:12))
        ]
      ]))),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('取消')),
        FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('添加'))]
    )));
    if(confirmed==true&&location.text.trim().isNotEmpty){
      await Catalog.instance.addSource(kind,name.text.trim().isEmpty?location.text.trim():name.text.trim(),
        location.text.trim(),username:username.text.trim(),password:password.text);
    }
    name.dispose();location.dispose();username.dispose();password.dispose();
  }
  Future<void> _settings() async {
    final token=TextEditingController(text:Metadata.token);
    await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('TMDB / Bangumi 设置'),
      content:SizedBox(width:460,child:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:token,obscureText:true,decoration:const InputDecoration(labelText:'TMDB Read Access Token')),
        const SizedBox(height:8),
        const Text('TMDB 令牌保存在系统安全存储中。',style:TextStyle(fontSize:12))
      ])),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('取消')),
        FilledButton(onPressed:()async{
          Metadata.token=token.text.trim();
          await const FlutterSecureStorage().write(key:'tmdb_token',value:Metadata.token);
          if(ctx.mounted)Navigator.pop(ctx);
        },child:const Text('保存'))]
    ));
    token.dispose();
  }
  void _message(String message){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(message)));}
}

class WorkPage extends StatefulWidget{
  const WorkPage({super.key,required this.workId});
  final String workId;
  @override State<WorkPage> createState()=>_WorkPageState();
}
class _WorkPageState extends State<WorkPage>{
  @override Widget build(BuildContext context)=>AnimatedBuilder(animation:Catalog.instance,builder:(ctx,_){
    final cat=Catalog.instance;
    final found=cat.works.where((w)=>w['id']==widget.workId).toList();
    if(found.isEmpty)return const Scaffold(body:Center(child:Text('未找到作品')));
    final work=found.first;
    final assets=cat.forWork(widget.workId);
    return Scaffold(appBar:AppBar(title:Text(work['title'].toString()),actions:[
      IconButton(tooltip:'匹配元数据',onPressed:()=>_match(work),icon:const Icon(Icons.manage_search))
    ]),body:ListView(padding:const EdgeInsets.all(18),children:[
      Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
        SizedBox(width:120,height:176,child:ClipRRect(borderRadius:BorderRadius.circular(10),
          child:work['poster']!=null?Image.network(work['poster'].toString(),fit:BoxFit.cover,
            errorBuilder:(_,__,___)=>const Icon(Icons.movie)):const ColoredBox(
              color:Color(0xff293c55),child:Icon(Icons.movie,size:52)))),
        const SizedBox(width:16),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(work['title'].toString(),style:Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height:8),
          Text([if(work['year']!=null)work['year'].toString(),
            if(work['tmdb_id']!=null)'TMDB '+work['tmdb_id'].toString(),
            if(work['bangumi_id']!=null)'Bangumi '+work['bangumi_id'].toString()].join(' · ')),
          const SizedBox(height:8),
          Text(work['overview']?.toString()??'暂无简介',maxLines:7,overflow:TextOverflow.ellipsis),
          OutlinedButton.icon(onPressed:()=>_match(work),icon:const Icon(Icons.search),label:const Text('搜索并绑定元数据'))
        ]))
      ]),
      const SizedBox(height:20),
      Text('正片',style:Theme.of(context).textTheme.titleLarge),
      for(final asset in assets.where((a)=>a['category']=='main'))_asset(asset),
      if(assets.any((a)=>a['category']=='extra'))...[
        const SizedBox(height:18),Text('特典',style:Theme.of(context).textTheme.titleLarge),
        for(final asset in assets.where((a)=>a['category']=='extra'))_asset(asset)
      ]
    ]));
  });
  Widget _asset(Map<String,Object?> asset)=>Card(child:ListTile(
    leading:const Icon(Icons.play_circle_outline),
    title:Text(asset['episode']==null?asset['name'].toString():'第 '+asset['episode'].toString()+' 集'),
    subtitle:Text(asset['name'].toString(),maxLines:1,overflow:TextOverflow.ellipsis),
    onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>WatchPage(asset:asset)))));
  Future<void> _match(Map<String,Object?> work) async {
    final query=TextEditingController(text:Catalog.cleanTitle(work['title'].toString()));
    String provider='tmdb';bool loading=false;String? failure;
    List<Candidate> results=[];
    await showDialog<void>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,update)=>AlertDialog(
      title:const Text('手动搜索并绑定'),
      content:SizedBox(width:540,height:490,child:Column(children:[
        SegmentedButton<String>(segments:const [
          ButtonSegment(value:'tmdb',label:Text('TMDB')),
          ButtonSegment(value:'bangumi',label:Text('Bangumi'))],
          selected:{provider},onSelectionChanged:(v)=>update((){provider=v.first;results=[];})),
        const SizedBox(height:10),
        Row(children:[Expanded(child:TextField(controller:query,decoration:const InputDecoration(labelText:'名称或 TMDB ID'))),
          IconButton.filled(icon:const Icon(Icons.search),onPressed:loading?null:()async{
            update((){loading=true;failure=null;});
            try{final items=await Metadata.search(query.text,provider);
              update((){results=items;loading=false;});}
            catch(e){update((){loading=false;failure=e.toString();});}
          })]),
        if(loading)const LinearProgressIndicator(),
        if(failure!=null)Text(failure!,style:const TextStyle(color:Colors.orangeAccent)),
        Expanded(child:ListView(children:[
          for(final result in results)ListTile(
            leading:result.poster==null?const Icon(Icons.movie):
              Image.network(result.poster!,width:45,height:65,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.movie)),
            title:Text(result.title),
            subtitle:Text((result.year?.toString()??'?')+' · '+result.provider+' #'+result.id.toString()),
            trailing:const Icon(Icons.link),
            onTap:()async{
              await Catalog.instance.bind(widget.workId,provider:result.provider,
                providerId:result.id,title:result.title,year:result.year,
                poster:result.poster,overview:result.overview,type:result.mediaType);
              if(ctx.mounted)Navigator.pop(ctx);
            })
        ]))
      ])),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('关闭'))]
    )));
    query.dispose();
  }
}
