import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:media_kit/media_kit.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'core/catalog.dart';
import 'core/metadata.dart';
import 'core/selected_scan_workflow.dart';
import 'core/personal_scrape_coordinator.dart';
import 'ui/source_browser_page.dart';
import 'ui/adaptive_poster_title.dart';
import 'ui/source_editor.dart';
import 'ui/tmdb_settings_dialog.dart';
import 'ui/nipaplay_detail_page.dart';
import 'ui/nipaplay_style.dart';
import 'ui/work_edit_dialogs.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Catalog.instance.initialize();
  const secure = FlutterSecureStorage();
  Metadata.token = (await secure.read(key: 'tmdb_token')) ?? '';
  Metadata.apiKey = (await secure.read(key: 'tmdb_api_key')) ?? '';
  Metadata.authMode = (await secure.read(key: 'tmdb_auth_mode')) == 'apiKey'
      ? 'apiKey'
      : 'token';
  runApp(const CCPlayer());
}

class CCPlayer extends StatelessWidget {
  const CCPlayer({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CCPlayer',
    debugShowCheckedModeBanner: false,
    theme: NipaPlayStyle.theme(Brightness.light),
    darkTheme: NipaPlayStyle.theme(Brightness.dark),
    themeMode: ThemeMode.light,
    home: const LibraryPage(),
  );
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  bool showSources = false;
  String filter = '';
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Catalog.instance,
    builder: (ctx, _) {
      final cat = Catalog.instance;
      final matches = cat.works
          .where(
            (w) => w['title'].toString().toLowerCase().contains(
              filter.toLowerCase(),
            ),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: const Text('CCPlayer'),
          actions: [
            IconButton(
              onPressed: _add,
              tooltip: '添加媒体源',
              icon: const Icon(Icons.add_to_photos_outlined),
            ),
            IconButton(
              onPressed: _settings,
              tooltip: '元数据设置',
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        body: Column(
          children: [
            if (cat.scanning) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('海报墙'),
                    selected: !showSources,
                    onSelected: (_) => setState(() => showSources = false),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text('媒体源 (${cat.sources.length})'),
                    selected: showSources,
                    onSelected: (_) => setState(() => showSources = true),
                  ),
                  const Spacer(),
                  Text('${cat.works.length} 部作品'),
                ],
              ),
            ),
            if (!showSources)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索动画',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => filter = v),
                ),
              ),
            Expanded(
              child: showSources
                  ? _sources(cat)
                  : matches.isEmpty
                  ? Center(
                      child: Text(cat.sources.isEmpty ? '请先添加媒体源' : '暂无匹配作品'),
                    )
                  : LayoutBuilder(
                      builder: (ctx, bounds) {
                        // A fixed 2:3 cover and a two-line title slot keep all
                        // poster tiles aligned regardless of title length.
                        const horizontalPadding = 14.0;
                        const crossSpacing = 12.0;
                        final columns = (bounds.maxWidth / 185).floor().clamp(
                          2,
                          9,
                        );
                        final cardWidth =
                            (bounds.maxWidth -
                                2 * horizontalPadding -
                                (columns - 1) * crossSpacing) /
                            columns;
                        final cardHeight = cardWidth * 1.5 + 8 + 48 + 4 + 20;
                        return GridView.builder(
                          padding: const EdgeInsets.all(horizontalPadding),
                          itemCount: matches.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisExtent: cardHeight,
                                crossAxisSpacing: crossSpacing,
                                mainAxisSpacing: 16,
                              ),
                          itemBuilder: (ctx, i) => _poster(matches[i]),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                cat.status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    },
  );
  Widget _poster(Map<String, Object?> work) => InkWell(
    onTap: () => Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WorkPage(workId: work['id'].toString()),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          key: ValueKey('library-poster-${work['id']}'),
          aspectRatio: 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Catalog.preferredPoster(work) != null
                ? Image.network(
                    Catalog.preferredPoster(work)!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) {
                      final fallback = work['poster_fallback']?.toString();
                      if (fallback == null ||
                          fallback.isEmpty ||
                          fallback == work['poster']) {
                        return _blankPoster();
                      }
                      return Image.network(
                        fallback,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _blankPoster(),
                      );
                    },
                  )
                : _blankPoster(),
          ),
        ),
        const SizedBox(height: 8),
        AdaptivePosterTitle(
          key: ValueKey('library-title-${work['id']}'),
          title: work['title'].toString(),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 20,
          child: Text(
            (work['year']?.toString() ?? '') +
                (work['manual_lock'] == 1 ? ' · 已手动绑定' : '') +
                (work['needs_review'] == 1 ? ' · 待复核' : ''),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    ),
  );
  Widget _blankPoster() => const ColoredBox(
    color: Color(0xff26364c),
    child: Center(
      child: Icon(Icons.movie_outlined, color: Color(0xff819ab9), size: 46),
    ),
  );

