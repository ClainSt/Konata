import 'dart:async';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:test/test.dart';

/// 测试用内存同步事务上下文。
final class _FakeSyncTx implements SyncTransactionContext {
  _FakeSyncTx(this.localDeviceId, this.appliedAtMs);

  @override
  final String localDeviceId;

  @override
  final int appliedAtMs;

  final List<String> appliedIds = <String>[];

  @override
  Object? rawHandleFor(String databaseName) => appliedIds;
}

/// 测试用切片贡献者，校验导出、纯函数合并预览与事务落地契约。
final class _FakeSliceContributor
    implements SyncSliceContributor<List<String>> {
  @override
  String get sliceId => 'test_slice';

  @override
  String get displayName => '测试切片';

  @override
  int get schemaVersion => 1;

  @override
  Future<SyncSlicePayload> exportSlice({required String localDeviceId}) async {
    return SyncSlicePayload(
      sliceId: sliceId,
      schemaVersion: schemaVersion,
      exportedAtMs: 1000,
      sourceDeviceId: localDeviceId,
      data: const <String, Object?>{'items': <String>['a']},
    );
  }

  @override
  SyncMergePlan<List<String>> planMerge({
    required SyncSlicePayload local,
    required SyncSlicePayload remote,
  }) {
    final localItems = (local.data['items'] as List<Object?>? ?? const [])
        .cast<String>()
        .toSet();
    final remoteItems = (remote.data['items'] as List<Object?>? ?? const [])
        .cast<String>()
        .toSet();
    final toInsert = remoteItems.difference(localItems).toList()..sort();
    return SyncMergePlan<List<String>>(
      sliceId: sliceId,
      insertCount: toInsert.length,
      updateCount: 0,
      deleteCount: 0,
      skippedCount: remoteItems.intersection(localItems).length,
      planData: toInsert,
      summaryLines: <String>['新增 ${toInsert.length} 条记录'],
    );
  }

  @override
  Future<void> applyMergePlan(
    SyncTransactionContext tx,
    SyncMergePlan<List<String>> plan,
  ) async {
    final target = tx.rawHandleFor('user_state') as List<String>?;
    target?.addAll(plan.planData);
  }
}

/// 测试用第三方追番提供者实现。
final class _FakeTrackerProvider implements ProgressTrackerProvider {
  @override
  String get trackerId => 'bangumi';

  @override
  String get displayName => 'Bangumi 番组计划';

  @override
  Future<bool> isConfigured() async => true;

  @override
  Future<TrackerSyncResult> pushProgress(TrackerProgressPayload payload) async {
    return TrackerSyncResult.succeeded(
      remoteSummary: '${payload.trackerId}:${payload.externalSubjectId}',
    );
  }
}

