import 'package:xml/xml.dart';

/// TTML 逐字歌词转换结果。
class TtmlConversion {
  /// 创建转换结果。
  const TtmlConversion({
    required this.lrc,
    required this.hasTranslation,
    required this.hasWordTiming,
  });

  /// 增强 LRC 正文（主唱逐字行、同时间戳译文行与 `bg:` 和声行）。
  final String lrc;

  /// 是否包含 `x-translation` 译文。
  final bool hasTranslation;

  /// 是否包含逐字时间。
  final bool hasWordTiming;
}

/// AMLL / Apple 风格 TTML 逐字歌词转换器（基于 XML 解析，正确处理嵌套和声与词间空格）。
abstract final class TtmlLyricConverter {
  static const TtmlConversion _empty = TtmlConversion(
    lrc: '',
    hasTranslation: false,
    hasWordTiming: false,
  );

  /// 将 TTML 文本转换为增强 LRC；解析失败或无有效行时返回空结果。
  static TtmlConversion convert(String ttml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(ttml);
    } on XmlException {
      return _empty;
    }

    final out = StringBuffer();
    var hasTranslation = false;
    var hasWordTiming = false;

    for (final p in doc.descendantElements.where((e) => e.name.local == 'p')) {
      final lineBegin = parseTimestamp(_attr(p, 'begin'));
      if (lineBegin == null) continue;
      final lineTag = formatLrcTag(lineBegin);

      final main = StringBuffer();
      final bg = StringBuffer();
      final translation = StringBuffer();
      var mainHasWords = false;

      for (final node in p.children) {
        if (node is XmlText) {
          _appendSeparator(main, node.value);
          continue;
        }
        if (node is! XmlElement || node.name.local != 'span') continue;
        final role = (_attr(node, 'role') ?? '').toLowerCase();
        switch (role) {
          case 'x-translation':
            translation.write(node.innerText.trim());
          case 'x-roman':
            break;
          case 'x-bg':
            final bgHasWords = _writeWordSpans(node, bg);
            hasWordTiming = hasWordTiming || bgHasWords;
          default:
            if (_writeWordSpan(node, main)) {
              mainHasWords = true;
            }
        }
      }

      final mainText = main.toString().trim();
      if (mainText.isNotEmpty) {
        out.writeln('[$lineTag]$mainText');
      }
      final translationText = translation.toString().trim();
      if (translationText.isNotEmpty) {
        hasTranslation = true;
        out.writeln('[$lineTag]$translationText');
      }
      final bgText = bg.toString().trim();
      if (bgText.isNotEmpty) {
        out.writeln('[$lineTag]bg:$bgText');
      }
      hasWordTiming = hasWordTiming || mainHasWords;
    }

    final lrc = out.toString();
    if (lrc.trim().isEmpty) return _empty;
    return TtmlConversion(
      lrc: lrc,
      hasTranslation: hasTranslation,
      hasWordTiming: hasWordTiming,
    );
  }

  /// 写入单个逐字片段；返回是否带有效起始时间。
  static bool _writeWordSpan(XmlElement span, StringBuffer target) {
    final text = span.innerText;
    if (text.isEmpty) return false;
    final begin = parseTimestamp(_attr(span, 'begin'));
    if (begin == null) {
      target.write(text);
      return false;
    }
    target.write('<${formatLrcTag(begin)}>$text');
    return true;
  }

  /// 写入和声容器内的全部逐字片段；容器无子片段时按单片段处理。
  static bool _writeWordSpans(XmlElement container, StringBuffer target) {
    final childSpans = container.childElements
        .where((e) => e.name.local == 'span')
        .toList(growable: false);
    if (childSpans.isEmpty) return _writeWordSpan(container, target);
    var any = false;
    for (final node in container.children) {
      if (node is XmlText) {
        _appendSeparator(target, node.value);
      } else if (node is XmlElement && node.name.local == 'span') {
        any = _writeWordSpan(node, target) || any;
      }
    }
    return any;
  }

  /// 词间纯空格视为单词分隔；含换行或制表的空白视为排版缩进并忽略。
  static void _appendSeparator(StringBuffer target, String raw) {
    if (raw.isEmpty) return;
    if (raw.trim().isNotEmpty) {
      target.write(raw);
      return;
    }
    if (raw.contains('\n') || raw.contains('\r') || raw.contains('\t')) return;
    if (target.isNotEmpty) target.write(' ');
  }

  static String? _attr(XmlElement element, String localName) {
    for (final attribute in element.attributes) {
      if (attribute.name.local == localName) return attribute.value;
    }
    return null;
  }

  /// 解析 TTML 时间（`12.3s`、`mm:ss.fff`、`hh:mm:ss.fff` 或纯秒数）。
  static double? parseTimestamp(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.endsWith('s')) {
      return double.tryParse(trimmed.substring(0, trimmed.length - 1));
    }
    final parts = trimmed.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]);
      final s = double.tryParse(parts[1]);
      if (m != null && s != null) return m * 60.0 + s;
      return null;
    }
    if (parts.length == 3) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final s = double.tryParse(parts[2]);
      if (h != null && m != null && s != null) return h * 3600.0 + m * 60.0 + s;
      return null;
    }
    return double.tryParse(trimmed);
  }

  /// 将秒数格式化为 `mm:ss.xx` LRC 时间标签正文。
  static String formatLrcTag(double seconds) {
    final totalCs = (seconds < 0 ? 0.0 : seconds * 100.0).round();
    final cs = totalCs % 100;
    final totalSec = totalCs ~/ 100;
    final sec = totalSec % 60;
    final min = totalSec ~/ 60;
    return '${min.toString().padLeft(2, '0')}:'
        '${sec.toString().padLeft(2, '0')}.'
        '${cs.toString().padLeft(2, '0')}';
  }
}
