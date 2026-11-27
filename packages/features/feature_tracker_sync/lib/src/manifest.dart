import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';

import 'data/bangumi_tracker_provider.dart';
import 'providers.dart';
import 'ui/settings_bangumi_sync_card.dart';

/// 第三方追番平台同步模块的声明式注册清单。
final FeatureManifest featureTrackerSyncManifest = FeatureManifest(
  id: 'feature_tracker_sync',
  displayName: '追番进度同步',
  wrapRuntime: (child) => Consumer(
    child: child as Widget,
    builder: (context, ref, child) {
      ref.watch(trackerSyncCoordinatorProvider);
      return child!;
    },
  ),
  settingsSections: <SettingsSectionContribution>[
    SettingsSectionContribution(
      id: 'bangumi_sync',
      title: '追踪记录',
      subtitle: 'Bangumi PAT 凭据与离线队列同步',
      iconKey: 'tracker',
      order: 40,
      viewBuilder: (_) => const SettingsBangumiSyncCard(),
    ),
  ],
  dataProviders: <DataProviderContribution>[
    ProgressTrackerProviderContribution(
      id: BangumiTrackerProvider.trackerKey,
      displayName: BangumiTrackerProvider.trackerDisplayName,
      priority: 100,
      provider: manifestBangumiTrackerProvider,
    ),
  ],
);
