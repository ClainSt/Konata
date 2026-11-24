/// HTTP `Range` 字节区间请求解析模型。
class HttpByteRange {
  /// 创建合法闭区间（总长度为 [totalLength]）。
  const HttpByteRange({
    required this.start,
    required this.endInclusive,
    required this.totalLength,
  });

  /// 起始字节偏移（含）。
  final int start;

  /// 结束字节偏移（含）。
  final int endInclusive;

  /// 文件总字节数。
  final int totalLength;

  /// 当前切片响应长度（字节）。
  int get length => endInclusive - start + 1;

  /// 用作只读流切片的排他上界。
  int get endExclusive => endInclusive + 1;

  /// 构造 HTTP `Content-Range` 头值。
  String toContentRangeHeader() => 'bytes $start-$endInclusive/$totalLength';

  /// 解析单个 HTTP `Range` 请求头。
  ///
  /// - 未携带 `Range` 头时返回 `(hasHeader: false, valid: true, range: null)`；
  /// - 语法非法或越界时返回 `(hasHeader: true, valid: false, range: null)`。
  static ({bool hasHeader, bool valid, HttpByteRange? range}) parse(
    String? header,
    int totalLength,
  ) {
    if (header == null || header.trim().isEmpty) {
      return (hasHeader: false, valid: true, range: null);
    }
    if (totalLength <= 0) {
      return (hasHeader: true, valid: false, range: null);
    }
    final trimmed = header.trim();
    if (!trimmed.toLowerCase().startsWith('bytes=')) {
      return (hasHeader: true, valid: false, range: null);
    }
    final spec = trimmed.substring(6).trim();
    if (spec.isEmpty || spec.contains(',')) {
      return (hasHeader: true, valid: false, range: null);
    }
    final dash = spec.indexOf('-');
    if (dash < 0) {
      return (hasHeader: true, valid: false, range: null);
    }

    final startPart = spec.substring(0, dash).trim();
    final endPart = spec.substring(dash + 1).trim();

    if (startPart.isEmpty) {
      final suffixLen = int.tryParse(endPart);
      if (suffixLen == null || suffixLen <= 0) {
        return (hasHeader: true, valid: false, range: null);
      }
      final start = (totalLength - suffixLen).clamp(0, totalLength - 1);
      return (
        hasHeader: true,
        valid: true,
        range: HttpByteRange(
          start: start,
          endInclusive: totalLength - 1,
          totalLength: totalLength,
        ),
      );
    }

    final start = int.tryParse(startPart);
    if (start == null || start < 0 || start >= totalLength) {
      return (hasHeader: true, valid: false, range: null);
    }

    int endInclusive;
    if (endPart.isEmpty) {
      endInclusive = totalLength - 1;
    } else {
      final parsedEnd = int.tryParse(endPart);
      if (parsedEnd == null || parsedEnd < start) {
        return (hasHeader: true, valid: false, range: null);
      }
      endInclusive = parsedEnd >= totalLength ? totalLength - 1 : parsedEnd;
    }

    return (
      hasHeader: true,
      valid: true,
      range: HttpByteRange(
        start: start,
        endInclusive: endInclusive,
        totalLength: totalLength,
      ),
    );
  }
}
