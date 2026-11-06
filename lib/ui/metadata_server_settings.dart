import 'settings_navigation.dart';
import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'uniform_action_bar.dart';
import '../core/metadata_servers.dart';
import '../core/connection_diagnostic.dart';

class MetadataServerSettings extends StatefulWidget {
  const MetadataServerSettings({super.key, this.diagnostic});
  final Future<ConnectionReport> Function(int, List<String>, bool)? diagnostic;
  @override
  State<MetadataServerSettings> createState() => _MetadataServerSettingsState();
}

class _MetadataServerSettingsState extends State<MetadataServerSettings> {
  static final _recent = <String, ConnectionReport>{};
  final fields = [
    for (final value in MetadataServers.values)
      TextEditingController(text: value),
  ];
  final results = List<ConnectionReport?>.filled(4, null);
  final busy = List.filled(4, false);
  final scroll = ScrollController();
  bool fallback = MetadataServers.fallback,
      trust = MetadataServers.trustCustomTmdb;
  bool saveFailed = false;
  @override
  void initState() {
    super.initState();
    for (var i = 0; i < 4; i++) {
      results[i] = _recent['$i:${fields[i].text}:$trust'];
    }
  }

  @override
  void dispose() {
    for (final f in fields) {
      f.dispose();
    }
    scroll.dispose();
    super.dispose();
  }

  Future<void> test(int i) async {
    setState(() {
      busy[i] = true;
      results[i] = null;
    });
    final addresses = fields.map((e) => e.text).toList();
    final testedTrust = trust;
    ConnectionReport result;
    try {
      result =
          await (widget.diagnostic?.call(i, addresses, testedTrust) ??
              ConnectionDiagnostic.test(i, addresses, trust: testedTrust));
    } catch (e) {
      result = ConnectionReport(
        status: DiagnosticStatus.failed,
        issue: DiagnosticIssue.unknown,
        details: 'Diagnostic error (${e.runtimeType})',
      );
    }
    _recent['$i:${addresses[i]}:$testedTrust'] = result;
    if (mounted) {
      setState(() {
        busy[i] = false;
        results[i] = trust == testedTrust ? result : null;
      });
    }
  }

  Future<void> save() async {
    try {
      await MetadataServers.save(
        fields.map((e) => e.text).toList(),
        fallback,
        trust,
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => saveFailed = true);
    }
  }

  void preset(int provider, List<String> values) => setState(() {
    for (final i in [provider, provider + 1]) {
      fields[i].text = values[i];
      results[i] = null;
    }
  });

  String _issueLabel(DiagnosticIssue issue) => switch (issue) {
    DiagnosticIssue.none => context.l10n.serverConnected,
    DiagnosticIssue.credentials => context.l10n.diagnosticCredentials,
    DiagnosticIssue.authentication => context.l10n.diagnosticAuth,
    DiagnosticIssue.timeout => context.l10n.diagnosticTimeout,
    DiagnosticIssue.tls => context.l10n.diagnosticTls,
    DiagnosticIssue.network => context.l10n.diagnosticNetwork,
    DiagnosticIssue.invalid => context.l10n.diagnosticInvalid,
    DiagnosticIssue.http => context.l10n.diagnosticHttp,
    DiagnosticIssue.unknown => context.l10n.diagnosticFailed,
  };

  Widget serviceField(int i) {
    final scheme = Theme.of(context).colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: scheme.onSurface.withValues(alpha: .14)),
    );
    final report = results[i];
    final status = busy[i]
        ? context.l10n.testing
        : report == null
        ? context.l10n.notTested
        : switch (report.status) {
            DiagnosticStatus.connected => context.l10n.serverConnected,
            DiagnosticStatus.partial => context.l10n.connectionPartial,
            DiagnosticStatus.failed => _issueLabel(report.issue),
          };
    final detail = report != null && !busy[i];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          i.isEven ? context.l10n.apiAddress : context.l10n.imageAddress,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        TextField(
          key: ValueKey('metadata-address-$i'),
          controller: fields[i],
          enabled: !busy.any((e) => e),
          style: const TextStyle(fontSize: 15, height: 1.4),
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: (_) => setState(() => results[i] = null),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: scheme.onSurface.withValues(alpha: .025),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            border: border,
            enabledBorder: border,
            disabledBorder: border,
            focusedBorder: border.copyWith(
              borderSide: BorderSide(color: scheme.primary, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: ValueKey('metadata-test-$i'),
              onPressed: busy[i] ? null : () => test(i),
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.onSurface,
                side: BorderSide(
                  color: scheme.onSurface.withValues(alpha: .14),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
              icon: busy[i]
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check, size: 18),
              label: Text(
                i.isEven ? context.l10n.testApi : context.l10n.testImages,
              ),
            ),
            Text(
              status,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: scheme.onSurface.withValues(alpha: .65),
              ),
            ),
          ],
        ),
        if (detail) ...[
          const SizedBox(height: 10),
          Container(
            key: ValueKey('metadata-result-$i'),
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.onSurface.withValues(alpha: .035),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(top: 8),
              visualDensity: VisualDensity.compact,
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text(
                context.l10n.connectionDetails,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    '${_issueLabel(report.issue)}\n${report.details}',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: scheme.onSurface.withValues(alpha: .7),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget providerSection(int provider) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = busy.any((e) => e);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.onSurface.withValues(alpha: .12)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            provider == 0 ? 'TMDB' : 'Bangumi',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: disabled
                    ? null
                    : () => preset(provider, MetadataServers.defaults),
                child: Text(context.l10n.resetDefaults),
              ),
              TextButton(
                onPressed: disabled
                    ? null
                    : () => preset(provider, MetadataServers.official),
                child: Text(context.l10n.officialServers),
              ),
            ],
          ),
          const SizedBox(height: 14),
          serviceField(provider),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Divider(
              height: 1,
              color: scheme.onSurface.withValues(alpha: .1),
            ),
          ),
          serviceField(provider + 1),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = busy.any((e) => e);
    return SettingsSurface(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 800),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.scraping,
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.closeMetadata,
                    onPressed: disabled ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 22),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(
                  context,
                ).copyWith(scrollbars: false),
                child: Scrollbar(
                  controller: scroll,
                  thumbVisibility: true,
                  thickness: 4,
                  radius: const Radius.circular(4),
                  child: SingleChildScrollView(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(24, 8, 32, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.serverNotice,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.6,
                            color: scheme.onSurface.withValues(alpha: .65),
                          ),
                        ),
                        const SizedBox(height: 18),
                        providerSection(0),
                        const SizedBox(height: 16),
                        providerSection(2),
                        const SizedBox(height: 20),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            context.l10n.autoFallback,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            context.l10n.fallbackDescription,
                            style: TextStyle(fontSize: 13, height: 1.6),
                          ),
                          value: fallback,
                          onChanged: (v) => setState(() => fallback = v),
                        ),
                        const SizedBox(height: 10),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            context.l10n.allowCustomCredentials,
                            style: TextStyle(fontSize: 14, height: 1.5),
                          ),
                          value: trust,
                          onChanged: (v) => setState(() => trust = v ?? false),
                        ),
                        if (saveFailed)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              context.l10n.serverSaveFailed,
                              style: TextStyle(
                                fontSize: 13,
                                color: scheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: scheme.onSurface.withValues(alpha: .1)),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: UniformActionBar(
                children: [
                  TextButton(
                    onPressed: disabled ? null : () => Navigator.pop(context),
                    child: Text(context.l10n.cancel),
                  ),
                  FilledButton(
                    onPressed: disabled ? null : save,
                    child: Text(context.l10n.save),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
