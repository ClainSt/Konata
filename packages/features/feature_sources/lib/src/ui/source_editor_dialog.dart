import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import '../state/sources_controller.dart';
import 'source_folder_picker_dialog.dart';

/// 打开新建或编辑媒体源毛玻璃弹窗；保存成功时返回落库后的 `MediaSource` 实例。
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

  void _syncDefaultLabelIfEmpty(String location) {
    if (_labelCtrl.text.trim().isNotEmpty) return;
    if (location.trim().isEmpty) return;
    _labelCtrl.text = deriveDefaultSourceLabel(_kind, location);
  }

  Future<void> _pickLocalDirectory() async {
    try {
      final picker = ref.read(featureSourcesDependenciesProvider).filePicker;
      final picked = await picker.pickDirectory(dialogTitle: '选择本地动画媒体目录');
      if (!mounted || picked == null || picked.trim().isEmpty) return;
      final trimmed = picked.trim();
      setState(() {
        _locationCtrl.text = trimmed;
        if (_labelCtrl.text.trim().isEmpty) {
          _labelCtrl.text = deriveDefaultSourceLabel(
            MediaSourceKind.local,
            trimmed,
          );
        }
        _formError = null;
        _testResult = null;
      });
    } catch (error) {
      if (mounted) {
        showKonataToast(context, '打开系统目录选择器失败：$error', isError: true);
      }
    }
  }

  Future<void> _runTestConnection() async {
    if (_saving || _testing) return;
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
      sourceLabel: _labelCtrl.text.trim().isEmpty
          ? null
          : _labelCtrl.text.trim(),
    );
    if (!mounted || selected == null) return;
    setState(() => _includedFolders = selected);
  }

  Future<void> _submit() async {
    if (_saving || _testing) return;
    final controller = ref.read(sourcesControllerProvider);
    final validated = controller.validateLocation(_kind, _locationCtrl.text);
    if (!validated.isValid) {
      setState(() {
        _formError = validated.errorMessage ?? '媒体源地址格式无效';
      });
      return;
    }

    final effectiveLabel = _labelCtrl.text.trim().isEmpty
        ? deriveDefaultSourceLabel(_kind, validated.normalizedLocation)
        : _labelCtrl.text.trim();

    setState(() {
      _saving = true;
      _formError = null;
    });

    final res = await controller.saveSource(
      existingId: widget.existingSource?.id,
      kind: _kind,
      label: effectiveLabel,
      location: validated.normalizedLocation,
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
    final maxBodyHeight = (screen.height * 0.68).clamp(200.0, 520.0);

    return KonataGlassDialog(
      width: 484,
      title: isEdit ? '编辑媒体源' : '添加媒体源',
      onClose: (_saving || _testing) ? () {} : () => Navigator.of(context).pop(),
      actions: [
        KonataPillButton.secondary(
          label: _testing ? '测试中...' : '测试连通',
          compact: true,
          onPressed: (_saving || _testing) ? null : _runTestConnection,
        ),
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: (_saving || _testing)
              ? null
              : () => Navigator.of(context).pop(),
        ),
        KonataPillButton.primary(
          label: _saving ? '保存中...' : '保存',
          compact: true,
          onPressed: (_saving || _testing) ? null : _submit,
        ),
      ],
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxBodyHeight),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
              const SizedBox(height: 16),
              KonataSmoothSectionSwitcher(
                switchKey: _kind,
                alignment: Alignment.topLeft,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    KonataSoftTextField(
                      controller: _labelCtrl,
                      label: '显示名称（可选，留空自动提取）',
                      hintText: '例如：NAS 番剧库 / BDRip 归档盘',
                      prefixIcon: Icons.label_outline_rounded,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Focus(
                            onFocusChange: (hasFocus) {
                              if (!hasFocus) {
                                _syncDefaultLabelIfEmpty(_locationCtrl.text);
                              }
                            },
                            child: KonataSoftTextField(
                              controller: _locationCtrl,
                              label: switch (_kind) {
                                MediaSourceKind.local => '本地目录路径',
                                MediaSourceKind.webdav => 'WebDAV 地址',
                                MediaSourceKind.smb => 'SMB 共享地址',
                              },
                              hintText: switch (_kind) {
                                MediaSourceKind.local =>
                                  KonataAdaptiveTokens.isAndroid
                                      ? '/storage/emulated/0/Anime'
                                      : r'D:\Anime',
                                MediaSourceKind.webdav =>
                                  KonataNetworkConfig.defaultWebDavHint,
                                MediaSourceKind.smb =>
                                  'smb://192.168.1.2/Anime',
                              },
                              prefixIcon: isRemote
                                  ? Icons.link_rounded
                                  : Icons.folder_open_rounded,
                            ),
                          ),
                        ),
                        if (!isRemote) ...[
                          const SizedBox(width: 10),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: KonataPillButton.secondary(
                              label: '浏览',
                              icon: Icons.folder_open_rounded,
                              onPressed: _pickLocalDirectory,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (isRemote) ...[
                      const SizedBox(height: 12),
                      KonataSoftTextField(
                        controller: _usernameCtrl,
                        label: '用户名（可选）',
                        hintText: _kind == MediaSourceKind.smb
                            ? '匿名共享可留空或填 guest'
                            : '账号名',
                        prefixIcon: Icons.person_outline_rounded,
                      ),
                      const SizedBox(height: 12),
                      IgnorePointer(
                        ignoring: _clearPassword,
                        child: Opacity(
                          opacity: _clearPassword ? 0.5 : 1,
                          child: KonataSoftTextField(
                            controller: _passwordCtrl,
                            obscureText: true,
                            label: _clearPassword
                                ? '密码（保存后将清空已存密码）'
                                : (_hasSavedPassword
                                      ? '密码（已加密存储，留空保持不变）'
                                      : '密码（安全加密存储）'),
                            prefixIcon: Icons.lock_outline_rounded,
                            onChanged: (v) {
                              if (v.isNotEmpty && _clearPassword) {
                                setState(() => _clearPassword = false);
                              }
                            },
                          ),
                        ),
                      ),
                      if (isEdit && _hasSavedPassword) ...[
                        const SizedBox(height: 6),
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() {
                              _clearPassword = !_clearPassword;
                              if (_clearPassword) _passwordCtrl.clear();
                            }),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  Checkbox(
                                    value: _clearPassword,
                                    onChanged: (v) => setState(() {
                                      _clearPassword = v ?? false;
                                      if (_clearPassword) {
                                        _passwordCtrl.clear();
                                      }
                                    }),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      '清除已存储的登录密码',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.textSecondary,
                                        fontSize: KonataTheme.fontSizeBodyXs,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 12),
                    AdaptiveResponsiveRow(
                      minLeadingWidth: 160,
                      estimatedTrailingWidth: 108,
                      leading: Text(
                        _includedFolders.isEmpty
                            ? '扫库作用域：全盘根目录'
                            : '扫库作用域：已选 ${_includedFolders.length} 个子目录',
                        style: TextStyle(
                          fontSize: KonataTheme.fontSizeBodyXs,
                          color: p.textSecondary,
                        ),
                      ),
                      trailing: KonataPillButton.secondary(
                        label: '选择范围',
                        icon: Icons.account_tree_outlined,
                        compact: true,
                        onPressed: _openScopePicker,
                      ),
                    ),
                    if (_testing) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                p.progressFill,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '正在检测媒体源连通性…',
                            style: TextStyle(
                              fontSize: KonataTheme.fontSizeBodyXs,
                              color: p.textSecondary,
                            ),
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
                    const SizedBox(height: 4),
                  ],
                ),
              ),
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
    final badge = isSuccess ? p.successBadge : p.dangerBadge;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: badge.bg,
        borderRadius: KonataTheme.borderRadiusControl,
        border: Border.all(color: badge.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isSuccess
                ? Icons.check_circle_outline_rounded
                : Icons.error_outline_rounded,
            size: 16,
            color: badge.fg,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: KonataTheme.fontSizeBodyXs,
                color: badge.fg,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
