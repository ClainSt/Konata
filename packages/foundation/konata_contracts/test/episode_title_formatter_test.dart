import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:test/test.dart';

final class _MemoryAssetLoader implements AssetDataLoaderPort {
  _MemoryAssetLoader(this._files);

  final Map<String, Uint8List> _files;

  @override
  Future<Uint8List?> loadBytes(String assetPath) async => _files[assetPath];
}

void main() {
  group('AssetDataLoaderPort 契约测试', () {
    test('按逻辑路径返回只读字节并在缺失时返回 null', () async {
      final loader = _MemoryAssetLoader(<String, Uint8List>{
        'assets/data/sample.bin.gz': Uint8List.fromList(<int>[1, 2, 3]),
      });
      expect(
        await loader.loadBytes('assets/data/sample.bin.gz'),
        equals(Uint8List.fromList(<int>[1, 2, 3])),
      );
      expect(await loader.loadBytes('assets/data/missing.bin.gz'), isNull);
    });
  });

  group('EpisodeTitleFormatter 唯一公共实现测试', () {
    test('单集、合并区间、多季前缀与剧场版规则保持一致', () {
      const rangeEp = EpisodeSummaryView(
        id: EpisodeId.trusted('e1'),
        workId: WorkId.trusted('w1'),
        seasonNumber: 1,
        category: EpisodeCategory.main,
        episodeNumber: 1,
        episodeNumberEnd: 2,
        title: '序章 / 启程',
      );
      expect(
        EpisodeTitleFormatter.formatCardTitle(
          episode: rangeEp,
          mainEpisodeCount: 12,
        ),
        '01-02 · 序章 / 启程',
      );
      expect(
        EpisodeTitleFormatter.formatCardTitle(
          episode: rangeEp,
          mainEpisodeCount: 12,
          showSeasonPrefix: true,
        ),
        'S1E01-02 · 序章 / 启程',
      );
      expect(
        EpisodeTitleFormatter.formatPlayerMediaTitle(
          workTitle: '葬送的芙莉莲',
          workMediaType: TmdbMediaType.tv,
          episode: rangeEp,
          mainEpisodeCount: 12,
        ),
        '葬送的芙莉莲 - 01-02 · 序章 / 启程',
      );
      expect(
        EpisodeTitleFormatter.isGenericEpisodePlaceholder('第 01 话'),
        isTrue,
      );
      expect(
        EpisodeTitleFormatter.isGenericEpisodePlaceholder('冒险的终点'),
        isFalse,
      );
    });

    test('历史快照中已格式化的集号及合并区间不重复拼接', () {
      for (final title in ['01 · 序章', '01-02 · 序章']) {
        expect(
          EpisodeTitleFormatter.formatHistorySubtitleFields(
            episodeTitle: title,
            isAudioRecord: false,
            seasonNumber: 1,
            episodeNumber: 1,
          ),
          title,
        );
      }
      expect(
        EpisodeTitleFormatter.formatHistorySubtitleFields(
          episodeTitle: '02 · 不同编号的标题',
          isAudioRecord: false,
          seasonNumber: 1,
          episodeNumber: 1,
        ),
        '01 · 02 · 不同编号的标题',
      );
    });

    test('播放记录副标题正确清洗音频前缀并保留特典标签', () {
      expect(
        EpisodeTitleFormatter.formatHistorySubtitleFields(
          episodeTitle: '01. 勇者.flac',
          isAudioRecord: true,
          seasonNumber: 0,
        ),
        '勇者',
      );
      expect(
        EpisodeTitleFormatter.formatHistorySubtitleFields(
          episodeTitle: '第 01 话',
          isAudioRecord: false,
          seasonNumber: 0,
          episodeNumber: 2,
        ),
        'SP02',
      );
    });
  });
}
