import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';

import 'providers.dart';
import 'ui/sources_page.dart';

/// `feature_sources` 向宿主外壳注册的标准化扩展清单。
///
/// 挂载顶层「媒体源」主导航分区（`id: 'sources'`，排序权重 `20`）。
final FeatureManifest featureSourcesManifest = FeatureManifest(
  id: 'feature_sources',
  displayName: '媒体源',
  wrapRuntime: (child) => _SourcesRuntime(child: child as Widget),
  navSections: <NavSectionContribution>[
    NavSectionContribution(
      id: 'sources',
      label: '媒体源',
      iconKey: 'sources',
      order: 20,
      viewBuilder: (slotContext) => const SourcesPage(),
    ),
  ],
);

/// 独立管理媒体源后台巡检的启动与前台恢复触发。
final class _SourcesRuntime extends ConsumerStatefulWidget {
  const _SourcesRuntime({required this.child});

  final Widget child;

  @override
  ConsumerState<_SourcesRuntime> createState() => _SourcesRuntimeState();
}

final class _SourcesRuntimeState extends ConsumerState<_SourcesRuntime>
    with WidgetsBindingObserver {
  Timer? _startup;

  @override
  void initState() {
    super.initState();
    if (!ref
        .read(featureSourcesDependenciesProvider)
        .autoStartOngoingWorksSync) {
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    _startup = Timer(const Duration(seconds: 5), _check);
  }

  void _check() => unawaited(
    ref.read(sourceScrapeControllerProvider).runOngoingWorksAutoSyncIfDue(),
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  @override
  void dispose() {
    _startup?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
