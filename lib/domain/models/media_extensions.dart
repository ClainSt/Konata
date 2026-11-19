/// 全站唯一权威媒体文件扩展名白名单、判定辅助与 MIME 映射表（Domain 层纯常量）。
///
/// 统一供 `DirectoryScanner`、`CloudMediaFileClassifier`、`SubtitleAndAudioChoices`、
/// `CueVariantResolver`、`SubtitleMatcher`、`LocalStreamBridge` 与界面文件浏览器复用，
/// 严禁在业务或表现层私写分散的扩展名集合。
abstract final class KonataMediaExtensions {
  /// 全站支持的视频容器扩展名（小写含点）。
  static const Set<String> video = {
    '.mkv',
    '.mp4',
    '.m2ts',
    '.ts',
    '.avi',
    '.webm',
    '.mov',
    '.m4v',
    '.flv',
    '.wmv',
    '.mpg',
    '.mpeg',
    '.vob',
  };

  /// 全站支持的可直接播放音频文件扩展名（不含 `.cue` 分轨清单）。
  static const Set<String> playableAudio = {
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
    '.aif',
    '.mka',
  };

  /// 目录扫描阶段纳入音频/CD 资产的扩展名集合（包含 `.cue` 分轨清单）。
  static const Set<String> scannableAudio = {
    '.cue',
    ...playableAudio,
  };

  /// 支持作为视频外挂音轨挂载的扩展名集合（传递给 `audio-files-append`）。
  static const Set<String> externalAudio = {
    '.mka',
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
    '.aif',
  };

  /// 全站支持的外挂字幕扩展名集合（覆盖文本字幕与 PGS / VobSub 位图字幕）。
  static const Set<String> subtitle = {
    '.ass',
    '.ssa',
    '.srt',
    '.vtt',
    '.sup',
    '.idx',
    '.sub',
  };

  /// 支持内存直注与文本编码归一的文本类外挂字幕扩展名集合。
  static const Set<String> textSubtitle = {
    '.ass',
    '.ssa',
    '.srt',
    '.vtt',
  };

  /// 扫图画集与封面支持的静态图片扩展名集合。
  static const Set<String> scanImage = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.bmp',
    '.avif',
  };

  /// 由 [video] 权威集合派生出的视频扩展名正则分组（不含首点）。
  static final String videoExtensionAlternation = video
      .map((ext) => ext.substring(1))
      .join('|');

  /// 由 [video] 权威集合派生的视频末尾后缀正则模式（如 `\.(?:mkv|mp4|...)$`）。
  static final String videoExtensionSuffixPattern =
      r'\.(?:' '$videoExtensionAlternation' r')$';

  /// 匹配文件名末尾视频扩展名的大小写不敏感正则。
  static final RegExp trailingVideoExtensionRegex = RegExp(
    videoExtensionSuffixPattern,
    caseSensitive: false,
  );

  /// 提取小写文件扩展名（含点号，如 `.mkv`；无扩展名或以点开头隐藏文件返回空串）。
  static String extensionOf(String pathOrName) {
    final normalized = pathOrName.trim().replaceAll('\\', '/');
    final fileName = normalized.split('/').last;
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot).toLowerCase();
  }

  /// 是否为受支持的视频容器文件。
  static bool isVideoFile(String pathOrName) =>
      video.contains(extensionOf(pathOrName));

  /// 是否为 `.cue` 分轨清单文件。
  static bool isCueSheetFile(String pathOrName) =>
      extensionOf(pathOrName) == '.cue';

  /// 是否为可直接播放的音频文件（不含 `.cue`）。
  static bool isPlayableAudioFile(String pathOrName) =>
      playableAudio.contains(extensionOf(pathOrName));

  /// 是否为扫描阶段识别的音频或分轨清单文件。
  static bool isScannableAudioFile(String pathOrName) =>
      scannableAudio.contains(extensionOf(pathOrName));

  /// 是否为支持外挂挂载的独立音轨文件。
  static bool isExternalAudioFile(String pathOrName) =>
      externalAudio.contains(extensionOf(pathOrName));

  /// 是否为受支持的外挂字幕文件。
  static bool isSubtitleFile(String pathOrName) =>
      subtitle.contains(extensionOf(pathOrName));

  /// 是否为可文本解码重映射的文本外挂字幕文件。
  static bool isTextSubtitleFile(String pathOrName) =>
      textSubtitle.contains(extensionOf(pathOrName));

  /// 是否为受支持的扫图图片文件。
  static bool isScanImageFile(String pathOrName) =>
      scanImage.contains(extensionOf(pathOrName));

  /// 按文件名后缀推导回环流网桥与 HTTP 响应使用的标准 MIME 类型。
  static String mimeTypeFor(String pathOrName) {
    return switch (extensionOf(pathOrName)) {
      '.mkv' => 'video/x-matroska',
      '.mp4' || '.m4v' => 'video/mp4',
      '.mov' => 'video/quicktime',
      '.webm' => 'video/webm',
      '.avi' => 'video/x-msvideo',
      '.flv' => 'video/x-flv',
      '.wmv' => 'video/x-ms-wmv',
      '.mpg' || '.mpeg' || '.vob' => 'video/mpeg',
      '.ts' || '.m2ts' => 'video/mp2t',
      '.flac' => 'audio/flac',
      '.wav' => 'audio/wav',
      '.wv' => 'audio/x-wavpack',
      '.aiff' || '.aif' => 'audio/aiff',
      '.dsf' => 'audio/x-dsf',
      '.dff' => 'audio/x-dff',
      '.mp3' => 'audio/mpeg',
      '.m4a' || '.aac' || '.alac' => 'audio/mp4',
      '.ogg' || '.opus' => 'audio/ogg',
      '.mka' => 'audio/x-matroska',
      '.ac3' => 'audio/ac3',
      '.eac3' || '.ec3' => 'audio/eac3',
      '.dts' || '.dtshd' => 'audio/vnd.dts',
      '.thd' => 'audio/vnd.dolby.mlp',
      _ => 'application/octet-stream',
    };
  }
}
