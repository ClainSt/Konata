import 'package:flutter_test/flutter_test.dart';

import 'package:konata/domain/lyrics/bangumi_track_enricher.dart';
import 'package:konata/domain/lyrics/lyric_offset_resolver.dart';
import 'package:konata/domain/lyrics/lyric_search_query.dart';

void main() {
  group('S4 三级时间轴偏移解析与路由归类', () {
    test('区分有线/扬声器/USB 与各类蓝牙输出设备', () {
      expect(
        LyricOffsetResolver.classifyAudioRoute(
          deviceName: 'Speakers (Realtek High Definition Audio)',
        ),
        LyricAudioRouteKind.wired,
      );
      expect(
        LyricOffsetResolver.classifyAudioRoute(
          deviceName: 'FiiO K7 USB DAC',
          deviceFingerprint: 'usb:2972:0047',
        ),
        LyricAudioRouteKind.wired,
      );
      expect(
        LyricOffsetResolver.classifyAudioRoute(deviceName: '', deviceFingerprint: ''),
        LyricAudioRouteKind.wired,
      );

      for (final bt in const [
        'AirPods Pro (A2DP)',
        'Sony WH-1000XM5 Stereo',
        'WF-1000XM4 Bluetooth Audio',
        'HUAWEI FreeBuds Pro 3',
        'Bluetooth Hands-Free Audio',
        'bt_a2dp_sink',
      ]) {
        expect(
          LyricOffsetResolver.classifyAudioRoute(deviceName: bt),
          LyricAudioRouteKind.bluetooth,
          reason: '设备 "$bt" 应识别为蓝牙音频路由',
        );
      }
      expect(
        LyricOffsetResolver.classifyAudioRoute(
          deviceName: 'Headphones',
          deviceFingerprint: 'android:a2dp:aa:bb',
        ),
        LyricAudioRouteKind.bluetooth,
      );
    });

    test('三级偏移精确叠加、正值提前语义与安全边界钳制', () {
      const snap = LyricOffsetSnapshot(
        trackOffsetMillis: 200,
        albumOffsetMillis: -500,
        routeOffsetMillis: 300,
        activeRouteKind: LyricAudioRouteKind.bluetooth,
        userOffsetLocked: true,
      );
      expect(snap.totalOffsetMillis, 0);
      expect(snap.totalOffsetSeconds, 0.0);

      final shifted = snap.copyWith(trackOffsetMillis: 600);
      expect(shifted.totalOffsetMillis, 400);
      expect(shifted.totalOffsetSeconds, closeTo(0.4, 1e-6));

      expect(LyricOffsetSnapshot.clampTrackOrAlbum(99999), 15000);
      expect(LyricOffsetSnapshot.clampTrackOrAlbum(-99999), -15000);
      expect(LyricOffsetSnapshot.clampRoute(9000), 5000);
      expect(LyricOffsetSnapshot.clampRoute(-9000), -5000);

      expect(LyricOffsetResolver.formatOffsetSeconds(0), '0.0s');
      expect(LyricOffsetResolver.formatOffsetSeconds(300), '+0.3s');
      expect(LyricOffsetResolver.formatOffsetSeconds(-500), '-0.5s');
      expect(LyricOffsetResolver.formatOffsetSeconds(250), '+0.25s');
    });
  });

  group('S4 Bangumi 音乐曲目身份补全与别名注入', () {
    const tracks = <BangumiMusicTrack>[
      BangumiMusicTrack(
        subjectId: 400001,
        subjectTitle: '結束バンド',
        subjectTitleCn: '团结乐队',
        relation: '原声集',
        trackNumber: 1,
        title: '青春コンプレックス',
        titleCn: '青春情结',
      ),
      BangumiMusicTrack(
        subjectId: 400001,
        subjectTitle: '結束バンド',
        subjectTitleCn: '团结乐队',
        relation: '原声集',
        trackNumber: 2,
        title: 'ひとりぼっち東京',
        titleCn: '孤独东京',
      ),
      BangumiMusicTrack(
        subjectId: 400002,
        subjectTitle: 'Distortion!!',
        relation: '片尾曲',
        trackNumber: 1,
        title: 'Distortion!!',
      ),
    ];

    test('准确识别弱占位曲名且不误伤真实曲名', () {
      for (final weak in const [
        'Track 01',
        '01',
        '02.flac',
        'CD1-03',
        'M04',
        'Audio Track 12',
      ]) {
        expect(
          BangumiTrackEnricher.isWeakTrackTitle(weak),
          isTrue,
          reason: '"$weak" 应判为弱文件名',
        );
      }
      for (final real in const ['青春コンプレックス', 'unravel', '1999', 'Aimer - 残響散歌']) {
        expect(
          BangumiTrackEnricher.isWeakTrackTitle(real),
          isFalse,
          reason: '"$real" 不应判为弱文件名',
        );
      }
    });

    test('多张关联专辑下依据专辑名 + 轨号安全恢复 Track 01 真实日文原名', () {
      final res = BangumiTrackEnricher.enrich(
        title: 'Track 01',
        album: '結束バンド',
        trackNumber: 1,
        musicTracks: tracks,
      );
      expect(res.hasEnhancement, isTrue);
      expect(res.recoveredTitle, '青春コンプレックス');
      expect(res.extraTitleAliases, containsAll(['青春コンプレックス', '青春情结']));

      // 另一张单曲的 Track 01 匹配各自条目，不串台。
      final resEd = BangumiTrackEnricher.enrich(
        title: '01',
        album: 'Distortion!!',
        trackNumber: 1,
        musicTracks: tracks,
      );
      expect(resEd.recoveredTitle, 'Distortion!!');

      // 缺少专辑名且关联了多张不同音乐条目时拒绝臆猜恢复。
      final ambiguous = BangumiTrackEnricher.enrich(
        title: 'Track 01',
        album: '',
        trackNumber: 1,
        musicTracks: tracks,
      );
      expect(ambiguous.hasEnhancement, isFalse);
    });

    test('单张关联单曲条目允许仅凭轨号恢复，且中文译名曲目可注入日文原名别名参与搜索', () {
      final singleAlbumTracks = tracks.where((t) => t.subjectId == 400001).toList();
      final recovered = BangumiTrackEnricher.enrich(
        title: 'Track 02',
        trackNumber: 2,
        musicTracks: singleAlbumTracks,
      );
      expect(recovered.recoveredTitle, 'ひとりぼっち東京');

      final aliasEnrich = BangumiTrackEnricher.enrich(
        title: '青春情结',
        trackNumber: 1,
        musicTracks: tracks,
      );
      expect(aliasEnrich.recoveredTitle, isNull);
      expect(aliasEnrich.extraTitleAliases, contains('青春コンプレックス'));

      final query = LyricSearchQuery(
        title: '青春情结',
        artist: '結束バンド',
        extraTitleAliases: aliasEnrich.extraTitleAliases,
      );
      expect(query.titleAliases, contains('青春コンプレックス'));
      expect(
        query.buildSearchKeywords().any((kw) => kw.contains('青春コンプレックス')),
        isTrue,
      );
    });
  });
}
