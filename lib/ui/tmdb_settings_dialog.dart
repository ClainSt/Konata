import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/metadata.dart';
import '../core/tmdb_auth.dart';

class TmdbSettingsDialog {
  static Future<void> show(BuildContext context) async {
    const secrets = FlutterSecureStorage();
    final token = TextEditingController(text: Metadata.token);
    final apiKey = TextEditingController(text: Metadata.apiKey);
    var mode = Metadata.authMode;
    var testing = false;
    String? result;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, refresh) {
            final controller = mode == 'token' ? token : apiKey;
            Future<void> test() async {
              refresh(() {
                result = null;
                testing = true;
              });
              try {
                final auth = TmdbCredentials(
                  mode: mode,
                  value: controller.text.trim(),
                );
                if (!auth.isConfigured) throw StateError('请先输入凭证');
                await Metadata.testTmdbCredentials(auth);
                result = 'TMDB 连接验证成功';
              } catch (e) {
                result = '验证失败：$e';
              }
              if (dialogContext.mounted) refresh(() => testing = false);
            }

            Future<void> save() async {
              final value = controller.text.trim();
              if (value.isEmpty) {
                refresh(() => result = '请先填写所选认证方式的凭证');
                return;
              }
              try {
                await secrets.write(
                  key: 'tmdb_token',
                  value: token.text.trim(),
                );
                await secrets.write(
                  key: 'tmdb_api_key',
                  value: apiKey.text.trim(),
                );
                await secrets.write(key: 'tmdb_auth_mode', value: mode);
                Metadata.token = token.text.trim();
                Metadata.apiKey = apiKey.text.trim();
                Metadata.authMode = mode;
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (e) {
                if (dialogContext.mounted) refresh(() => result = '保存失败：$e');
              }
            }

            return AlertDialog(
              title: const Text('TMDB / Bangumi 设置'),
              content: SizedBox(
                width: 490,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('TMDB 认证方式'),
                    const SizedBox(height: 10),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'token', label: Text('访问令牌')),
                        ButtonSegment(value: 'apiKey', label: Text('API Key')),
                      ],
                      selected: {mode},
                      onSelectionChanged: (chosen) => refresh(() {
                        mode = chosen.first;
                        result = null;
                      }),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      key: ValueKey(mode),
                      controller: controller,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: mode == 'token'
                            ? 'API Read Access Token'
                            : 'API Key',
                        helperText: '保存在系统安全存储；两种凭证分别保存，可随时切换',
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      '元数据来源仅使用 TMDB 和 Bangumi，后者的公开搜索不需要此凭证。',
                      style: TextStyle(fontSize: 12),
                    ),
                    if (result != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        result!,
                        style: Theme.of(dialogContext).textTheme.bodySmall,
                      ),
                    ],
                  ],
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
                      : const Icon(Icons.cloud_done_outlined),
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
      token.dispose();
      apiKey.dispose();
    }
  }
}
