import '../l10n/strings.dart';
import 'uniform_action_bar.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../core/catalog.dart';
import '../core/sources.dart';
import 'source_access_message.dart';

/// NipaPlay-style source editor. No explicit anonymous or password mode switch.
enum _SourceMessage {
  connected,
  localAccessible,
  testFailed,
  fieldsRequired,
  invalidSmb,
  invalidWebdav,
  guestCredentials,
  saveFailed,
}

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
    _SourceMessage? message;
    var problem = SourceAccessProblem.unknown;
    int itemCount = 0;

    String credentialPassword() {
      if (username.text.trim().isEmpty) return '';
      if (password.text.isNotEmpty) return password.text;
      if (clearPassword || username.text.trim() != previousUsername) return '';
      return original['password']?.toString() ?? '';
    }

    _SourceMessage? validateConnection() {
      if (!webdav) return null;
      if (username.text.trim().isEmpty && password.text.isNotEmpty) {
        return _SourceMessage.guestCredentials;
      }
      final url = location.text.trim();
      if (smb) {
        try {
          SmbSource.validateLocation(url);
        } on ArgumentError {
          return _SourceMessage.invalidSmb;
        }
      } else {
        final uri = Uri.tryParse(url);
        if (uri == null ||
            uri.host.isEmpty ||
            !(uri.isScheme('http') || uri.isScheme('https'))) {
          return _SourceMessage.invalidWebdav;
        }
      }
      return null;
    }

    Future<void> test(BuildContext dialogContext, StateSetter update) async {
      update(() {
        testing = true;
        message = null;
      });
      try {
        if (webdav) {
          final invalid = validateConnection();
          if (invalid != null) {
            message = invalid;
            return;
          }
          final dav = WebDav({
            'kind': source['kind'],
            'location': location.text.trim(),
            'username': username.text.trim(),
            'password': credentialPassword(),
          });
          final files = await dav
              .list(dav.root)
              .timeout(const Duration(seconds: 18));
          itemCount = files.length;
          message = _SourceMessage.connected;
        } else {
          await Directory(
            location.text.trim(),
          ).list(followLinks: false).take(1).drain<void>();
          message = _SourceMessage.localAccessible;
        }
      } catch (e) {
        problem = SourceAccessProblem.from(e);
        message = _SourceMessage.testFailed;
      } finally {
        if (dialogContext.mounted) update(() => testing = false);
      }
    }

    Future<void> save(BuildContext dialogContext, StateSetter update) async {
      final label = name.text.trim(),
          url = location.text.trim(),
          user = username.text.trim();
      if (label.isEmpty || url.isEmpty) {
        update(() => message = _SourceMessage.fieldsRequired);
        return;
      }
      final invalid = validateConnection();
      if (invalid != null) {
        update(() => message = invalid);
        return;
      }
      if (url != source['location']) {
        final proceed = await showDialog<bool>(
          context: dialogContext,
          builder: (ctx) => AlertDialog(
            title: Text(dialogContext.l10n.changeSourceTitle),
            content: Text(dialogContext.l10n.changeSourceBody),
            actions: [
              UniformActionBar(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(dialogContext.l10n.cancel),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(dialogContext.l10n.confirmChange),
                  ),
                ],
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
      } catch (_) {
        if (dialogContext.mounted) {
          update(() => message = _SourceMessage.saveFailed);
        }
      }
    }

    try {
      final route = DialogRoute<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, update) => AlertDialog(
            title: Text(dialogContext.l10n.editSource),
            content: SizedBox(
              width: 470,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: name,
                      decoration: InputDecoration(
                        labelText: dialogContext.l10n.sourceName,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: location,
                      readOnly: !webdav,
                      decoration: InputDecoration(
                        labelText: smb
                            ? dialogContext.l10n.smbUrl
                            : webdav
                            ? dialogContext.l10n.webdavUrl
                            : dialogContext.l10n.localFolder,
                      ),
                    ),
                    if (!webdav)
                      TextButton.icon(
                        onPressed: () async {
                          final selected = await FilePicker.getDirectoryPath(
                            dialogTitle: dialogContext.l10n.chooseMediaFolder,
                          );
                          if (selected != null && dialogContext.mounted) {
                            update(() => location.text = selected);
                          }
                        },
                        icon: const Icon(Icons.folder_open),
                        label: Text(dialogContext.l10n.chooseFolder),
                      ),
                    if (webdav) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: username,
                        decoration: InputDecoration(
                          labelText: dialogContext.l10n.usernameOptional,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: password,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: dialogContext.l10n.newPassword,
                          helperText: clearPassword
                              ? dialogContext.l10n.passwordWillClear
                              : dialogContext.l10n.keepPassword,
                          suffixIcon: IconButton(
                            icon: Icon(
                              clearPassword
                                  ? Icons.undo
                                  : Icons.backspace_outlined,
                            ),
                            tooltip: clearPassword
                                ? dialogContext.l10n.undoClearPassword
                                : dialogContext.l10n.clearSavedPassword,
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
                      Text(switch (message!) {
                        _SourceMessage.connected =>
                          dialogContext.l10n.sourceConnected(itemCount),
                        _SourceMessage.localAccessible =>
                          dialogContext.l10n.localAccessible,
                        _SourceMessage.testFailed => sourceAccessMessage(
                          dialogContext.l10n,
                          problem,
                        ),
                        _SourceMessage.fieldsRequired =>
                          dialogContext.l10n.sourceFieldsRequired,
                        _SourceMessage.invalidSmb =>
                          dialogContext.l10n.invalidSmb,
                        _SourceMessage.invalidWebdav =>
                          dialogContext.l10n.invalidWebdav,
                        _SourceMessage.guestCredentials =>
                          dialogContext.l10n.anonymousCredentials,
                        _SourceMessage.saveFailed =>
                          dialogContext.l10n.sourceSaveFailed,
                      }, style: Theme.of(dialogContext).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
            actions: [
              UniformActionBar(
                children: [
                  TextButton(
                    onPressed: testing
                        ? null
                        : () => Navigator.pop(dialogContext),
                    child: Text(dialogContext.l10n.cancel),
                  ),
                  OutlinedButton.icon(
                    icon: testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering),
                    onPressed: testing
                        ? null
                        : () => test(dialogContext, update),
                    label: Text(dialogContext.l10n.testConnection),
                  ),
                  FilledButton(
                    onPressed: testing
                        ? null
                        : () => save(dialogContext, update),
                    child: Text(dialogContext.l10n.save),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      await Navigator.of(context, rootNavigator: true).push<void>(route);
      await route.completed;
    } finally {
      name.dispose();
      location.dispose();
      username.dispose();
      password.dispose();
    }
  }
}