  void _browse(Map<String, Object?> source) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SourceBrowserPage(source: source)),
    );
  }

  Widget _sources(Catalog cat) => ListView(
    children: [
      for (final source in cat.sources)
        Card(
          child: ListTile(
            leading: Icon(
              source['kind'] == 'local' ? Icons.folder : Icons.cloud_outlined,
            ),
            title: Text(source['label'].toString()),
            subtitle: Text(
              '${source['location']}\n已选择 ${cat.rootsFor(source['id'].toString()).length} 个刮削范围',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _browse(source),
            trailing: Wrap(
              children: [
                IconButton(
                  tooltip: '编辑媒体源',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => SourceEditor.show(context, source),
                ),
                IconButton(
                  tooltip: '浏览云盘或本地目录并选取刮削文件夹',
                  onPressed: () => _browse(source),
                  icon: const Icon(Icons.folder_open_outlined),
                ),
                IconButton(
                  tooltip: '刮削 TMDB / Bangumi 元数据（不重新扫描视频）',
                  onPressed: cat.scanning
                      ? null
                      : () async {
                          try {
                            final report = await PersonalScrapeCoordinator()
                                .scrapeSource(
                                  source['id'].toString(),
                                  onlyPending: true,
                                );
                            _message(
                              '刮削完成：成功 ${report.matched}，待复核 ${report.review}，失败 ${report.errors}',
                            );
                          } catch (e) {
                            _message('刮削失败：$e');
                          }
                        },
                  icon: const Icon(Icons.auto_awesome_outlined),
                ),
                IconButton(
                  tooltip: '扫描已选范围',
                  onPressed: cat.scanning
                      ? null
                      : () async {
                          if (cat.rootsFor(source['id'].toString()).isEmpty) {
                            _browse(source);
                            return;
                          }
                          try {
                            await SelectedScanWorkflow.run(source);
                          } catch (_) {
                            // Progress inspector owns scanning errors; no snackbar.
                          }
                        },
                  icon: const Icon(Icons.sync),
                ),
                IconButton(
                  tooltip: '移除',
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('移除媒体源？'),
                        content: const Text('仅清除索引，不删除源文件。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('移除'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await Catalog.instance.removeSource(
                        source['id'].toString(),
                      );
                    }
                  },
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        ),
      Center(
        child: FilledButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.add),
          label: const Text('添加媒体源'),
        ),
      ),
    ],
  );
  Future<void> _add() async {
    final name = TextEditingController(),
        location = TextEditingController(),
        username = TextEditingController(),
        password = TextEditingController();
    String kind = 'webdav';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('添加媒体源'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'webdav', label: Text('WebDAV')),
                      ButtonSegment(value: 'local', label: Text('本地')),
                    ],
                    selected: {kind},
                    onSelectionChanged: (v) => update(() => kind = v.first),
                  ),
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '显示名称'),
                  ),
                  if (kind == 'local')
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text('点击添加后将打开系统文件夹选择器，可直接选择本地目录。'),
                    ),
                  if (kind == 'webdav') ...[
                    TextField(
                      controller: location,
                      decoration: const InputDecoration(
                        labelText: 'WebDAV 根目录 URL',
                      ),
                    ),
                    TextField(
                      controller: username,
                      decoration: const InputDecoration(
                        labelText: '用户名（可留空，匿名访问）',
                      ),
                    ),
                    TextField(
                      controller: password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '密码（可留空，匿名访问）',
                      ),
                    ),
                    const Text(
                      '留空用户名和密码即匿名访问。目录浏览支持 Basic/Digest 认证；公网请使用 HTTPS。',
                      style: TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      if (kind == 'local') {
        final chosen = await FilePicker.getDirectoryPath(
          dialogTitle: '选择本地媒体文件夹',
        );
        if (chosen != null && chosen.isNotEmpty) {
          final id = await Catalog.instance.addSource(
            'local',
            name.text.trim().isEmpty
                ? p.basename(p.normalize(chosen))
                : name.text.trim(),
            chosen,
          );
          if (mounted) _browse(Catalog.instance.sourceOf(id));
        }
      } else if (location.text.trim().isNotEmpty) {
        if (username.text.trim().isEmpty && password.text.isNotEmpty) {
          _message('匿名访问时密码也应留空');
          return;
        }
        final uri = Uri.tryParse(location.text.trim());
        if (uri == null ||
            !uri.hasAuthority ||
            (uri.scheme != 'http' && uri.scheme != 'https')) {
          _message('请输入有效的 http(s) WebDAV 地址');
        } else {
          final id = await Catalog.instance.addSource(
            'webdav',
            name.text.trim().isEmpty ? uri.host : name.text.trim(),
            location.text.trim(),
            username: username.text.trim(),
            password: password.text,
          );
          if (mounted) _browse(Catalog.instance.sourceOf(id));
        }
      }
    }
    name.dispose();
    location.dispose();
    username.dispose();
    password.dispose();
  }

  Future<void> _settings() => TmdbSettingsDialog.show(context);

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class WorkPage extends StatefulWidget {
  const WorkPage({super.key, required this.workId});
  final String workId;
  @override
  State<WorkPage> createState() => _WorkPageState();
}

