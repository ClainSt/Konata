import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../domain/models/media_source.dart';
import '../../domain/models/network_config.dart';
import '../../domain/sources/source_location_validator.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';

/// 添加或编辑媒体源毛玻璃弹窗（支持本地磁盘、WebDAV、SMB 三类源与连通测试）。
class SourceEditorDialog extends StatefulWidget {
  /// 创建媒体源编辑弹窗。
  const SourceEditorDialog({
    super.key,
    this.existing,
    required this.onSave,
    this.onTestConnection,
  });

  /// 若不为空则进入编辑模式。
  final MediaSource? existing;

  /// 保存回调。
  final Future<void> Function(
    MediaSource source,
    String? password, {
    bool clearPassword,
  })
  onSave;

  /// 弹窗内实时「测试连通」回调（成功返回 `null`，失败返回中文原因）。
  final Future<String?> Function(
    MediaSource draft, {
    String? passwordOverride,
    bool clearPassword,
  })?
  onTestConnection;

  @override
  State<SourceEditorDialog> createState() => _SourceEditorDialogState();
}

class _SourceEditorDialogState extends State<SourceEditorDialog> {
  late MediaSourceKind _kind;
  late final TextEditingController _labelController;
  late final TextEditingController _locationController;
  late final TextEditingController _usernameController;
  final TextEditingController _passwordController = TextEditingController();
  bool _saving = false;
  bool _testing = false;
  bool _clearPassword = false;
  String? _errorText;
  String? _testFeedback;
  bool _testSuccess = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = e?.kind ?? MediaSourceKind.local;
    _labelController = TextEditingController(text: e?.label ?? '');
    _locationController = TextEditingController(text: e?.location ?? '');
    _usernameController = TextEditingController(text: e?.username ?? '');
  }

  @override
  void dispose() {
    _labelController.dispose();
    _locationController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _pickLocalDirectory() async {
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: '选择本地动画媒体目录',
    );
    if (selected != null && selected.isNotEmpty) {
      _locationController.text = selected;
      if (_labelController.text.trim().isEmpty) {
        _labelController.text = deriveDefaultSourceLabel(
          MediaSourceKind.local,
          selected,
        );
      }
    }
  }

  void _syncDefaultLabelIfEmpty(String location) {
    if (_labelController.text.trim().isNotEmpty) return;
    if (location.trim().isEmpty) return;
    _labelController.text = deriveDefaultSourceLabel(_kind, location);
  }

  MediaSource? _buildValidatedDraft() {
    final validated = SourceLocationValidator.validate(
      _kind,
      _locationController.text,
    );
    if (!validated.isValid) {
      setState(() => _errorText = validated.errorMessage ?? '媒体源地址格式无效');
      return null;
    }
    if (validated.normalizedLocation != _locationController.text.trim()) {
      _locationController.text = validated.normalizedLocation;
    }
    final rawLabel = _labelController.text.trim();
    final label = rawLabel.isEmpty
        ? deriveDefaultSourceLabel(_kind, validated.normalizedLocation)
        : rawLabel;
    final id =
        widget.existing?.id ?? 'src_${DateTime.now().microsecondsSinceEpoch}';
    return MediaSource(
      id: id,
      kind: _kind,
      label: label,
      location: validated.normalizedLocation,
      username: _kind == MediaSourceKind.local
          ? null
          : _usernameController.text.trim(),
      createdAt: widget.existing?.createdAt ?? DateTime.now(),
    );
  }

  Future<void> _handleTest() async {
    if (_saving || _testing || widget.onTestConnection == null) return;
    setState(() {
      _errorText = null;
      _testFeedback = null;
    });
    final draft = _buildValidatedDraft();
    if (draft == null) return;

    setState(() => _testing = true);
    try {
      final pwd = _passwordController.text;
      final error = await widget.onTestConnection!(
        draft,
        passwordOverride:
            (_clearPassword || pwd.isEmpty) ? null : pwd,
        clearPassword: _clearPassword,
      );
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testSuccess = error == null;
        _testFeedback = error ?? '连通测试成功，服务器与凭据验证通过';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testSuccess = false;
        _testFeedback = '测试连通异常: $error';
      });
    }
  }

  Future<void> _submit() async {
    setState(() {
      _errorText = null;
      _testFeedback = null;
    });
    final source = _buildValidatedDraft();
    if (source == null) return;

    setState(() => _saving = true);
    try {
      final pwd = _passwordController.text;
      await widget.onSave(
        source,
        (_clearPassword || pwd.isEmpty) ? null : pwd,
        clearPassword: _clearPassword,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorText = '保存失败: $error';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isRemote = _kind != MediaSourceKind.local;

    return KonataGlassDialog(
      width: 484,
      title: widget.existing == null ? '添加媒体源' : '编辑媒体源',
      onClose: (_saving || _testing) ? () {} : () => Navigator.of(context).pop(),
      actions: [
        if (widget.onTestConnection != null)
          KonataPillButton.secondary(
            label: _testing ? '测试中...' : '测试连通',
            compact: true,
            onPressed: (_saving || _testing) ? null : _handleTest,
          ),
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed:
              (_saving || _testing) ? null : () => Navigator.of(context).pop(),
        ),
        KonataPillButton.primary(
          label: _saving ? '保存中...' : '保存',
          compact: true,
          onPressed: (_saving || _testing) ? null : _submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AbsorbPointer(
            absorbing: widget.existing != null,
            child: Opacity(
              opacity: widget.existing != null ? 0.65 : 1,
              child: KonataSegmentedCapsule<MediaSourceKind>(
                selected: _kind,
                options: const [
                  KonataSegmentOption(
                    value: MediaSourceKind.local,
                    label: '本地目录',
                  ),
                  KonataSegmentOption(
                    value: MediaSourceKind.webdav,
                    label: 'WebDAV',
                  ),
                  KonataSegmentOption(
                    value: MediaSourceKind.smb,
                    label: 'SMB 共享',
                  ),
                ],
                onChanged: (value) => setState(() => _kind = value),
              ),
            ),
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
                  controller: _labelController,
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
                            _syncDefaultLabelIfEmpty(_locationController.text);
                          }
                        },
                        child: KonataSoftTextField(
                          controller: _locationController,
                          label: switch (_kind) {
                            MediaSourceKind.local => '本地目录路径',
                            MediaSourceKind.webdav => 'WebDAV 地址',
                            MediaSourceKind.smb => 'SMB 共享地址',
                          },
                          hintText: switch (_kind) {
                            MediaSourceKind.local => r'D:\Anime',
                            MediaSourceKind.webdav =>
                              TmdbNetworkConfig.defaultWebDavHint,
                            MediaSourceKind.smb => 'smb://192.168.1.2/Anime',
                          },
                          prefixIcon: Icons.link_rounded,
                        ),
                      ),
                    ),
                    if (_kind == MediaSourceKind.local) ...[
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
                    controller: _usernameController,
                    label: '用户名（可选）',
                    prefixIcon: Icons.person_outline_rounded,
                  ),
                  const SizedBox(height: 12),
                  IgnorePointer(
                    ignoring: _clearPassword,
                    child: Opacity(
                      opacity: _clearPassword ? 0.5 : 1,
                      child: KonataSoftTextField(
                        controller: _passwordController,
                        obscureText: true,
                        label: _clearPassword
                            ? '密码（保存后将清空已存密码）'
                            : (widget.existing == null
                                  ? '密码（安全加密存储）'
                                  : '密码（留空保持不变）'),
                        prefixIcon: Icons.lock_outline_rounded,
                      ),
                    ),
                  ),
                  if (widget.existing != null) ...[
                    const SizedBox(height: 6),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() {
                          _clearPassword = !_clearPassword;
                          if (_clearPassword) _passwordController.clear();
                        }),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Checkbox(
                                value: _clearPassword,
                                onChanged: (v) => setState(() {
                                  _clearPassword = v ?? false;
                                  if (_clearPassword) _passwordController.clear();
                                }),
                                visualDensity: VisualDensity.compact,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '清除已存储的登录密码',
                                style: TextStyle(
                                  color: p.textSecondary,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          if (_testFeedback != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: (_testSuccess ? p.success : p.danger).withValues(
                  alpha: 0.12,
                ),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: (_testSuccess ? p.success : p.danger).withValues(
                    alpha: 0.4,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _testSuccess
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                    size: 16,
                    color: _testSuccess ? p.success : p.danger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _testFeedback!,
                      style: TextStyle(
                        color: _testSuccess ? p.success : p.danger,
                        fontSize: 12.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_errorText != null) ...[
            const SizedBox(height: 10),
            Text(
              _errorText!,
              style: TextStyle(color: p.danger, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }
}
