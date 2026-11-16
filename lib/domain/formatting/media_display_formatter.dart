import '../parsing/title_normalizer.dart';

/// 跨层共用的纯领域展示格式化工具（字节大小、扩展名、分钟级时间及 BDRip 长文件名折行处理）。
abstract final class MediaDisplayFormatter {
  static final RegExp _hanziPattern = RegExp(r'[\u4E00-\u9FFF]');

  /// 判断详情页主标题下方是否需要展示原始语言副标题。
  ///
  /// 当主标题已包含有效中文译名（含汉字且不含日文假名）时隐藏重复日文原名；
  /// 仅在主标题无中文译名（如英文或日文原名）且与 [originalTitle] 不同时返回 `true`。
  static bool shouldShowOriginalSubtitle({
    required String title,
    required String? originalTitle,
  }) {
    final trimmedTitle = title.trim();
    final trimmedOrig = originalTitle?.trim() ?? '';
    if (trimmedOrig.isEmpty || trimmedOrig == trimmedTitle) {
      return false;
    }
    final hasChineseTitle =
        _hanziPattern.hasMatch(trimmedTitle) &&
        !TitleNormalizer.containsKana(trimmedTitle);
    return !hasChineseTitle;
  }

  /// 将字节数格式化为人类可读体积文本；当 [bytes] 为空或非正数时返回 [emptyFallback]。
  static String formatBytes(int? bytes, {String emptyFallback = ''}) {
    if (bytes == null || bytes <= 0) return emptyFallback;
    const kb = 1024.0;
    const mb = kb * 1024.0;
    const gb = mb * 1024.0;
    const tb = gb * 1024.0;
    if (bytes >= tb) return '${(bytes / tb).toStringAsFixed(2)} TB';
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  /// 提取文件大写扩展名（无有效扩展名时返回空字符串）。
  static String fileExtensionUpper(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot >= fileName.length - 1) return '';
    return fileName.substring(dot + 1).toUpperCase();
  }

  /// 将日期时间格式化为 `YYYY-MM-DD HH:mm`。
  static String formatDateTimeMinute(DateTime dt) {
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}-$m-$d $hh:$mm';
  }

  /// 在密集括号、下划线与点分隔符后插入零宽空格，防止 BDRip 长命名提前整行截断。
  static String formatWrappableFileName(String raw) {
    if (raw.length <= 32 && !raw.contains('][') && !raw.contains('_')) {
      return raw;
    }
    return raw
        .replaceAll('][', ']\u200B[')
        .replaceAll('_', '_\u200B')
        .replaceAll('.', '.\u200B');
  }
}
