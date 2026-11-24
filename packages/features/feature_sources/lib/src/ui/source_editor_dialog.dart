import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/sources_controller.dart';
import 'source_folder_picker_dialog.dart';

/// 打开新建或编辑媒体源弹窗；保存成功时返回落库后的 `MediaSource` 实例。
Future<MediaSource?> showSourceEditorDialog(
  BuildContext context, {
  MediaSource? existingSource,
}) {
  return showKonataGlassDialog<MediaSource>(
    context: context,
    builder: (_) => _SourceEditorDialog(existingSource: existingSource),
  );
}

class _SourceEditorDialog extends ConsumerStatefulWidget {
  const _SourceEditorDialog({this.existingSource});

  final MediaSource? existingSource;

  @override
  ConsumerState<_SourceEditorDialog> createState() =>
      _SourceEditorDialogState();
}

class _SourceEditorDialogState extends ConsumerState<_SourceEditorDialog> {
  late MediaSourceKind _kind;
  late final TextEditingController _labelCtrl;
  late final TextEditingController _locationCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _passwordCtrl;

  List<String> _includedFolders = const <String>[];
  bool _hasSavedPassword = false;
  bool _clearPassword = false;
  bool _testing = false;
  bool _saving = false;
  SourceTestResult? _testResult;
  String? _formError;

