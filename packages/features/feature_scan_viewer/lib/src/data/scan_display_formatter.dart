/// 扫图画廊与灯箱共用的纯领域展示格式化工具（字节大小、扩展名剥离与长文件名折行）。
abstract final class ScanDisplayFormatter {
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

  /// 剥离文件名扩展名用于卡片主标题展示。
  static String stripExtension(String fileName) {
    final trimmed = fileName.trim();
    final dot = trimmed.lastIndexOf('.');
    return dot > 0 ? trimmed.substring(0, dot) : trimmed;
  }

  /// 在密集括号、下划线与点分隔符后插入零宽空格，防止长文件名提前整行截断。
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
