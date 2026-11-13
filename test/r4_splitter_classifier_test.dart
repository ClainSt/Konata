import 'package:ccplayer/core/cloud_media_file_classifier.dart';
import 'package:ccplayer/core/directory_analyzer.dart';
import 'package:ccplayer/core/multi_work_splitter.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _asset(
  String id,
  String relativePath, {
  int size = 500 * 1024 * 1024,
}) => {
  'id': id,
  'name': relativePath.split('/').last,
  'relative_path': relativePath,
  'size': size,
};

void main() {
  group('Rule 1: technical noise stripping & tightened OP/ED bounds', () {
    test('strips CRC32, tech brackets, and fps without breaking episodes', () {
      expect(
        CloudMediaFileClassifier.stripTechnicalNoise(
          '[SubGroup] Sample Show - 04 [BD 1920x1080 23.976fps AVC-yuv420p10 FLAC][D45080ED].mkv',
        ),
        '[SubGroup] Sample Show - 04.mkv',
      );
      expect(
        CloudMediaFileClassifier.stripTechnicalNoise(
          '[Moozzi2] Magic Kaito 1412 - 01 (BD 1080p) (89D91AED).mkv',
        ),
        '[Moozzi2] Magic Kaito 1412 - 01.mkv',
      );
      expect(
        CloudMediaFileClassifier.episodeNumberFromName(
          '[Moozzi2] Magic Kaito 1412 - 01 (BD 1080p).mkv',
        ),
        1,
      );
    });

    test('CRC32 hashes ending in ED never demote episodes to extra', () {
      const episodeFiles = [
        '[SubGroup] Crimson Chronicle - 01 [1080p][D45080ED].mkv',
        '[SubGroup] Crimson Chronicle - 02 [1080p][ed07016e].mkv',
        '[SubGroup] Crimson Chronicle - 03 [1080p][89D91AED].mkv',
        '[SubGroup] Crimson Chronicle - 04 [1080p][A91498ED].mkv',
        '[SubGroup] takt op.Destiny - 01 [1080p][ed07016e].mkv',
      ];

      for (final file in episodeFiles) {
        expect(
          CloudMediaFileClassifier.isOpEdExtra(file),
          isFalse,
          reason: file,
        );
        expect(
          CloudMediaFileClassifier.classifyAsset(
            'Crimson Chronicle',
            file,
            'video',
          ),
          'episode',
          reason: file,
        );
      }

      final inv = DirectoryAnalyzer.analyze('Crimson Chronicle', [
        for (final file in episodeFiles.take(4))
          (path: file, size: 700 * 1024 * 1024),
      ]);
      expect(inv.shape, WorkShape.series);
      expect(inv.episodes, {1, 2, 3, 4});
      expect(inv.extras, isEmpty);
    });

    test('real OP/ED extras remain extras under tightened bounds', () {
      const trueExtras = [
        '[SubGroup] Sample Show NCOP1 [1080p][D45080ED].mkv',
        '[SubGroup] Sample Show - ED2 [BD 1080p].mkv',
        '[SubGroup] Sample Show ノンクレジットED [1080p].mkv',
        '[SubGroup] Sample Show - OP01 (1080p).mkv',
        'MenuEX1.mkv',
      ];

      for (final file in trueExtras) {
        expect(
          CloudMediaFileClassifier.classifyAsset('Sample Show', file, 'video'),
          'extra',
          reason: file,
        );
      }
      expect(
        CloudMediaFileClassifier.isOpEdExtra('Sample Show NCOP1.mkv'),
        isTrue,
      );
      expect(
        CloudMediaFileClassifier.isOpEdExtra('Sample Show - ED2.mkv'),
        isTrue,
      );
      expect(
        CloudMediaFileClassifier.isOpEdExtra('Sample Show ノンクレジットED.mkv'),
        isTrue,
      );
      expect(
        CloudMediaFileClassifier.isOpEdExtra('Sample Show - ED.mkv'),
        isTrue,
      );
      expect(
        CloudMediaFileClassifier.isOpEdExtra('Sample Show - OP.mkv'),
        isTrue,
      );
    });

    test('standalone OVA with 1920x1080 and 23.976fps keeps episode null', () {
      const ova =
          'Mobile Suit Gundam SEED MSV - OVA ASTRAY BLUE FRAME 2006 [BD 1920x1080 23.976fps AVC-yuv420p10 FLAC].mkv';
      expect(CloudMediaFileClassifier.episodeNumberFromName(ova), isNull);

      final inv = DirectoryAnalyzer.analyze(
        'Mobile Suit Gundam SEED MSV OVA ASTRAY BLUE FRAME',
        const [(path: ova, size: 800 * 1024 * 1024)],
      );
      expect(inv.shape, WorkShape.feature);
      expect(inv.main, hasLength(1));
      expect(inv.main.single.episode, isNull);
      expect(inv.extras, isEmpty);
    });
  });

  group('Rule 2: contiguous integer main-sequence protection (2A)', () {
    test('protects contiguous 1..13 episodes with weak bracket/recap notes', () {
      final entries = <({String path, int? size})>[
        for (var ep = 1; ep <= 13; ep++)
          if (ep == 5)
            (
              path: '[Group] Starlight Idol - 05 [総集編] [1080p].mkv',
              size: 620 * 1024 * 1024,
            )
          else if (ep == 7)
            (
              path: '[Group] Starlight Idol - 07 [ Wug Ban Special ] [1080p].mkv',
              size: 640 * 1024 * 1024,
            )
          else if (ep == 9)
            (
              path: '[Group] Starlight Idol - 09 (Recap) [1080p].mkv',
              size: 610 * 1024 * 1024,
            )
          else
            (
              path:
                  '[Group] Starlight Idol - ${ep.toString().padLeft(2, '0')} [1080p].mkv',
              size: 630 * 1024 * 1024,
            ),
        (
          path: '[Group] Starlight Idol - NCOP1 [1080p].mkv',
          size: 80 * 1024 * 1024,
        ),
        (
          path: 'SPs/[Group] Starlight Idol - SP01 [1080p].mkv',
          size: 120 * 1024 * 1024,
        ),
      ];

      final inv = DirectoryAnalyzer.analyze('Starlight Idol', entries);
      expect(inv.shape, WorkShape.series);
      expect(inv.episodes, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13});
      expect(inv.extras, hasLength(2));
    });

    test('strong extra markers and SP subdirs stay extra even inside 1..N', () {
      final entries = <({String path, int? size})>[
        (path: 'Show - 01 [1080p].mkv', size: 600 * 1024 * 1024),
        (path: 'Show - 02 [1080p].mkv', size: 600 * 1024 * 1024),
        (path: 'Show - 03 [NCOP1] [1080p].mkv', size: 600 * 1024 * 1024),
        (path: 'Show - 04 [Menu] [1080p].mkv', size: 600 * 1024 * 1024),
        (path: 'Show - 05 [Preview] [1080p].mkv', size: 600 * 1024 * 1024),
        (path: 'SPs/Show - 06 [Special] [1080p].mkv', size: 600 * 1024 * 1024),
      ];

      final inv = DirectoryAnalyzer.analyze('Show', entries);
      expect(inv.episodes, {1, 2});
      expect(inv.extras, hasLength(4));

      // Standalone weak extra classification outside contiguous directory stays extra.
      expect(
        CloudMediaFileClassifier.classifyAsset(
          'Show',
          'Show - 12 Ending Special Ver (BDRip 1080p).mkv',
          'video',
        ),
        'extra',
      );
    });
  });

  group('Rule 3: pure special collection directory detection (12A)', () {
    test('detects container suffixes and maps title + season 0 for specials', () {
      for (final folder in const [
        '头文字D Extras',
        'Starlight Resonance Specials',
        'Starlight Resonance SPs',
        '星辰物语 特典',
        '星辰物语 Extra',
      ]) {
        final expectedBase = folder
            .replaceFirst(
              RegExp(r'\s+(?:Extras|Specials|SPs|特典|Extra)$'),
              '',
            )
            .trim();
        final inv = DirectoryAnalyzer.analyze(folder, const [
          (path: 'Special 01 [1080p][D45080ED].mkv', size: 300 * 1024 * 1024),
          (path: 'Special 02 [1080p][A91498ED].mkv', size: 320 * 1024 * 1024),
        ]);
        expect(inv.title, expectedBase, reason: folder);
        expect(inv.season, 0, reason: folder);
        expect(inv.shape, WorkShape.series, reason: folder);
        expect(inv.episodes, {1, 2}, reason: folder);
      }
    });

    test('does not strip proper-noun subtitle Extra Stage', () {
      final inv = DirectoryAnalyzer.analyze('头文字D Extra Stage', const [
        (
          path: '[Group] Initial D Extra Stage - 01 [1080p].mkv',
          size: 500 * 1024 * 1024,
        ),
        (
          path: '[Group] Initial D Extra Stage - 02 [1080p].mkv',
          size: 500 * 1024 * 1024,
        ),
      ]);
      expect(inv.title, '头文字D Extra Stage');
      expect(inv.season, isNull);
      expect(inv.titleHints.first, '头文字D Extra Stage');
    });
  });

  group('Rule 4a: greedy explicit pairing, hint isolation, extra matching', () {
    test('18A: greedily pairs fewer explicit folder segments among 5 clusters', () {
      final assets = [
        _asset('tv1-1', 'Alpha Chronicle - 01 [1080p].mkv'),
        _asset('tv1-2', 'Alpha Chronicle - 02 [1080p].mkv'),
        _asset('tv2-1', 'Beta Chronicle Reload - 01 [1080p].mkv'),
        _asset('tv2-2', 'Beta Chronicle Reload - 02 [1080p].mkv'),
        _asset('ova1', 'Alpha OVA Astray [OVA][1080p].mkv'),
        _asset('ova2', 'Beta OVA Zero [OVA][1080p].mkv'),
        _asset('ova3', 'Gamma Side Story [OVA][1080p].mkv'),
      ];

      final clusters = MultiWorkSplitter.split(
        'Beta Chronicle Reload & Alpha Chronicle',
        assets,
      );
      expect(clusters, hasLength(5));

      final byId = <String, SubWorkCluster>{
        for (final c in clusters)
          for (final a in c.assignments) a.assetId: c,
      };
      expect(byId['tv1-1']!.inventory.title, 'Alpha Chronicle');
      expect(byId['tv2-1']!.inventory.title, 'Beta Chronicle Reload');
      expect(byId['ova1']!.inventory.title, isNot('Beta Chronicle Reload'));
      expect(byId['ova1']!.inventory.title, isNot('Alpha Chronicle'));
      expect(byId['ova3']!.inventory.title, contains('Gamma'));
    });

    test('18B: isolates grandparent collection stem and keeps HD Remaster hints', () {
      final assets = [
        _asset(
          'hd-1',
          '[Group] Starlight Destiny HD Remaster - 01 [1080p].mkv',
        ),
        _asset(
          'hd-2',
          '[Group] Starlight Destiny HD Remaster - 02 [1080p].mkv',
        ),
        _asset('s1-1', '[Group] Starlight Original - 01 [HD重制版][1080p].mkv'),
        _asset('s1-2', '[Group] Starlight Original - 02 [HD重制版][1080p].mkv'),
      ];

      final clusters = MultiWorkSplitter.split(
        '星辰档案 作品集/星辰传说 Original & 星辰命运 Destiny',
        assets,
      );
      expect(clusters, hasLength(2));
      for (final c in clusters) {
        expect(c.inventory.titleHints, isNot(contains('星辰档案')));
      }
      final hdCluster = clusters.singleWhere(
        (c) => c.assignments.any((a) => a.assetId == 'hd-1'),
      );
      final cnHdCluster = clusters.singleWhere(
        (c) => c.assignments.any((a) => a.assetId == 's1-1'),
      );
      expect(
        hdCluster.inventory.titleHints.any((h) => h.contains('HD Remaster')),
        isTrue,
      );
      expect(
        cnHdCluster.inventory.titleHints.any((h) => h.contains('HD重制版')),
        isTrue,
      );
    });

    test('18B fallback: generic numeric files fall back to parent stem', () {
      final assets = [
        _asset('tv-1', '01.mkv'),
        _asset('tv-2', '02.mkv'),
        _asset('m-1', 'Movie/Special Movie Part [1080p].mkv'),
      ];

      final clusters = MultiWorkSplitter.split(
        '幻影旅团 作品集/TV+Movie',
        assets,
      );
      expect(clusters, hasLength(2));
      final genericTv = clusters.singleWhere(
        (c) => c.assignments.any((a) => a.assetId == 'tv-1'),
      );
      expect(genericTv.inventory.title, '幻影旅团');
      expect(genericTv.inventory.titleHints, contains('幻影旅团'));
    });

    test('18D: matches extras to longest specific work title cluster', () {
      final assets = [
        _asset('s1', 'Mobile Suit Gundam SEED - 01.mkv'),
        _asset('s2', 'Mobile Suit Gundam SEED - 02.mkv'),
        _asset('sd1', 'Mobile Suit Gundam SEED Destiny - 01.mkv'),
        _asset('sd2', 'Mobile Suit Gundam SEED Destiny - 02.mkv'),
        _asset('sg1', 'Mobile Suit Gundam SEED C.E.73 Stargazer [OVA].mkv'),
        _asset(
          'ex-seed',
          'SPs/Mobile Suit Gundam SEED NCOP1.mkv',
          size: 40 * 1024 * 1024,
        ),
        _asset(
          'ex-destiny',
          'SPs/Mobile Suit Gundam SEED Destiny NCOP1.mkv',
          size: 40 * 1024 * 1024,
        ),
        _asset(
          'ex-sg',
          'SPs/Mobile Suit Gundam SEED C.E.73 Stargazer ED.mkv',
          size: 35 * 1024 * 1024,
        ),
      ];

      final clusters = MultiWorkSplitter.split('高达SEED 合集', assets);
      expect(clusters, hasLength(3));
      final owners = <String, SubWorkCluster>{
        for (final c in clusters)
          for (final a in c.assignments) a.assetId: c,
      };
      expect(owners['ex-seed']!.slug, owners['s1']!.slug);
      expect(owners['ex-destiny']!.slug, owners['sd1']!.slug);
      expect(owners['ex-sg']!.slug, owners['sg1']!.slug);
    });
  });

  group('Rule 4b: mixed TV+Movie/OVA splitting & {tmdb-N} / #00 boundaries', () {
    test('4B: plain multi-season {tmdb-N} TV folder does NOT split', () {
      final assets = [
        _asset('s1e1', 'Season 1/Sample Series S01E01.mkv'),
        _asset('s1e2', 'Season 1/Sample Series S01E02.mkv'),
        _asset('s2e1', 'Season 2/Sample Series S02E01.mkv'),
        _asset('s2e2', 'Season 2/Sample Series S02E02.mkv'),
        _asset('sp1', 'SPs/Sample Series NCOP1.mkv', size: 40 * 1024 * 1024),
      ];

      expect(
        MultiWorkSplitter.split('示例番剧 {tmdb-54321}', assets),
        isEmpty,
      );
    });

    test('4B: {tmdb-N} TV folder splits detached theatrical films & clears tmdbId', () {
      final romanAssets = [
        _asset('tv1', 'Turn A Gundam - 01 [1080p].mkv'),
        _asset('tv2', 'Turn A Gundam - 02 [1080p].mkv'),
        _asset('tv3', 'Turn A Gundam - 03 [1080p].mkv'),
        _asset('m1', 'Turn A Gundam I Earth Light [1080p].mkv'),
        _asset('m2', 'Turn A Gundam II Moonlight Butterfly [1080p].mkv'),
      ];

      final romanClusters = MultiWorkSplitter.split(
        '倒A高达 {tmdb-19990}',
        romanAssets,
      );
      expect(romanClusters, hasLength(3));
      final tvCluster = romanClusters.singleWhere(
        (c) => c.assignments.any((a) => a.assetId == 'tv1'),
      );
      final m1Cluster = romanClusters.singleWhere(
        (c) => c.assignments.any((a) => a.assetId == 'm1'),
      );
      final m2Cluster = romanClusters.singleWhere(
        (c) => c.assignments.any((a) => a.assetId == 'm2'),
      );
      expect(tvCluster.inventory.tmdbId, 19990);
      expect(m1Cluster.inventory.tmdbId, isNull);
      expect(m2Cluster.inventory.tmdbId, isNull);
      expect(m1Cluster.inventory.movieMarker, isTrue);
      expect(m2Cluster.inventory.movieMarker, isTrue);
      expect(m1Cluster.inventory.fileHints, contains('Turn A Gundam'));

      // Movie.1.2017 / Movie.2.2018 inside Movies/ under {tmdb-N}
      final datedMovieAssets = [
        _asset('tv1', 'Blue Horizon - 01.mkv'),
        _asset('tv2', 'Blue Horizon - 02.mkv'),
        _asset('mv1', 'Movies/Blue.Horizon.Movie.1.2017.1080p.mkv'),
        _asset('mv2', 'Movies/Blue.Horizon.Movie.2.2018.1080p.mkv'),
      ];
      final datedClusters = MultiWorkSplitter.split(
        '蔚蓝地平线 {tmdb-77889}',
        datedMovieAssets,
      );
      expect(datedClusters, hasLength(3));
      final mainTv = datedClusters.singleWhere(
        (c) => c.assignments.any((a) => a.assetId == 'tv1'),
      );
      expect(mainTv.inventory.tmdbId, 77889);
      for (final m in datedClusters.where((c) => c != mainTv)) {
        expect(m.inventory.tmdbId, isNull);
        expect(m.inventory.movieMarker, isTrue);
      }
    });

    test('6A: TV+Movie splits [EX1]/[EX2], routes MenuEX1/MenuEX2, and splits Movie', () {
      final assets = [
        _asset('tv1', 'Accel Legend - 01 [1080p].mkv'),
        _asset('tv2', 'Accel Legend - 02 [1080p].mkv'),
        _asset('ex1', 'Accel Legend [EX1][1080p].mkv'),
        _asset('ex2', 'Accel Legend [EX2][1080p].mkv'),
        _asset('mv', 'Accel Legend Infinite Burst [1080p].mkv'),
        _asset('mex1', 'SPs/MenuEX1.mkv', size: 25 * 1024 * 1024),
        _asset('mex2', 'SPs/MenuEX2.mkv', size: 25 * 1024 * 1024),
      ];

      final clusters = MultiWorkSplitter.split('加速传说 TV+Movie', assets);
      expect(clusters, hasLength(4));

      final byAsset = <String, SubWorkCluster>{
        for (final c in clusters)
          for (final a in c.assignments) a.assetId: c,
      };
      expect(byAsset['ex1']!.slug, isNot(equals(byAsset['ex2']!.slug)));
      expect(byAsset['mex1']!.slug, byAsset['ex1']!.slug);
      expect(byAsset['mex2']!.slug, byAsset['ex2']!.slug);
      expect(byAsset['ex1']!.inventory.season, 0);
      expect(byAsset['ex2']!.inventory.season, 0);
      expect(byAsset['mv']!.inventory.movieMarker, isTrue);

      for (final c in clusters) {
        final mainEps = c.assignments
            .where((a) => a.category == 'main' && a.episode != null)
            .map((a) => a.episode!)
            .toList();
        expect(mainEps.toSet(), hasLength(mainEps.length));
      }
    });

    test('8A: splits standalone two-volume Alternative - 01 / - 02 without conflict', () {
      final assets = [
        _asset('alt1', '[Group] Horizon Alternative - 01 [BD 1080p].mkv'),
        _asset('alt2', '[Group] Horizon Alternative - 02 [BD 1080p].mkv'),
      ];

      final clusters = MultiWorkSplitter.split('地平线 Alternative', assets);
      expect(clusters, hasLength(2));
      for (final c in clusters) {
        expect(c.inventory.season, 0);
        expect(c.assignments, hasLength(1));
      }
      expect(
        clusters.map((c) => c.inventory.titleHints.join(' ')).join('|'),
        allOf(contains('ONE'), contains('TWO')),
      );

      // Season-tagged Alternative must stay unified (not split as two OVAs).
      final seasonalAssets = [
        _asset('s1', '[Group] Horizon Alternative Season 1 - 01.mkv'),
        _asset('s2', '[Group] Horizon Alternative Season 1 - 02.mkv'),
      ];
      expect(
        MultiWorkSplitter.split('地平线 Alternative', seasonalAssets),
        isEmpty,
      );
    });

    test('13A: splits #00 OVA with explicit subtitle while keeping plain #00 unified', () {
      final ovaAssets = [
        _asset('ep0', '[Group] Scarlet Knight #00 序章・前日談 [1080p].mkv'),
        _asset('ep1', '[Group] Scarlet Knight #01 [1080p].mkv'),
        _asset('ep2', '[Group] Scarlet Knight #02 [1080p].mkv'),
        _asset('ep3', '[Group] Scarlet Knight #03 [1080p].mkv'),
      ];

      final clusters = MultiWorkSplitter.split('绯红骑士 {tmdb-99112}', ovaAssets);
      expect(clusters, hasLength(2));

      final ep0Cluster = clusters.singleWhere(
        (c) => c.assignments.any((a) => a.assetId == 'ep0'),
      );
      final tvCluster = clusters.singleWhere(
        (c) => c.assignments.any((a) => a.assetId == 'ep1'),
      );
      expect(ep0Cluster.inventory.season, 0);
      expect(ep0Cluster.inventory.tmdbId, isNull);
      expect(tvCluster.inventory.tmdbId, 99112);
      expect(tvCluster.inventory.episodes, {1, 2, 3});

      // Plain #00 without subtitle must NOT split.
      final plainAssets = [
        _asset(
          'p0',
          '[AI-Raws] NIGHT HEAD 2041 #00 (BD HEVC 1920x1080 FLAC)[AFC9B2CA].mkv',
        ),
        _asset(
          'p1',
          '[AI-Raws] NIGHT HEAD 2041 #01 (BD HEVC 1920x1080 FLAC)[11112222].mkv',
        ),
        _asset(
          'p2',
          '[AI-Raws] NIGHT HEAD 2041 #02 (BD HEVC 1920x1080 FLAC)[33334444].mkv',
        ),
      ];
      expect(MultiWorkSplitter.split('NIGHT HEAD 2041', plainAssets), isEmpty);
    });

    test('generic arc suffixes (-hen/編/Stage) split multi-arc collections only', () {
      final arcAssets = [
        _asset('a1', 'Academy Arc 黎明編 - 01.mkv'),
        _asset('a2', 'Academy Arc 黎明編 - 02.mkv'),
        _asset('b1', 'Academy Arc 黄昏編 - 01.mkv'),
        _asset('b2', 'Academy Arc 黄昏編 - 02.mkv'),
      ];
      final arcClusters = MultiWorkSplitter.split('学园物语 黎明編 & 黄昏編', arcAssets);
      expect(arcClusters, hasLength(2));

      final stageAssets = [
        _asset('st1', 'Drift Legend Apex Stage.mkv'),
        _asset('st2', 'Drift Legend Apex Stage 2.mkv'),
      ];
      final stageClusters = MultiWorkSplitter.split('漂移传说 合集', stageAssets);
      expect(stageClusters, hasLength(2));

      // Per-episode subtitles ending in 編/篇 after episode numbers must NOT split.
      final singleSeriesWithEpSubtitles = [
        _asset('e1', 'Quest Series - 01 旅立ち編.mkv'),
        _asset('e2', 'Quest Series - 02 決戦編.mkv'),
        _asset('e3', 'Quest Series - 03 覚醒編.mkv'),
      ];
      expect(
        MultiWorkSplitter.split('冒险物语', singleSeriesWithEpSubtitles),
        isEmpty,
      );

      // Normal words like "Two" or "新章" are not hardcoded to season 2.
      expect(
        DirectoryAnalyzer.splitSeasonSuffix('Sample Story Two', isSeries: true)
            .season,
        isNull,
      );
      expect(
        DirectoryAnalyzer.splitSeasonSuffix('Sample Story 新章', isSeries: true)
            .season,
        isNull,
      );
    });
  });
}
