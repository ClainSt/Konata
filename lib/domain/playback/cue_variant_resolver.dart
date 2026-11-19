import 'package:path/path.dart' as p;

import '../models/media_extensions.dart';
import '../models/media_variant.dart';
import 'cue_and_lrc_parser.dart';

/// CUE 虚拟分轨关联物理音频与同目录配对解析器，内外播放与详情过滤共用。
abstract final class CueVariantResolver {
  static final RegExp _genericDiscImageStemRegex = RegExp(
    r'^(?:cd[\s._-]*image|disc[\s._-]*image|album|image|disc[\s._-]*\d+|cd[\s._-]*\d+)$',
    caseSensitive: false,
  );

  /// 根据 CUE 分轨声明定位同目录下的目标物理音频变体。
  static MediaVariant? resolve({
    required MediaVariant cueVariant,
    required CueTrack cueTrack,
    required List<MediaVariant> audioVariantsInDir,
    required MediaVariant fallbackInitial,
  }) {
    final rawFileRef = cueTrack.fileName.trim();
    if (rawFileRef.isNotEmpty &&
        !CueTrack.isSafeRelativeFileReference(rawFileRef)) {
      return null;
    }
    final fileReference = rawFileRef.replaceAll('\\', '/');
    final declared = p.posix.basename(fileReference).toLowerCase();
    if (declared.isNotEmpty) {
      for (final candidate in audioVariantsInDir) {
        if (candidate.fileName.toLowerCase() == declared) {
          return candidate;
        }
      }
      final declaredStem = p.basenameWithoutExtension(declared);
      for (final candidate in audioVariantsInDir) {
        if (p.basenameWithoutExtension(candidate.fileName.toLowerCase()) ==
            declaredStem) {
          return candidate;
        }
      }
    }
    if (isPlayableAudioFile(fallbackInitial.fileName)) return fallbackInitial;
    if (audioVariantsInDir.length == 1) return audioVariantsInDir.first;
    // 多音频文件但 CUE 指向的文件缺失时，不能错误挑选首个文件。
    if (declared.isNotEmpty && audioVariantsInDir.isEmpty) {
      final dir = p.posix.dirname(
        cueVariant.relativePath.replaceAll('\\', '/'),
      );
      final rel = dir == '.'
          ? cueTrack.fileName.trim()
          : '$dir/${cueTrack.fileName.trim()}';
      return MediaVariant(
        id: '${cueVariant.id}::audio_file',
        workId: cueVariant.workId,
        sourceId: cueVariant.sourceId,
        relativePath: rel,
        fileName: p.posix.basename(declared),
        fileSize: 0,
        assetKind: cueVariant.assetKind,
      );
    }
    return null;
  }

  /// 在同目录候选 `.cue` 清单中为指定整轨物理音频匹配唯一归属的 `.cue` 变体。
  static MediaVariant? matchCueVariantForAudio({
    required MediaVariant audioVariant,
    required List<MediaVariant> cueVariantsInDir,
    required List<MediaVariant> audioVariantsInDir,
  }) {
    if (cueVariantsInDir.isEmpty) return null;
    final audioStem = p
        .basenameWithoutExtension(audioVariant.fileName)
        .trim()
        .toLowerCase();
    for (final cue in cueVariantsInDir) {
      final cueStem = p
          .basenameWithoutExtension(cue.fileName)
          .trim()
          .toLowerCase();
      if (cueStem == audioStem) return cue;
    }
    if (cueVariantsInDir.length == 1 && audioVariantsInDir.length == 1) {
      return cueVariantsInDir.first;
    }
    for (final cue in cueVariantsInDir) {
      final cueStem = p
          .basenameWithoutExtension(cue.fileName)
          .trim()
          .toLowerCase();
      if (cueStem.isEmpty) continue;
      if (audioStem.startsWith(cueStem) || cueStem.startsWith(audioStem)) {
        final ambiguous = audioVariantsInDir.any((other) {
          if (other.id == audioVariant.id) return false;
          final otherStem = p
              .basenameWithoutExtension(other.fileName)
              .trim()
              .toLowerCase();
          return otherStem.startsWith(cueStem) || cueStem.startsWith(otherStem);
        });
        if (!ambiguous) return cue;
      }
    }
    return null;
  }

  /// 判断文件名是否为 `.cue` 分轨清单文件。
  static bool isCueSheetFile(String name) =>
      KonataMediaExtensions.isCueSheetFile(name);

  /// 判断音频文件名词干是否属于无具体语义的泛化抓轨镜像名（如 `CDImage`）。
  static bool isGenericDiscImageStem(String stem) {
    return _genericDiscImageStemRegex.hasMatch(stem.trim());
  }

  /// 统一用于 CD 队列和 CUE 物理媒体匹配的音频扩展名（引用领域单一权威白名单）。
  static bool isPlayableAudioFile(String name) =>
      KonataMediaExtensions.isPlayableAudioFile(name);
}
