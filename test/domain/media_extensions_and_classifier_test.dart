import 'package:flutter_test/flutter_test.dart';

import 'package:konata/domain/models/media_extensions.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/parsing/media_tech_parser.dart';
import 'package:konata/domain/playback/cue_variant_resolver.dart';
import 'package:konata/domain/playback/subtitle_and_audio_choices.dart';
import 'package:konata/domain/scraping/cloud_media_file_classifier.dart';
import 'package:konata/domain/scraping/personal_filename_parser.dart';
import 'package:konata/infrastructure/sources/directory_scanner.dart';
import 'package:konata/infrastructure/sources/subtitle_matcher.dart';
import 'package:konata/domain/repositories/file_system_gateway.dart';

class _InMemoryGateway implements MediaSourceGateway {
  _InMemoryGateway(this._entriesByDir);

  final Map<String, List<RemoteEntry>> _entriesByDir;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    return _entriesByDir[relativePath] ?? const [];
  }

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async => null;

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<void> close() async {}
}

void main() {
  group('KonataMediaExtensions 全站权威白名单与片源降噪标签', () {
    test('全量覆盖 1917~2026 片库全部视频/音频/外挂音轨/字幕扩展名且多处严格同源', () {
      const expectedVideos = [
        '.mkv',
        '.mp4',
        '.m2ts',
        '.ts',
        '.webm',
        '.avi',
        '.mov',
        '.m4v',
        '.flv',
        '.wmv',
        '.mpg',
        '.mpeg',
        '.vob',
        '.ogm',
        '.rmvb',
        '.iso',
      ];
      for (final ext in expectedVideos) {
        expect(KonataMediaExtensions.video.contains(ext), isTrue, reason: ext);
        expect(KonataMediaExtensions.isVideoFile('ep01$ext'), isTrue);
      }

      const expectedAudios = [
        '.flac',
        '.wav',
        '.alac',
        '.m4a',
        '.aac',
        '.opus',
        '.ogg',
        '.mp3',
        '.ac3',
        '.eac3',
        '.ec3',
        '.dts',
        '.dtshd',
        '.thd',
        '.ape',
        '.tak',
        '.tta',
        '.wv',
        '.dsf',
        '.dff',
        '.aiff',
        '.mka',
      ];
      for (final ext in expectedAudios) {
        expect(
          KonataMediaExtensions.playableAudio.contains(ext),
          isTrue,
          reason: ext,
        );
        expect(
          KonataMediaExtensions.scannableAudio.contains(ext),
          isTrue,
          reason: ext,
        );
        expect(
          KonataMediaExtensions.externalAudio.contains(ext),
          isTrue,
          reason: ext,
        );
        expect(CueVariantResolver.isPlayableAudioFile('track$ext'), isTrue);
      }
      expect(KonataMediaExtensions.scannableAudio.contains('.cue'), isTrue);
      expect(CueVariantResolver.isCueSheetFile('disc.cue'), isTrue);

      const expectedSubtitles = [
        '.ass',
        '.ssa',
        '.srt',
        '.vtt',
        '.sup',
        '.idx',
        '.sub',
      ];
      for (final ext in expectedSubtitles) {
        expect(KonataMediaExtensions.subtitle.contains(ext), isTrue, reason: ext);
        expect(SubtitleMatcher.isSubtitleFile('ep01$ext'), isTrue);
      }

      // 验证各模块全部直接复用权威集合引用
      expect(
        identical(
          SubtitleAndAudioChoices.subtitleExtensions,
          KonataMediaExtensions.subtitle,
        ),
        isTrue,
      );
      expect(
        identical(
          SubtitleAndAudioChoices.externalAudioExtensions,
          KonataMediaExtensions.externalAudio,
        ),
        isTrue,
      );
      expect(
        identical(
          SubtitleMatcher.supportedExtensions,
          KonataMediaExtensions.subtitle,
        ),
        isTrue,
      );
    });

    test('DirectoryScanner 正确扫描新增老番容器、无损音频与 VobSub 字幕', () async {
      final gw = _InMemoryGateway({
        '': const [
          RemoteEntry(
            name: 'ClassicShow',
            relativePath: 'ClassicShow',
            isDirectory: true,
          ),
        ],
        'ClassicShow': const [
          RemoteEntry(
            name: 'Classic 01 [LDRip][720x480].vob',
            relativePath: 'ClassicShow/Classic 01 [LDRip][720x480].vob',
            isDirectory: false,
          ),
          RemoteEntry(
            name: 'Classic 02 [HDTV].mpg',
            relativePath: 'ClassicShow/Classic 02 [HDTV].mpg',
            isDirectory: false,
          ),
          RemoteEntry(
            name: 'Classic 03.mov',
            relativePath: 'ClassicShow/Classic 03.mov',
            isDirectory: false,
          ),
          RemoteEntry(
            name: 'Classic 01.idx',
            relativePath: 'ClassicShow/Classic 01.idx',
            isDirectory: false,
          ),
          RemoteEntry(
            name: 'Classic 01.sub',
            relativePath: 'ClassicShow/Classic 01.sub',
            isDirectory: false,
          ),
          RemoteEntry(
            name: 'CDs',
            relativePath: 'ClassicShow/CDs',
            isDirectory: true,
          ),
        ],
        'ClassicShow/CDs': const [
          RemoteEntry(
            name: '01 Theme.wv',
            relativePath: 'ClassicShow/CDs/01 Theme.wv',
            isDirectory: false,
          ),
          RemoteEntry(
            name: '02 HiRes.dsf',
            relativePath: 'ClassicShow/CDs/02 HiRes.dsf',
            isDirectory: false,
          ),
          RemoteEntry(
            name: '03 Studio.dff',
            relativePath: 'ClassicShow/CDs/03 Studio.dff',
            isDirectory: false,
          ),
          RemoteEntry(
            name: '04 Master.aiff',
            relativePath: 'ClassicShow/CDs/04 Master.aiff',
            isDirectory: false,
          ),
        ],
      });

      final res = await const DirectoryScanner().scan(gw);
      final videos = res.files
          .where((f) => f.assetKind == AssetKind.video)
          .map((f) => f.fileName)
          .toList();
      final audios = res.files
          .where((f) => f.assetKind == AssetKind.cdAlbum)
          .map((f) => f.fileName)
          .toList();
      expect(
        videos,
        containsAll([
          'Classic 01 [LDRip][720x480].vob',
          'Classic 02 [HDTV].mpg',
          'Classic 03.mov',
        ]),
      );
      expect(
        audios,
        containsAll([
          '01 Theme.wv',
          '02 HiRes.dsf',
          '03 Studio.dff',
          '04 Master.aiff',
        ]),
      );
      final vobFile = res.files.firstWhere((f) => f.fileName.endsWith('.vob'));
      expect(
        vobFile.externalSubtitles,
        containsAll(['ClassicShow/Classic 01.idx', 'ClassicShow/Classic 01.sub']),
      );
    });

    test('SubtitleAndAudioChoices 发现同目录 .m4a / .eac3 / .ec3 / .thd / .dtshd 外挂音轨', () {
      const siblings = [
        'Movie.mkv',
        'Movie.jpn.m4a',
        'Movie.eng.eac3',
        'Movie.ec3',
        'Movie.atmos.thd',
        'Movie.jpn.dtshd',
      ];
      final discovered = SubtitleAndAudioChoices.findMatchingExternalAudioPaths(
        videoRelativePath: 'Movie.mkv',
        candidatePaths: siblings,
      );
      expect(
        discovered,
        containsAll([
          'Movie.jpn.m4a',
          'Movie.eng.eac3',
          'Movie.ec3',
          'Movie.atmos.thd',
          'Movie.jpn.dtshd',
        ]),
      );
    });

    test('CloudMediaFileClassifier 正确剥离 ldrip/hdtv/main12/alac/truehd/dtshd/yuv444p10 技术标签并识别新扩展名', () {
      const sample1 =
          '[Group] Neon Classic - 07 [LDRip 720x480 AC3].vob';
      const sample2 =
          '[Group] Modern Show - 12 [HDTV Main12 yuv444p10 ALAC].m4v';
      const sample3 =
          '[Group] Cinema Movie [2160p TrueHD DTSHD].mpg';
      expect(
        CloudMediaFileClassifier.stripTechnicalNoise(sample1),
        equals('[Group] Neon Classic - 07.vob'),
      );
      expect(
        CloudMediaFileClassifier.episodeNumberFromName(sample1),
        equals(7),
      );
      expect(
        CloudMediaFileClassifier.stripTechnicalNoise(sample2),
        equals('[Group] Modern Show - 12.m4v'),
      );
      expect(
        CloudMediaFileClassifier.episodeNumberFromName(sample2),
        equals(12),
      );
      expect(
        CloudMediaFileClassifier.stripTechnicalNoise(sample3),
        equals('[Group] Cinema Movie.mpg'),
      );
      expect(
        KonataMediaExtensions.sourceTags,
        containsAll(['bdrip', 'dvdrip', 'ldrip', 'tvrip', 'hdtv', 'webrip', 'web-dl']),
      );
      expect(
        MediaTechParser.parse(
          '[Group] Classic Show 01 [LDRip][720x480].ogm',
        ).mediaSourceTag,
        equals('LDRip'),
      );
      expect(
        PersonalFilenameParser.stripUnbracketedTechTokens(
          'Classic Show 01 LDRip 720p x264',
        ).toLowerCase(),
        isNot(contains('ldrip')),
      );
      expect(KonataMediaExtensions.isVideoFile('Disc1.iso'), isTrue);
      expect(
        KonataMediaExtensions.subtitleExtensionsNoDot,
        containsAll(['ass', 'ssa', 'srt', 'vtt', 'sup', 'idx', 'sub']),
      );
    });
  });
}