class _WorkPageState extends State<WorkPage> {
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Catalog.instance,
    builder: (ctx, _) {
      final cat = Catalog.instance;
      final found = cat.works.where((w) => w['id'] == widget.workId).toList();
      if (found.isEmpty) {
        return const Scaffold(body: Center(child: Text('未找到作品')));
      }
      final work = found.first;
      return NipaPlayDetailPage(
        work: work,
        assets: cat.forWork(widget.workId),
        onEditMetadata: () => WorkEditDialogs.metadata(
          context,
          work,
          searchAndBind: () => _match(work),
        ),
        onEditCover: () => WorkEditDialogs.cover(context, work),
        onBack: () => Navigator.maybePop(context),
      );
    },
  );

  Future<void> _match(Map<String, Object?> work) async {
    final query = TextEditingController(
      text: Catalog.cleanTitle(work['title'].toString()),
    );
    String provider = 'tmdb';
    bool loading = false;
    String? failure;
    List<Candidate> results = [];
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('手动搜索并绑定'),
          content: SizedBox(
            width: 540,
            height: 490,
            child: Column(
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'tmdb', label: Text('TMDB')),
                    ButtonSegment(value: 'bangumi', label: Text('Bangumi')),
                  ],
                  selected: {provider},
                  onSelectionChanged: (v) => update(() {
                    provider = v.first;
                    results = [];
                  }),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: query,
                        decoration: const InputDecoration(
                          labelText: '名称或 TMDB ID',
                        ),
                      ),
                    ),
                    IconButton.filled(
                      icon: const Icon(Icons.search),
                      onPressed: loading
                          ? null
                          : () async {
                              update(() {
                                loading = true;
                                failure = null;
                              });
                              try {
                                final items = await Metadata.search(
                                  query.text,
                                  provider,
                                );
                                update(() {
                                  results = items;
                                  loading = false;
                                });
                              } catch (e) {
                                update(() {
                                  loading = false;
                                  failure = e.toString();
                                });
                              }
                            },
                    ),
                  ],
                ),
                if (loading) const LinearProgressIndicator(),
                if (failure != null)
                  Text(
                    failure!,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final result in results)
                        ListTile(
                          leading: result.poster == null
                              ? const Icon(Icons.movie)
                              : Image.network(
                                  result.poster!,
                                  width: 45,
                                  height: 65,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      const Icon(Icons.movie),
                                ),
                          title: Text(result.title),
                          subtitle: Text(
                            '${result.year?.toString() ?? '?'} · ${result.provider} #${result.id}',
                          ),
                          trailing: const Icon(Icons.link),
                          onTap: () async {
                            await Catalog.instance.bind(
                              widget.workId,
                              provider: result.provider,
                              providerId: result.id,
                              title: result.title,
                              year: result.year,
                              poster: result.poster,
                              overview: result.overview,
                              type: result.mediaType,
                            );
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
    query.dispose();
  }
}
