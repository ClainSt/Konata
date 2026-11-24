import 'ass_uue_font_decoder.dart';

/// 云端字幕字体子集化服务的规范化 Origin（严格绑定 `scheme + host + port`）。
class CloudSubsetOrigin {
  /// 从规范化字段构建 Origin。
  const CloudSubsetOrigin({
    required this.scheme,
    required this.host,
    required this.port,
  });

  /// 从任意 HTTP/HTTPS 请求地址解析严格规范化的 `(scheme, host, port)` Origin。
  factory CloudSubsetOrigin.fromUri(Uri uri) {
    final normalizedScheme = uri.scheme.toLowerCase();
    if (normalizedScheme != 'http' && normalizedScheme != 'https') {
      throw FormatException('云端子集化仅允许 http/https 协议，当前为: ${uri.scheme}');
    }
    final normalizedHost = uri.host.trim().toLowerCase();
    if (normalizedHost.isEmpty) {
      throw const FormatException('云端子集化服务地址缺少有效主机名');
    }
    final resolvedPort = uri.hasPort
        ? uri.port
        : (normalizedScheme == 'https' ? 443 : 80);
    return CloudSubsetOrigin(
      scheme: normalizedScheme,
      host: normalizedHost,
      port: resolvedPort,
    );
  }

  /// 协议名（仅允许 `http` 或 `https`）。
  final String scheme;

  /// 小写规范化主机名。
  final String host;

  /// 显式归一化端口号（`http` 默认 80，`https` 默认 443）。
  final int port;

  /// 生成用于缓存隔离与权限登记的唯一稳定 Origin 键。
  String get key => '$scheme://$host:$port';

  @override
  bool operator ==(Object other) {
    return other is CloudSubsetOrigin &&
        other.scheme == scheme &&
        other.host == host &&
        other.port == port;
  }

  @override
  int get hashCode => Object.hash(scheme, host, port);

  @override
  String toString() => key;
}

/// ASS 云端子集化响应逐事件语义同构与零字形退化校验结果。
class AssSemanticVerificationResult {
  /// 创建语义校验结果。
  const AssSemanticVerificationResult({
    required this.isValid,
    this.failureReason,
    this.verifiedEventCount = 0,
    this.verifiedEmbeddedFontCount = 0,
  });

  /// 响应字幕是否 100% 通过逐事件语义同构与字体字形完整性检验。
  final bool isValid;

  /// 未通过检验时的精确诊断原因。
  final String? failureReason;

  /// 已逐条核对通过的 `Dialogue:` 事件数量。
  final int verifiedEventCount;

  /// 已验证 SFNT 魔数合法的内嵌子集字体数量。
  final int verifiedEmbeddedFontCount;
}

class _ParsedAssDialogue {
  const _ParsedAssDialogue({
    required this.layer,
    required this.start,
    required this.end,
    required this.style,
    required this.name,
    required this.marginL,
    required this.marginR,
    required this.marginV,
    required this.effect,
    required this.plainText,
    required this.nonFontTagSignature,
  });

  final String layer;
  final String start;
  final String end;
  final String style;
  final String name;
  final String marginL;
  final String marginR;
  final String marginV;
  final String effect;
  final String plainText;
  final String nonFontTagSignature;
}

/// 云端子集化 ASS 响应逐事件语义同构与零字形退化校验器（纯领域安全门禁）。
///
/// 响应在写入本地缓存前必须全部满足：
/// 1. `Dialogue:` 事件条数与原始字幕严格相等；
/// 2. 逐条事件的图层、起止时间、说话人、边距、特效字段与去标签纯对白文本 100% 一致；
/// 3. 除去合法子集别名改写（`\fn...`）外，其余全部 ASS 覆写标签语义保持同构；
/// 4. 内嵌 `[Fonts]` UUEncode 字体必须全部解码成功且通过 SFNT 魔数检验，严禁引入替换符或退化乱码。
class AssSemanticVerifier {
  AssSemanticVerifier._();

  static final RegExp _overrideBlockRegex = RegExp(r'\{([^}]*)\}');
  static final RegExp _fnTagRegex = RegExp(r'\\fn[^\\}]*');

