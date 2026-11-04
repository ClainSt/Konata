import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../core/catalog.dart';
import '../core/sources.dart';

/// NipaPlay-style source editor. No explicit anonymous or password mode switch.
class SourceEditor {
  static Future<void> show(
    BuildContext context,
    Map<String, Object?> source,
  ) async {
    final catalog = Catalog.instance;
    final original = await catalog.withCredentials(source);
    if (!context.mounted) return;
    final name = TextEditingController(text: source['label']?.toString() ?? '');
    final location = TextEditingController(
      text: source['location']?.toString() ?? '',
    );
    final username = TextEditingController(
      text: source['username']?.toString() ?? '',
    );
    final password = TextEditingController();
    final webdav = source['kind'] != 'local';
    final smb = source['kind'] == 'smb';
    final previousUsername = username.text.trim();
    bool clearPassword = false, testing = false;
    String? message;

    String credentialPassword() {
      if (username.text.trim().isEmpty) return '';
      if (password.text.isNotEmpty) return password.text;
      if (clearPassword || username.text.trim() != previousUsername) return '';
      return original['password']?.toString() ?? '';
    }

    Future<void> test(StateSetter update) async {
      update(() {
        testing = true;
        message = null;
      });
      try {
        if (smb) {
          SmbSource.validateLocation(location.text.trim());
          final client = WebDav({
            'kind': 'smb',
            'location': location.text.trim(),
            'username': username.text.trim(),
            'password': credentialPassword(),
          });
          final files = await client.list(client.root);
          message = '连接成功，共享目录返回 ${files.length} 项';
        } else if (webdav) {
          final uri = Uri.tryParse(location.text.trim());
          if (uri == null ||
              !uri.hasAuthority ||
              !(uri.isScheme('http') || uri.isScheme('https'))) {
            throw StateError('WebDAV 地址无效');
          }
          if (username.text.trim().isEmpty && password.text.isNotEmpty) {
            throw StateError('匿名访问时密码也应留空');
          }
          final dav = WebDav({
            'location': location.text.trim(),
            'username': username.text.trim(),
            'password': credentialPassword(),
          });
          final files = await dav
              .list(dav.root)
              .timeout(const Duration(seconds: 18));
          message = '连接成功，根目录返回 ${files.length} 项';
        } else {
          message = await Directory(location.text.trim()).exists()
              ? '本地目录可访问'
              : '本地目录不存在';
        }
      } catch (e) {
        message = '连接失败：$e';
      }
      update(() => testing = false);
    }

    Future<void> save(BuildContext dialogContext, StateSetter update) async {
      final label = name.text.trim(),
          url = location.text.trim(),
          user = username.text.trim();
      if (label.isEmpty || url.isEmpty) {
        update(() => message = '名称和地址不能为空');
        return;
      }
      if (smb) {
        try {
          SmbSource.validateLocation(url);
        } catch (e) {
          update(() => message = '$e');
          return;
        }
      } else if (webdav) {
        final uri = Uri.tryParse(url);
        if (uri == null ||
            !uri.hasAuthority ||
            !(uri.isScheme('http') || uri.isScheme('https'))) {
          update(() => message = '请输入有效的 WebDAV 地址');
          return;
        }
        if (user.isEmpty && password.text.isNotEmpty) {
          update(() => message = '匿名访问时请同时留空用户名和密码');
          return;
        }
      }
      if (url != source['location']) {
        final proceed = await showDialog<bool>(
          context: dialogContext,
          builder: (ctx) => AlertDialog(
            title: const Text('确认更改媒体源地址'),
            content: const Text('作品、人工绑定、观看进度及源 ID 将保留。如果新目录不包含原文件，需要重新扫描。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确认修改'),
              ),
            ],
          ),
        );
        if (proceed != true || !dialogContext.mounted) return;
      }
      final newPassword = !webdav
          ? null
          : user.isEmpty
          ? ''
          : password.text.isNotEmpty
          ? password.text
          : clearPassword || user != previousUsername
          ? ''
          : null;
      try {
        await catalog.updateSource(
          source['id'].toString(),
          label: label,
          location: url,
          username: webdav ? user : '',
          password: newPassword,
        );
        if (dialogContext.mounted) Navigator.pop(dialogContext);
      } catch (e) {
        if (dialogContext.mounted) update(() => message = '保存失败：$e');
      }
    }

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, update) => AlertDialog(
            title: const Text('编辑媒体源'),
            content: SizedBox(
              width: 470,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(labelText: '媒体源名称'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: location,
                      readOnly: !webdav,
                      decoration: InputDecoration(
                        labelText: smb
                            ? 'SMB 共享地址'
                            : webdav
                            ? 'WebDAV 根目录 URL'
                            : '本地文件夹',
                      ),
                    ),
                    if (!webdav)
                      TextButton.icon(
                        onPressed: () async {
                          final selected = await FilePicker.getDirectoryPath(
                            dialogTitle: '选择本地媒体文件夹',
                          );
                          if (selected != null && dialogContext.mounted) {
                            update(() => location.text = selected);
                          }
                        },
                        icon: const Icon(Icons.folder_open),
                        label: const Text('选择文件夹'),
                      ),
                    if (webdav) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: username,
                        decoration: const InputDecoration(
                          labelText: '用户名（可留空）',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: password,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: '新密码（可留空）',
                          helperText: clearPassword
                              ? '保存后清除已有密码'
                              : '留空保留原密码；用户名和密码均留空表示匿名访问',
                          suffixIcon: IconButton(
                            icon: Icon(
                              clearPassword
                                  ? Icons.undo
                                  : Icons.backspace_outlined,
                            ),
                            tooltip: clearPassword ? '撤销清除密码' : '清除已保存密码',
                            onPressed: () => update(() {
                              clearPassword = !clearPassword;
                              if (clearPassword) password.clear();
                            }),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (message != null)
                      Text(
                        message!,
                        style: Theme.of(dialogContext).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: testing ? null : () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              OutlinedButton.icon(
                icon: testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
                onPressed: testing ? null : () => test(update),
                label: const Text('测试连接'),
              ),
              FilledButton(
                onPressed: testing ? null : () => save(dialogContext, update),
                child: const Text('保存'),
              ),
            ],
          ),
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
