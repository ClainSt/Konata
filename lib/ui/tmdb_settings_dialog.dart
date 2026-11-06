import '../l10n/strings.dart';
import 'uniform_action_bar.dart';
import 'tmdb_api_guide.dart';
import 'package:flutter/material.dart';
import 'settings_navigation.dart';
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
      await openSettingsScreen<void>(
        context,
        (dialogContext) => StatefulBuilder(
          builder: (dialogContext, refresh) {
            final scheme = Theme.of(dialogContext).colorScheme;
            final outline = scheme.onSurface.withValues(alpha: .14);
            final fieldBorder = OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: outline),
            );
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
                if (!auth.isConfigured) {
                  refresh(() {
                    result = 'missing';
                    testing = false;
                  });
                  return;
                }
                await Metadata.testTmdbCredentials(auth);
                result = 'success';
              } catch (_) {
                result = 'testFailed';
              }
              if (dialogContext.mounted) refresh(() => testing = false);
            }

            Future<void> save() async {
              final value = controller.text.trim();
              if (value.isEmpty) {
                refresh(() => result = 'missing');
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
              } catch (_) {
                if (dialogContext.mounted) refresh(() => result = 'saveFailed');
              }
            }

            return SettingsFormSurface(
              dialog: AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 12),
                contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                scrollable: true,
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        dialogContext.l10n.tmdbSettings,
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: dialogContext.l10n.closeTmdb,
                      onPressed: testing
                          ? null
                          : () => Navigator.pop(dialogContext),
                      icon: const Icon(Icons.close, size: 22),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: 490,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dialogContext.l10n.authMethod,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        style: ButtonStyle(
                          shape: WidgetStatePropertyAll(
                            RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          side: WidgetStatePropertyAll(
                            BorderSide(color: outline),
                          ),
                          backgroundColor: WidgetStateProperty.resolveWith(
                            (states) => states.contains(WidgetState.selected)
                                ? scheme.primary
                                : Colors.transparent,
                          ),
                          foregroundColor: WidgetStateProperty.resolveWith(
                            (states) => states.contains(WidgetState.selected)
                                ? scheme.onPrimary
                                : scheme.onSurface,
                          ),
                          textStyle: const WidgetStatePropertyAll(
                            TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        segments: [
                          ButtonSegment(
                            value: 'token',
                            label: Text(dialogContext.l10n.accessToken),
                          ),
                          ButtonSegment(
                            value: 'apiKey',
                            label: const Text('API Key'),
                          ),
                        ],
                        selected: {mode},
                        onSelectionChanged: (chosen) => refresh(() {
                          mode = chosen.first;
                          result = null;
                        }),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        key: ValueKey(mode),
                        controller: controller,
                        obscureText: true,
                        style: const TextStyle(fontSize: 16),
                        decoration: InputDecoration(
                          border: fieldBorder,
                          enabledBorder: fieldBorder,
                          focusedBorder: fieldBorder.copyWith(
                            borderSide: BorderSide(
                              color: scheme.primary,
                              width: 1.5,
                            ),
                          ),
                          helperMaxLines: 3,
                          helperStyle: TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: scheme.onSurface.withValues(alpha: .65),
                          ),
                          labelStyle: const TextStyle(fontSize: 16),
                          floatingLabelStyle: TextStyle(
                            color: scheme.onSurface.withValues(alpha: .7),
                          ),
                          labelText: mode == 'token'
                              ? 'API Read Access Token'
                              : 'API Key',
                          helperText: dialogContext.l10n.secureCredentials,
                          suffixIcon: IconButton(
                            key: const ValueKey('tmdb-api-help'),
                            tooltip: dialogContext.l10n.apiGuideTitle,
                            onPressed: () => TmdbApiGuide.show(dialogContext),
                            icon: const Icon(Icons.help_outline),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        dialogContext.l10n.metadataProviders,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.6,
                          color: scheme.onSurface.withValues(alpha: .6),
                        ),
                      ),
                      if (result != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          switch (result) {
                            'success' => dialogContext.l10n.connectionOk,
                            'missing' => dialogContext.l10n.enterCredentials,
                            'saveFailed' =>
                              dialogContext.l10n.credentialSaveFailed,
                            _ => dialogContext.l10n.credentialTestFailed,
                          },
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: scheme.onSurface,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  UniformActionBar(
                    children: [
                      TextButton(
                        style: TextButton.styleFrom(
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          foregroundColor: scheme.onSurface.withValues(
                            alpha: .65,
                          ),
                        ),
                        onPressed: testing
                            ? null
                            : () => Navigator.pop(dialogContext),
                        child: Text(dialogContext.l10n.cancel),
                      ),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          foregroundColor: scheme.onSurface,
                          side: BorderSide(color: outline),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 13,
                          ),
                        ),
                        onPressed: testing ? null : test,
                        icon: testing
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.cloud_done_outlined),
                        label: Text(dialogContext.l10n.testConnection),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          textStyle: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onPressed: testing ? null : save,
                        child: Text(dialogContext.l10n.save),
                      ),
                    ],
                  ),
                ],
              ),
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
