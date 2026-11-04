import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:media_kit/media_kit.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:window_manager/window_manager.dart';
import 'core/app_theme.dart';
import 'ui/app_header.dart';
import 'ui/settings_page.dart';
import 'ui/add_media_dialog.dart';
import 'core/sources.dart';
import 'core/catalog.dart';
import 'core/metadata.dart';

import 'ui/source_browser_page.dart';
import 'ui/poster_title.dart';
import 'ui/source_editor.dart';
import 'ui/nipaplay_detail_page.dart';
import 'ui/nipaplay_style.dart';
import 'ui/work_edit_dialogs.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (AppHeader.desktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'CCPlayer',
        minimumSize: Size(640, 480),
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
    );
  }
  await AppTheme.instance.load();
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

final libraryDestination = ValueNotifier<bool>(false);

class CCPlayer extends StatefulWidget {
  const CCPlayer({super.key});
  @override
  State<CCPlayer> createState() => _CCPlayerState();
}

class _CCPlayerState extends State<CCPlayer> {
  final navigatorKey = GlobalKey<NavigatorState>();
  Widget _navigation() => ValueListenableBuilder<bool>(
    valueListenable: libraryDestination,
    builder: (context, sources, _) => AppHeader(
      showSources: sources,
      onNavigate: (value) {
        navigatorKey.currentState?.popUntil((route) => route.isFirst);
        libraryDestination.value = value;
      },
      onSettings: () => showDialog<void>(
        context: navigatorKey.currentContext!,
        builder: (_) => const SettingsPage(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: AppTheme.instance,
    builder: (context, _) => MaterialApp(
      navigatorKey: navigatorKey,
      title: 'CCPlayer',
      debugShowCheckedModeBanner: false,
      theme: NipaPlayStyle.theme(Brightness.light),
      darkTheme: NipaPlayStyle.theme(Brightness.dark),
      themeMode: AppTheme.instance.mode,
      builder: (context, child) => Overlay.wrap(
        child: Column(
          children: [
            if (AppHeader.desktop) _navigation(),
            Expanded(child: child!),
            if (!AppHeader.desktop) _navigation(),
          ],
        ),
      ),
      home: const LibraryPage(),
    ),
  );
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  bool get showSources => libraryDestination.value;
  @override
  void initState() {
    super.initState();
    libraryDestination.addListener(_destinationChanged);
  }

  void _destinationChanged() => setState(() {});
  @override
  void dispose() {
    libraryDestination.removeListener(_destinationChanged);
    super.dispose();
  }

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
        body: Column(
          children: [
            if (cat.scanning) const LinearProgressIndicator(),
            _libraryToolbar(cat),
            Expanded(
              child: showSources
                  ? _sources(cat)
                  : matches.isEmpty
                  ? Center(
                      child: Text(cat.sources.isEmpty ? '请先添加媒体源' : '暂无匹配作品'),
                    )
                  : LayoutBuilder(
                      builder: (ctx, bounds) {
                        // Poster-first cards: only a 2:3 cover and one compact title line.
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
                        final cardHeight = cardWidth * 1.5 + 8 + 22;
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
  Widget _libraryToolbar(Catalog cat) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
    child: LayoutBuilder(
      builder: (context, bounds) {
        final search = SizedBox(
          height: 42,
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: '搜索动画',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              fillColor: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: .045),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            onChanged: (value) => setState(() => filter = value),
          ),
        );
        final row = Row(
          children: [
            Text(
              showSources
                  ? '${cat.sources.length} 个媒体源'
                  : '${cat.works.length} 部作品',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .55),
              ),
            ),
            const Spacer(),
            if (!showSources && bounds.maxWidth >= 700) ...[
              SizedBox(width: 280, child: search),
              const SizedBox(width: 16),
            ],
            if (cat.hiddenWorkEntries.isNotEmpty)
              IconButton(
                key: const ValueKey('manage-hidden-works-button'),
                onPressed: _manageHiddenWorks,
                tooltip: '管理已隐藏作品',
                icon: const Icon(Icons.visibility_off_outlined),
              ),
            Tooltip(
              message: '添加媒体源',
              child: TextButton.icon(
                style: ButtonStyle(
                  foregroundColor: WidgetStateProperty.resolveWith(
                    (states) =>
                        states.contains(WidgetState.hovered) ||
                            states.contains(WidgetState.focused) ||
                            states.contains(WidgetState.pressed)
                        ? NipaPlayStyle.accent
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: .6),
                  ),
                  overlayColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  textStyle: const WidgetStatePropertyAll(
                    TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                onPressed: _add,
                icon: const Icon(Icons.add, size: 20),
                label: const Text('添加媒体源'),
              ),
            ),
          ],
        );
        return Column(
          children: [
            row,
            if (!showSources && bounds.maxWidth < 700) ...[
              const SizedBox(height: 12),
              search,
            ],
          ],
        );
      },
    ),
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
        SizedBox(
          height: 22,
          child: Align(
            alignment: Alignment.topLeft,
            child: PosterTitle(
              key: ValueKey('library-title-${work['id']}'),
              title: work['title'].toString(),
            ),
          ),
        ),
      ],
    ),
  );
  Widget _blankPoster() => const ColoredBox(
    color: Color(0xffeeeeee),
    child: Center(
      child: Icon(Icons.movie_outlined, color: Colors.grey, size: 46),
    ),
  );

  void _browse(Map<String, Object?> source) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SourceBrowserPage(source: source)),
    );
  }

  Widget _sources(Catalog cat) => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    children: [
      for (final source in cat.sources)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: .08),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: LayoutBuilder(
                    builder: (context, bounds) {
                      final info = InkWell(
                        onTap: () => _browse(source),
                        borderRadius: BorderRadius.circular(8),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: .09),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                source['kind'] == 'local'
                                    ? Icons.folder_outlined
                                    : Icons.cloud_outlined,
                                size: 23,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    source['label'].toString(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    '${source['kind'] == 'local'
                                        ? '本地目录'
                                        : source['kind'] == 'smb'
                                        ? 'SMB'
                                        : 'WebDAV'} · ${source['location']}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1.5,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: .55),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                      final actions = Wrap(
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
                            tooltip: '移除',
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('移除媒体源？'),
                                  content: const Text('仅清除索引，不删除源文件。'),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
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
                      );
                      return bounds.maxWidth >= 540
                          ? Row(
                              children: [
                                Expanded(child: info),
                                const SizedBox(width: 20),
                                actions,
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                info,
                                const SizedBox(height: 10),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: actions,
                                ),
                              ],
                            );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
  Future<void> _add() async {
    final kind = await AddMediaDialog.show(context);
    if (kind == null || !mounted) return;
    final name = TextEditingController(),
        location = TextEditingController(),
        username = TextEditingController(),
        password = TextEditingController();
    bool obscurePassword = true;
    InputDecoration fieldDecoration(String label, {Widget? suffixIcon}) =>
        InputDecoration(
          labelText: label,
          suffixIcon: suffixIcon,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: .25),
            ),
          ),
        );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 20, 12, 8),
          contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  kind == 'local'
                      ? '添加本地文件夹'
                      : kind == 'smb'
                      ? '添加 SMB 共享'
                      : '添加 WebDAV 服务器',
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(ctx, false),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (kind != 'local') ...[
                    Text(
                      '连接后可手动选择需要扫描的文件夹。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(
                          ctx,
                        ).colorScheme.onSurface.withValues(alpha: .65),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  TextField(
                    controller: name,
                    decoration: fieldDecoration('连接名称（可选）'),
                  ),
                  if (kind == 'local')
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text('点击添加后将打开系统文件夹选择器，可直接选择本地目录。'),
                    ),
                  if (kind != 'local') ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: location,
                      decoration: fieldDecoration(
                        kind == 'smb' ? 'SMB 地址（smb://主机/共享目录）' : 'WebDAV 地址',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: username,
                      decoration: fieldDecoration(
                        kind == 'smb' ? r'用户名（可选，支持 域\用户名）' : '用户名（可选）',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: password,
                      obscureText: obscurePassword,
                      decoration: fieldDecoration(
                        '密码（可选）',
                        suffixIcon: IconButton(
                          tooltip: obscurePassword ? '显示密码' : '隐藏密码',
                          onPressed: () =>
                              update(() => obscurePassword = !obscurePassword),
                          icon: Icon(
                            obscurePassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '无需认证时，用户名和密码留空即可。',
                      style: TextStyle(
                        color: Theme.of(
                          ctx,
                        ).colorScheme.onSurface.withValues(alpha: .6),
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
        if (kind == 'smb') {
          try {
            SmbSource.validateLocation(location.text.trim());
            final id = await Catalog.instance.addSource(
              'smb',
              name.text.trim().isEmpty ? uri!.host : name.text.trim(),
              location.text.trim(),
              username: username.text.trim(),
              password: password.text,
            );
            if (mounted) _browse(Catalog.instance.sourceOf(id));
          } catch (e) {
            _message('添加 SMB 失败：$e');
          }
        } else if (uri == null ||
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

  Future<void> _manageHiddenWorks() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AnimatedBuilder(
      animation: Catalog.instance,
      builder: (context, _) {
        final hidden = Catalog.instance.hiddenWorkEntries;
        return AlertDialog(
          title: const Text('管理已隐藏作品'),
          content: SizedBox(
            width: 560,
            height: 350,
            child: hidden.isEmpty
                ? const Center(child: Text('暂无已隐藏作品'))
                : ListView.builder(
                    itemCount: hidden.length,
                    itemBuilder: (context, index) {
                      final work = hidden[index];
                      return ListTile(
                        title: Text(work['title']?.toString() ?? ''),
                        subtitle: Text(
                          work['keep_hidden'] == 1
                              ? '重新扫描后仍保持隐藏'
                              : '重新扫描后会自动恢复',
                        ),
                        trailing: TextButton.icon(
                          onPressed: () async {
                            await Catalog.instance.restoreWork(
                              work['id'].toString(),
                            );
                          },
                          icon: const Icon(Icons.visibility_outlined),
                          label: const Text('恢复显示'),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    ),
  );

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
        onDelete: () => _deleteWork(work),
        onBack: () => Navigator.maybePop(context),
      );
    },
  );

  Future<void> _deleteWork(Map<String, Object?> work) async {
    if (Catalog.instance.scanning) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('扫描或刮削进行中，请完成后再移除作品')));
      return;
    }
    var keepHidden = false;
    final decision = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: const Text('从媒体库删除该作品？'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(work['title']?.toString() ?? ''),
                const SizedBox(height: 12),
                const Text('仅从 CCPlayer 媒体库中移除，不会删除本地或云盘源文件、人工关联和观看进度。'),
                const SizedBox(height: 10),
                CheckboxListTile(
                  key: const ValueKey('keep-work-hidden-checkbox'),
                  value: keepHidden,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('重新扫描后仍保持隐藏'),
                  subtitle: const Text('不勾选时，重新扫描该作品会再次显示'),
                  onChanged: (value) =>
                      update(() => keepHidden = value ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('confirm-remove-work'),
              onPressed: () => Navigator.pop(dialogContext, keepHidden),
              child: const Text('从媒体库移除'),
            ),
          ],
        ),
      ),
    );
    if (decision == null || !mounted) return;
    try {
      await Catalog.instance.hideWork(widget.workId, keepHidden: decision);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移除作品失败：$error')));
      }
    }
  }

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
