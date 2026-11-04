import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../core/catalog.dart';
import '../core/sources.dart';

class SourceEditor {
  static Future<void> show(
    BuildContext context,
    Map<String, Object?> source,
  ) async {
    final cat = Catalog.instance;
    final current = await cat.withCredentials(source);
    if (!context.mounted) return;
    final name = TextEditingController(text: source['label'].toString());
    final location = TextEditingController(text: source['location'].toString());
    final username = TextEditingController(
      text: source['username']?.toString() ?? '',
    );
    final password = TextEditingController();
    final webdav = source['kind'] == 'webdav';
    var anonymous = webdav && username.text.trim().isEmpty;
    var replacePassword = false;
    var testing = false;
    String? result;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, refresh) {
            Future<void> chooseFolder() async {
              final picked = await FilePicker.getDirectoryPath(
                dialogTitle: '更改本地媒体文件夹',
              );
              if (picked != null && dialogContext.mounted) {
                refresh(() => location.text = picked);
              }
            }

            Future<void> test() async {
              refresh(() {
                testing = true;
                result = null;
              });
              try {
                if (webdav) {
                  final creds = {
                    'location': location.text.trim(),
                    'username': anonymous ? '' : username.text.trim(),
                    'password': anonymous
                        ? ''
                        : replacePassword
                        ? password.text
                        : current['password']?.toString() ?? '',
                  };
                  final uri = Uri.tryParse(creds['location']!);
                  if (uri == null ||
                      !uri.hasAuthority ||
                      !(uri.isScheme('http') || uri.isScheme('https'))) {
                    throw StateError('WebDAV 地址格式无效');
                  }
                  final dav = WebDav(creds);
                  final entries = await dav
                      .list(dav.root)
                      .timeout(const Duration(seconds: 18));
                  result = '连接成功，根目录返回 ${entries.length} 个项目';
                } else {
                  result = await Directory(location.text.trim()).exists()
                      ? '目录可访问'
                      : '本地目录不存在';
                }
              } catch (e) {
                result = '连接失败：$e';
              }
              if (dialogContext.mounted) refresh(() => testing = false);
            }

            Future<void> save() async {
              final label = name.text.trim();
              final url = location.text.trim();
              if (label.isEmpty || url.isEmpty) {
                refresh(() => result = '名称和地址不能为空');
                return;
              }
              if (webdav) {
                final uri = Uri.tryParse(url);
                if (uri == null ||
                    !uri.hasAuthority ||
                    !(uri.isScheme('http') || uri.isScheme('https'))) {
                  refresh(() => result = '请输入有效的 WebDAV HTTP(S) 地址');
                  return;
                }
              }
              if (!anonymous &&
                  username.text.trim().isEmpty &&
                  replacePassword &&
                  password.text.isNotEmpty) {
                refresh(() => result = '匿名访问时请不要单独输入密码');
                return;
              }
              if (url != source['location']) {
                final confirmed = await showDialog<bool>(
                  context: dialogContext,
                  builder: (ctx) => AlertDialog(
                    title: const Text('确认更改媒体源位置'),
                    content: const Text(
                      '媒体源 ID、海报、人工绑定、进度和已选扫描范围将保留。若新位置不包含原文件，相应视频可能暂时无法播放，需要重新扫描确认。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('继续保存'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
              }
              try {
                await cat.updateSource(
                  source['id'].toString(),
                  label: label,
                  location: url,
                  username: webdav
                      ? (anonymous ? '' : username.text.trim())
                      : '',
                  password: webdav
                      ? (anonymous
                            ? ''
                            : replacePassword
                            ? password.text
                            : null)
                      : null,
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (e) {
                if (dialogContext.mounted) refresh(() => result = '保存失败：$e');
              }
            }

            return AlertDialog(
              title: const Text('编辑媒体源'),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(labelText: '媒体源名称'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: location,
                        readOnly: !webdav,
                        decoration: InputDecoration(
                          labelText: webdav ? 'WebDAV 根目录 URL' : '本地文件夹',
                        ),
                      ),
                      if (!webdav)
                        TextButton.icon(
                          icon: const Icon(Icons.folder_open),
                          onPressed: chooseFolder,
                          label: const Text('选择其他本地文件夹'),
                        ),
                      if (webdav) ...[
                        const SizedBox(height: 12),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('匿名访问（无需用户名和密码）'),
                          value: anonymous,
                          onChanged: (value) =>
                              refresh(() => anonymous = value ?? false),
                        ),
                        if (!anonymous) ...[
                          TextField(
                            controller: username,
                            decoration: const InputDecoration(labelText: '用户名'),
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('更改或清除密码'),
                            subtitle: const Text('不勾选则保留已保存的密码。勾选后留空代表使用空密码。'),
                            value: replacePassword,
                            onChanged: (value) =>
                                refresh(() => replacePassword = value ?? false),
                          ),
                          if (replacePassword)
                            TextField(
                              controller: password,
                              obscureText: true,
                              decoration: const InputDecoration(
                                labelText: '新密码（可留空）',
                              ),
                            ),
                        ],
                      ],
                      const SizedBox(height: 8),
                      if (result != null)
                        Text(
                          result!,
                          style: Theme.of(dialogContext).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: testing
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                OutlinedButton.icon(
                  onPressed: testing ? null : test,
                  icon: testing
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: const Text('测试连接'),
                ),
                FilledButton(
                  onPressed: testing ? null : save,
                  child: const Text('保存'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      name.dispose();
      location.dispose();
      username.dispose();
      password.dispose();
    }
  }
}