void main() {
  group('强类型 ID 值对象', () {
    test('自动裁剪空白并拒绝空标识符', () {
      expect(WorkId('  w-001  ').value, 'w-001');
      expect(EpisodeId('ep-1').value, 'ep-1');
      expect(SourceId('src-1').value, 'src-1');
      expect(SeriesGroupId('ser-1').value, 'ser-1');
      expect(VariantId('var-1').value, 'var-1');

      expect(() => WorkId(''), throwsArgumentError);
      expect(() => EpisodeId('   '), throwsArgumentError);
      expect(() => SourceId('\t'), throwsArgumentError);
      expect(() => SeriesGroupId(''), throwsArgumentError);
      expect(() => VariantId(' '), throwsArgumentError);
    });
  });

  group('ArtworkRef 远程与本机自定义序列化规则', () {
    test('远程艺术图保留来源、路径与锁定态并参与跨设备同步', () {
      const ref = ArtworkRef.remote(
        source: ArtworkSource.fanart,
        uri: 'https://assets.fanart.tv/logo.png',
        locked: true,
      );

      final syncJson = ref.toSyncJson();
      expect(syncJson, isNotNull);
      expect(syncJson!['kind'], 'remote');
      expect(syncJson['source'], 'fanart');
      expect(syncJson['locked'], isTrue);

      final restored = ArtworkRef.tryFromJson(syncJson);
      expect(restored, equals(ref));
    });

    test('本机自定义图片仅本地保留路径，同步载荷返回 null 绝不泄漏本机路径', () {
      const ref = ArtworkRef.localCustom(
        localPath: r'D:\Anime-Projects\Konata\photos\custom.png',
      );

      expect(ref.locked, isTrue);
      expect(ref.toSyncJson(), isNull);

      final localJson = ref.toLocalJson();
      expect(localJson['kind'], 'localCustom');
      expect(ArtworkRef.tryFromJson(localJson), equals(ref));
    });

    test('非法 JSON 还原安全返回 null', () {
      expect(ArtworkRef.tryFromJson(null), isNull);
      expect(ArtworkRef.tryFromJson(<String, Object?>{'kind': 'unknown'}), isNull);
      expect(
        ArtworkRef.tryFromJson(<String, Object?>{
          'kind': 'remote',
          'source': 'invalid',
          'uri': '/a.jpg',
        }),
        isNull,
      );
    });
  });

  group('KonataLaneConfig 车道隔离规则', () {
    test('主干车道不追加目录前缀，隔离车道自动规范化', () {
      expect(KonataLaneConfig.resolveLane(''), '');
      expect(KonataLaneConfig.resolveLane('main'), '');
      expect(KonataLaneConfig.isolatedDirectoryName('main'), isNull);
      expect(KonataLaneConfig.resolveDesktopWindowTitle(rawOverride: ''), 'Konata');

      expect(KonataLaneConfig.resolveLane('Next_1'), 'next_1');
      expect(KonataLaneConfig.isolatedDirectoryName('next'), 'Konata_next');
      expect(
        KonataLaneConfig.resolveDesktopWindowTitle(rawOverride: 'next'),
        'Konata [NEXT]',
      );
      expect(
        KonataLaneConfig.resolveAndroidLauncherLabel(rawOverride: 'maint'),
        'Konata (MAINT)',
      );
      expect(() => KonataLaneConfig.resolveLane('1bad'), throwsArgumentError);
    });
  });

  group('DomainEventBus 低频事件广播', () {
    test('按子类型过滤订阅并在释放后静默忽略发布', () async {
      final bus = InMemoryDomainEventBus();
      final workEvents = <LibraryWorkChangedEvent>[];
      final sub = bus.on<LibraryWorkChangedEvent>().listen(workEvents.add);

      bus.publish(
        MediaSourceChangedEvent(
          sourceId: SourceId('src-1'),
          reason: 'scanned',
          occurredAtMs: 10,
        ),
      );
      bus.publish(
        LibraryWorkChangedEvent(
          workId: WorkId('w-1'),
          reason: 'scraped',
          occurredAtMs: 20,
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(workEvents, hasLength(1));
      expect(workEvents.single.workId.value, 'w-1');

      await sub.cancel();
      await bus.dispose();
      // 释放后再次发布不得抛出异常。
      bus.publish(
        LibraryWorkChangedEvent(
          workId: WorkId('w-2'),
          reason: 'deleted',
          occurredAtMs: 30,
        ),
      );
    });
  });

  group('DiagnosticTextSanitizer 脱敏能力', () {
    test('脱敏 URL 密码、Bearer 令牌、查询密钥与本机用户名目录', () {
      const raw =
          r'请求失败 https://alice:secret123@dav.example.com/anime?api_key=abc999 '
          r'Authorization: Bearer tok_xyz123 C:\Users\ClainSt\Desktop\log.txt';
      final clean = DiagnosticTextSanitizer.redactForExport(raw);

      expect(clean, isNot(contains('secret123')));
      expect(clean, isNot(contains('abc999')));
      expect(clean, isNot(contains('tok_xyz123')));
      expect(clean, isNot(contains('ClainSt')));
      expect(clean, contains('<USER_HOME>'));
      expect(DiagnosticTextSanitizer.isSensitiveKey('webdav_password'), isTrue);
      expect(DiagnosticTextSanitizer.isSensitiveKey('workId'), isFalse);
    });
  });

  group('7 大声明式扩展点与 FeatureManifest 平台过滤', () {
    test('平台过滤与 SyncSliceContributor 合并契约运转正常', () async {
      final slice = _FakeSliceContributor();
      final tracker = _FakeTrackerProvider();

      final manifest = FeatureManifest(
        id: 'feature_demo',
        displayName: '演示模块',
        settingsSections: <SettingsSectionContribution>[
          SettingsSectionContribution(
            id: 'external_tools',
            title: '外置播放器',
            iconKey: 'external_player',
            order: 40,
            supportedPlatforms: const <KonataPlatform>{KonataPlatform.windows},
            viewBuilder: (_) => 'desktop_panel',
          ),
        ],
        playerSidePanels: <PlayerSidePanelContribution>[
          PlayerSidePanelContribution(
            id: 'lyrics_offset',
            label: '歌词校准',
            iconKey: 'lyrics',
            order: 20,
            supportedModes: const <PlayerMediaMode>{PlayerMediaMode.audio},
            viewBuilder: (_) => 'lyrics_panel',
          ),
        ],
        dataProviders: <DataProviderContribution>[
          ProgressTrackerProviderContribution(
            id: 'tracker_bangumi',
            displayName: 'Bangumi',
            priority: 10,
            provider: tracker,
          ),
        ],
        syncSlices: <SyncSliceContributor<Object?>>[slice],
      );

      final desktopOnly = manifest.settingsSections.single;
      expect(desktopOnly.isSupportedOn(KonataPlatform.windows), isTrue);
      expect(desktopOnly.isSupportedOn(KonataPlatform.androidPhone), isFalse);

      final audioPanel = manifest.playerSidePanels.single;
      expect(
        audioPanel.isSupportedOn(
          KonataPlatform.androidTablet,
          PlayerMediaMode.audio,
        ),
        isTrue,
      );
      expect(
        audioPanel.isSupportedOn(
          KonataPlatform.windows,
          PlayerMediaMode.video,
        ),
        isFalse,
      );

      final local = await slice.exportSlice(localDeviceId: 'dev-a');
      const remote = SyncSlicePayload(
        sliceId: 'test_slice',
        schemaVersion: 1,
        exportedAtMs: 2000,
        sourceDeviceId: 'dev-b',
        data: <String, Object?>{'items': <String>['a', 'b', 'c']},
      );
      final plan = slice.planMerge(local: local, remote: remote);
      expect(plan.hasChanges, isTrue);
      expect(plan.insertCount, 2);
      expect(plan.skippedCount, 1);

      final tx = _FakeSyncTx('dev-a', 3000);
      await slice.applyMergePlan(tx, plan);
      expect(tx.appliedIds, equals(<String>['b', 'c']));

      final pushRes = await tracker.pushProgress(
        const TrackerProgressPayload(
          trackerId: 'bangumi',
          externalSubjectId: '12345',
          seasonNumber: 1,
          episodeNumber: 3,
          completed: true,
        ),
      );
      expect(pushRes.success, isTrue);
    });
  });
}