  @override
  void initState() {
    super.initState();
    final src = widget.existingSource;
    _kind = src?.kind ?? MediaSourceKind.local;
    _labelCtrl = TextEditingController(text: src?.label ?? '');
    _locationCtrl = TextEditingController(text: src?.location ?? '');
    _usernameCtrl = TextEditingController(text: src?.username ?? '');
    _passwordCtrl = TextEditingController();
    _includedFolders = src == null
        ? const <String>[]
        : ref.read(sourcesControllerProvider).readIncludedFolders(src.id);

    if (src != null && src.kind != MediaSourceKind.local) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadSavedPasswordFlag(src.id);
      });
    }
  }

  Future<void> _loadSavedPasswordFlag(String sourceId) async {
    final pwd = await ref
        .read(sourcesControllerProvider)
        .readSavedPassword(sourceId);
    if (!mounted) return;
    setState(() {
      _hasSavedPassword = pwd != null && pwd.isNotEmpty;
    });
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _locationCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickLocalDirectory() async {
    final picker = ref.read(featureSourcesDependenciesProvider).filePicker;
    final picked = await picker.pickDirectory(dialogTitle: '选择本地动画目录');
    if (!mounted || picked == null || picked.trim().isEmpty) return;
    setState(() {
      _locationCtrl.text = picked.trim();
      if (_labelCtrl.text.trim().isEmpty) {
        final normalized = picked.trim().replaceAll('\\', '/');
        final parts = normalized.split('/').where((s) => s.isNotEmpty).toList();
        if (parts.isNotEmpty) {
          _labelCtrl.text = parts.last;
        }
      }
      _formError = null;
      _testResult = null;
    });
  }

  Future<void> _runTestConnection() async {
    setState(() {
      _testing = true;
      _formError = null;
    });
    final controller = ref.read(sourcesControllerProvider);
    final res = await controller.testConnection(
      sourceId: widget.existingSource?.id,
      kind: _kind,
      location: _locationCtrl.text,
      username: _usernameCtrl.text,
      password: _passwordCtrl.text,
      clearPassword: _clearPassword,
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = res;
    });
  }

  Future<void> _openScopePicker() async {
    final controller = ref.read(sourcesControllerProvider);
    final validated = controller.validateLocation(_kind, _locationCtrl.text);
    if (!validated.isValid) {
      setState(() => _formError = validated.errorMessage);
      return;
    }

    final selected = await showSourceFolderPickerDialog(
      context,
      sourceId: widget.existingSource?.id,
      kind: _kind,
      location: validated.normalizedLocation,
      username: _usernameCtrl.text,
      password: _passwordCtrl.text,
      clearPassword: _clearPassword,
      initialSelected: _includedFolders,
    );
    if (!mounted || selected == null) return;
    setState(() => _includedFolders = selected);
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _formError = null;
    });
    final controller = ref.read(sourcesControllerProvider);
    final res = await controller.saveSource(
      existingId: widget.existingSource?.id,
      kind: _kind,
      label: _labelCtrl.text,
      location: _locationCtrl.text,
      username: _usernameCtrl.text,
      password: _passwordCtrl.text,
      clearPassword: _clearPassword,
      includedFolders: _includedFolders,
    );
    if (!mounted) return;
    if (res.success && res.source != null) {
      Navigator.of(context).pop(res.source);
      return;
    }
    setState(() {
      _saving = false;
      _formError = res.errorMessage ?? '保存失败，请检查表单内容';
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isEdit = widget.existingSource != null;
    final isRemote = _kind != MediaSourceKind.local;
    final screen = MediaQuery.sizeOf(context);
    final maxBodyHeight = (screen.height * 0.68).clamp(240.0, 520.0);

    return KonataGlassDialog(
      title: isEdit ? '编辑媒体源' : '添加媒体源',
      width: (screen.width - 32).clamp(300.0, 520.0),
      actions: [
        KonataPillButton.ghost(
          label: '测试连通',
          icon: Icons.wifi_tethering_rounded,
          onPressed: (_testing || _saving) ? null : _runTestConnection,
        ),
        KonataPillButton.ghost(
          label: '取消',
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        KonataPillButton.primary(
          label: _saving ? '保存中…' : '保存',
          onPressed: _saving ? null : _submit,
        ),
      ],
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxBodyHeight),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              KonataSegmentedCapsule<MediaSourceKind>(
                selected: _kind,
                expand: true,
                options: const [
                  KonataSegmentOption(
                    value: MediaSourceKind.local,
                    label: '本地目录',
                    icon: Icons.folder_outlined,
                  ),
                  KonataSegmentOption(
                    value: MediaSourceKind.webdav,
                    label: 'WebDAV',
                    icon: Icons.cloud_outlined,
                  ),
                  KonataSegmentOption(
                    value: MediaSourceKind.smb,
                    label: 'SMB 共享',
                    icon: Icons.dns_outlined,
                  ),
                ],
                onChanged: (next) {
                  setState(() {
                    _kind = next;
                    _testResult = null;
                    _formError = null;
                    if (next == MediaSourceKind.local) {
                      _clearPassword = false;
                    }
                  });
                },
              ),
              const SizedBox(height: 14),
              KonataSoftTextField(
                controller: _labelCtrl,
                label: '名称',
                hintText: '例如：NAS 动画库 / 本地移动硬盘',
                prefixIcon: Icons.label_outline_rounded,
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: KonataSoftTextField(
                      controller: _locationCtrl,
                      label: switch (_kind) {
                        MediaSourceKind.local => '本地目录路径',
                        MediaSourceKind.webdav => 'WebDAV 服务地址',
                        MediaSourceKind.smb => 'SMB 共享地址',
                      },
                      hintText: switch (_kind) {
                        MediaSourceKind.local => r'例如：D:\Anime 或 /storage/Anime',
                        MediaSourceKind.webdav => '例如：https://nas.local:5006/anime',
                        MediaSourceKind.smb => r'例如：smb://192.168.1.2/Anime',
                      },
                      prefixIcon: isRemote
                          ? Icons.link_rounded
                          : Icons.folder_open_rounded,
                    ),
                  ),
                  if (!isRemote) ...[
                    const SizedBox(width: 8),
                    KonataPillButton.secondary(
                      label: '浏览',
                      icon: Icons.folder_open_rounded,
                      onPressed: _pickLocalDirectory,
                    ),
                  ],
                ],
              ),
              if (isRemote) ...[
                const SizedBox(height: 12),
                KonataSoftTextField(
                  controller: _usernameCtrl,
                  label: '用户名（可选）',
                  hintText: _kind == MediaSourceKind.smb ? '匿名共享可留空或填 guest' : '账号名',
                  prefixIcon: Icons.person_outline_rounded,
                ),
                const SizedBox(height: 12),
                KonataSoftTextField(
                  controller: _passwordCtrl,
                  label: _hasSavedPassword ? '访问密码（已加密保存）' : '访问密码（可选）',
                  hintText: _hasSavedPassword && !_clearPassword
                      ? '留空将保留已加密保存的旧密码'
                      : '输入密码（仅写入系统安全凭据库）',
                  obscureText: true,
                  prefixIcon: Icons.lock_outline_rounded,
                  onChanged: (v) {
                    if (v.isNotEmpty && _clearPassword) {
                      setState(() => _clearPassword = false);
                    }
                  },
                ),
                if (_hasSavedPassword) ...[
                  const SizedBox(height: 8),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() {
                      _clearPassword = !_clearPassword;
                      if (_clearPassword) _passwordCtrl.clear();
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Checkbox(
                            value: _clearPassword,
                            onChanged: (val) => setState(() {
                              _clearPassword = val ?? false;
                              if (_clearPassword) _passwordCtrl.clear();
                            }),
                          ),
                          Expanded(
                            child: Text(
                              '清除此前保存的密码并改为匿名连接',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: p.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _includedFolders.isEmpty
                          ? '扫库作用域：全盘根目录'
                          : '扫库作用域：已选 ${_includedFolders.length} 个子目录',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: p.textSecondary,
                      ),
                    ),
                  ),
                  KonataPillButton.secondary(
                    label: '选择范围',
                    icon: Icons.account_tree_outlined,
                    compact: true,
                    onPressed: _openScopePicker,
                  ),
                ],
              ),
              if (_testing) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '正在检测媒体源连通性…',
                      style: TextStyle(fontSize: 12.5, color: p.textSecondary),
                    ),
                  ],
                ),
              ],
              if (_testResult != null) ...[
                const SizedBox(height: 12),
                _StatusCallout(
                  isSuccess: _testResult!.success,
                  text: _testResult!.message,
                ),
              ],
              if (_formError != null) ...[
                const SizedBox(height: 12),
                _StatusCallout(isSuccess: false, text: _formError!),
              ],
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCallout extends StatelessWidget {
  const _StatusCallout({required this.isSuccess, required this.text});

  final bool isSuccess;
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = isSuccess ? p.success : p.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isSuccess
                ? Icons.check_circle_outline_rounded
                : Icons.error_outline_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, color: color, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