  /// 对原始 ASS 与云端返回的子集化 ASS 执行逐事件同构与零退化核验。
  static AssSemanticVerificationResult verify({
    required String originalAss,
    required String subsettedAss,
  }) {
    if (subsettedAss.trim().isEmpty) {
      return const AssSemanticVerificationResult(
        isValid: false,
        failureReason: '云端返回空字幕响应',
      );
    }

    final origEvents = _parseDialogues(originalAss);
    final nextEvents = _parseDialogues(subsettedAss);
    if (origEvents.length != nextEvents.length) {
      return AssSemanticVerificationResult(
        isValid: false,
        failureReason:
            '对白事件数量不一致（原始 ${origEvents.length} 条，返回 ${nextEvents.length} 条）',
      );
    }

    for (var i = 0; i < origEvents.length; i++) {
      final a = origEvents[i];
      final b = nextEvents[i];
      if (a.layer != b.layer ||
          a.start != b.start ||
          a.end != b.end ||
          a.style != b.style ||
          a.name != b.name ||
          a.marginL != b.marginL ||
          a.marginR != b.marginR ||
          a.marginV != b.marginV ||
          a.effect != b.effect) {
        return AssSemanticVerificationResult(
          isValid: false,
          failureReason: '第 ${i + 1} 条对白的时间轴、图层或元数据字段被篡改',
        );
      }
      if (a.plainText != b.plainText) {
        return AssSemanticVerificationResult(
          isValid: false,
          failureReason: '第 ${i + 1} 条对白纯文本内容发生变动或字形退化',
        );
      }
      if (a.nonFontTagSignature != b.nonFontTagSignature) {
        return AssSemanticVerificationResult(
          isValid: false,
          failureReason: '第 ${i + 1} 条对白的非字体覆写标签语义遭到改写',
        );
      }
      if (!a.plainText.contains('\uFFFD') && b.plainText.contains('\uFFFD')) {
        return AssSemanticVerificationResult(
          isValid: false,
          failureReason: '第 ${i + 1} 条对白引入了非法 Unicode 替换符',
        );
      }
    }

    // 校验返回字幕中的内嵌 [Fonts] 块全部可精确解码且通过 SFNT 字体头魔数检查。
    final List<AssEmbeddedFontEntry> embeddedFonts;
    try {
      embeddedFonts = AssUueFontDecoder.extractEmbeddedFonts(subsettedAss);
    } on FormatException catch (e) {
      return AssSemanticVerificationResult(
        isValid: false,
        failureReason: '内嵌字体 UUEncode 解码失败: ${e.message}',
      );
    }
    for (final font in embeddedFonts) {
      if (!AssUueFontDecoder.isValidFontMagic(font.bytes)) {
        return AssSemanticVerificationResult(
          isValid: false,
          failureReason: '内嵌字体 ${font.fontName} 未通过 SFNT 合法字体魔数检验',
        );
      }
    }

    return AssSemanticVerificationResult(
      isValid: true,
      verifiedEventCount: origEvents.length,
      verifiedEmbeddedFontCount: embeddedFonts.length,
    );
  }

  static List<_ParsedAssDialogue> _parseDialogues(String content) {
    final result = <_ParsedAssDialogue>[];
    for (final rawLine in content.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trimRight();
      if (!line.startsWith('Dialogue:')) continue;
      final rest = line.substring('Dialogue:'.length);
      final commas = <int>[];
      for (var i = 0; i < rest.length; i++) {
        if (rest.codeUnitAt(i) == 0x2C) {
          commas.add(i);
          if (commas.length == 9) break;
        }
      }
      if (commas.length < 9) continue;

      final payload = rest.substring(commas[8] + 1);
      final plainText = payload.replaceAll(_overrideBlockRegex, '');
      final nonFontTags = StringBuffer();
      for (final m in _overrideBlockRegex.allMatches(payload)) {
        final inner = m.group(1)!.replaceAll(_fnTagRegex, '').trim();
        if (inner.isNotEmpty) {
          nonFontTags
            ..write('{')
            ..write(inner)
            ..write('}');
        }
      }

      result.add(
        _ParsedAssDialogue(
          layer: rest.substring(0, commas[0]).trim(),
          start: rest.substring(commas[0] + 1, commas[1]).trim(),
          end: rest.substring(commas[1] + 1, commas[2]).trim(),
          style: rest.substring(commas[2] + 1, commas[3]).trim(),
          name: rest.substring(commas[3] + 1, commas[4]).trim(),
          marginL: rest.substring(commas[4] + 1, commas[5]).trim(),
          marginR: rest.substring(commas[5] + 1, commas[6]).trim(),
          marginV: rest.substring(commas[6] + 1, commas[7]).trim(),
          effect: rest.substring(commas[7] + 1, commas[8]).trim(),
          plainText: plainText,
          nonFontTagSignature: nonFontTags.toString(),
        ),
      );
    }
    return result;
  }
}
