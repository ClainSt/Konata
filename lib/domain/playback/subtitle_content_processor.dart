/// 字幕内嵌/外挂字体子集化三态分类。
enum SubtitleSubsetState {
  /// 未子集化：常规字库名与标准 Unicode 文本。
  unsubsetted,

  /// 可还原映射子集：存在子集别名或 `[Fonts]` 嵌入，但对白码位仍为正常 Unicode（可安全读取与展示）。
  restorableMappedSubset,

  /// 码位混淆不透明子集：字形被重映射至私用区（PUA）或乱码拉丁/符号位；
  /// 自动繁简转换模式严禁改写该类文本，避免破坏特效字幕字形映射。
  opaqueObfuscatedSubset,
}

/// OpenCC 繁简转换目标模式。
enum SubtitleOpenCcMode {
  /// 保持原文不做转换。
  none,

  /// 转换为简体中文（繁转简）。
  toSimplified,

  /// 转换为繁体中文（简转繁）。
  toTraditional,
}

/// 字幕内容处理策略结果。
class SubtitleContentProcessResult {
  /// 创建字幕处理结果。
  const SubtitleContentProcessResult({
    required this.content,
    required this.subsetState,
    required this.converted,
    this.skipReason,
  });

  /// 处理后的最终字幕文本。
  final String content;

  /// 探测到的字幕字体子集三态分类。
  final SubtitleSubsetState subsetState;

  /// 本次是否实际执行了 OpenCC 片段转换。
  final bool converted;

  /// 若自动模式下因保护规则跳过转换，则记录跳过原因。
  final String? skipReason;
}

/// 双语字幕片段语种分类。
enum _SegmentScript {
  japaneseKanaDominant,
  chineseHan,
  latinOrNeutral,
}

/// 字幕三态子集保护与双语 ASS 可逆片段 OpenCC 转换器（纯领域算法）。
class SubtitleContentProcessor {
  SubtitleContentProcessor._();

  static final RegExp _subsetAliasFontRegex = RegExp(
    r'(?:^|[,\\fn])([A-Za-z0-9]{6,12})\+|[_\-](?:subset|subfont)|subsetted',
    caseSensitive: false,
  );
  static final RegExp _assOverrideBlockRegex = RegExp(r'\{[^}]*\}');
  static final RegExp _assDrawingEnableRegex = RegExp(r'\\p[1-9]\d*');
  static final RegExp _assDrawingDisableRegex = RegExp(r'\\p0(?:\D|$)');
  static final RegExp _assLineBreakRegex = RegExp(r'(\\[Nnh])');

  /// 识别 ASS / SRT / VTT 文本的字体子集三态分类。
  static SubtitleSubsetState classifySubsetState(String content) {
    final hasFontsSection = RegExp(
      r'^\s*\[Fonts\]\s*$',
      multiLine: true,
      caseSensitive: false,
    ).hasMatch(content);
    final hasSubsetFontHints =
        hasFontsSection || _subsetAliasFontRegex.hasMatch(content);

    var puaCount = 0;
    var cjkCount = 0;
    var suspiciousObfuscatedRuns = 0;

    for (final rawLine in content.split('\n')) {
      final line = rawLine.trimRight();
      if (!line.startsWith('Dialogue:') && !line.startsWith('Comment:')) {
        continue;
      }
      final payload = _extractAssDialoguePayload(line);
      if (payload == null) continue;
      final plain = _stripAssOverrideAndDrawing(payload);
      if (plain.isEmpty) continue;

      var lineAsciiWeird = 0;
      var linePua = 0;
      for (final rune in plain.runes) {
        if ((rune >= 0xE000 && rune <= 0xF8FF) ||
            (rune >= 0xF0000 && rune <= 0xFFFFD)) {
          puaCount++;
          linePua++;
        } else if (_isCjkIdeograph(rune)) {
          cjkCount++;
        } else if (rune >= 0x00A1 && rune <= 0x024F) {
          lineAsciiWeird++;
        }
      }
      if (linePua >= 2) {
        suspiciousObfuscatedRuns++;
      } else if (hasSubsetFontHints &&
          lineAsciiWeird >= 6 &&
          cjkCount == 0 &&
          !plain.contains(' ')) {
        suspiciousObfuscatedRuns++;
      }
    }

    if (puaCount >= 2 || suspiciousObfuscatedRuns > 0) {
      return SubtitleSubsetState.opaqueObfuscatedSubset;
    }
    if (hasSubsetFontHints) {
      return SubtitleSubsetState.restorableMappedSubset;
    }
    return SubtitleSubsetState.unsubsetted;
  }

  /// 执行带三态子集保护的双语 ASS / SRT / VTT 可逆 OpenCC 转换。
  ///
  /// - 自动模式（`forceOverrideSubsetGuard == false`）遇 `opaqueObfuscatedSubset` 立即跳过转换，防止毁字；
  /// - 双语 ASS 行按 `\N` 与 `{...}` 样式片段独立识别语种，含日文假名的片段保持原样不误转；
  /// - 仅在跨样式边界满足位置可逆映射时合并相邻中文片段进行词组转换。
  static SubtitleContentProcessResult process({
    required String content,
    required SubtitleOpenCcMode mode,
    bool forceOverrideSubsetGuard = false,
  }) {
    final subsetState = classifySubsetState(content);
    if (mode == SubtitleOpenCcMode.none) {
      return SubtitleContentProcessResult(
        content: content,
        subsetState: subsetState,
        converted: false,
      );
    }

    if (!forceOverrideSubsetGuard &&
        subsetState == SubtitleSubsetState.opaqueObfuscatedSubset) {
      return SubtitleContentProcessResult(
        content: content,
        subsetState: subsetState,
        converted: false,
        skipReason: 'opaque_obfuscated_subset_protected',
      );
    }

    final isAss =
        content.contains('[Events]') ||
        RegExp(r'^\s*Dialogue:', multiLine: true).hasMatch(content);
    final transformed = isAss
        ? _convertAssContent(content, mode)
        : _convertPlainSubtitleLines(content, mode);

    return SubtitleContentProcessResult(
      content: transformed,
      subsetState: subsetState,
      converted: transformed != content,
    );
  }

  static String _convertAssContent(String content, SubtitleOpenCcMode mode) {
    final usesCrlf = content.contains('\r\n');
    final lines = content.split(RegExp(r'\r?\n'));
    final out = <String>[];
    for (final line in lines) {
      if (!line.startsWith('Dialogue:')) {
        out.add(line);
        continue;
      }
      final splitIdx = _findAssTextStartIndex(line);
      if (splitIdx < 0) {
        out.add(line);
        continue;
      }
      final prefix = line.substring(0, splitIdx);
      final payload = line.substring(splitIdx);
      out.add('$prefix${_convertAssDialoguePayload(payload, mode)}');
    }
    return out.join(usesCrlf ? '\r\n' : '\n');
  }

  static String _convertAssDialoguePayload(
    String payload,
    SubtitleOpenCcMode mode,
  ) {
    // 1. 按 \N / \n / \h 切分物理双语视觉段，各段独立判断是否为日文假名主段。
    final parts = <String>[];
    var cursor = 0;
    for (final match in _assLineBreakRegex.allMatches(payload)) {
      if (match.start > cursor) {
        parts.add(
          _convertSingleAssVisualSegment(
            payload.substring(cursor, match.start),
            mode,
          ),
        );
      }
      parts.add(match.group(0)!);
      cursor = match.end;
    }
    if (cursor < payload.length) {
      parts.add(_convertSingleAssVisualSegment(payload.substring(cursor), mode));
    }
    return parts.join();
  }

  static String _convertSingleAssVisualSegment(
    String segment,
    SubtitleOpenCcMode mode,
  ) {
    final stripped = _stripAssOverrideAndDrawing(segment);
    if (_classifySegmentScript(stripped) != _SegmentScript.chineseHan) {
      return segment;
    }

    // 拆分为「覆写标签 / 绘图区」与「可见纯文本」交替令牌，仅在字符级一一可逆时跨标签合并词组转换。
    final tokens = <({String text, bool convertible})>[];
    var drawingActive = false;
    var cursor = 0;
    for (final m in _assOverrideBlockRegex.allMatches(segment)) {
      if (m.start > cursor) {
        tokens.add((
          text: segment.substring(cursor, m.start),
          convertible: !drawingActive,
        ));
      }
      final tag = m.group(0)!;
      if (_assDrawingDisableRegex.hasMatch(tag)) {
        drawingActive = false;
      } else if (_assDrawingEnableRegex.hasMatch(tag)) {
        drawingActive = true;
      }
      tokens.add((text: tag, convertible: false));
      cursor = m.end;
    }
    if (cursor < segment.length) {
      tokens.add((
        text: segment.substring(cursor),
        convertible: !drawingActive,
      ));
    }

    // 尝试将相邻可转换文本合并分词；仅在长度完全等长（位置一一可逆）时回填各片段，否则逐片段安全转换。
    final convertibleIndices = <int>[];
    final mergedBuffer = StringBuffer();
    final lengths = <int>[];
    for (var i = 0; i < tokens.length; i++) {
      if (!tokens[i].convertible) continue;
      convertibleIndices.add(i);
      mergedBuffer.write(tokens[i].text);
      lengths.add(tokens[i].text.length);
    }

    if (convertibleIndices.isEmpty) return segment;

    final mergedOriginal = mergedBuffer.toString();
    final mergedConverted = _applyOpenCcText(mergedOriginal, mode);
    if (mergedConverted.length == mergedOriginal.length) {
      var offset = 0;
      final outTokens = List<String>.generate(
        tokens.length,
        (i) => tokens[i].text,
      );
      for (var k = 0; k < convertibleIndices.length; k++) {
        final len = lengths[k];
        outTokens[convertibleIndices[k]] = mergedConverted.substring(
          offset,
          offset + len,
        );
        offset += len;
      }
      return outTokens.join();
    }

    // 不可逆（长度变化）时回退至单段独立转换，确保不跨标签错位。
    final fallbackOut = StringBuffer();
    for (final token in tokens) {
      if (token.convertible) {
        fallbackOut.write(_applyOpenCcText(token.text, mode));
      } else {
        fallbackOut.write(token.text);
      }
    }
    return fallbackOut.toString();
  }

  static String _convertPlainSubtitleLines(
    String content,
    SubtitleOpenCcMode mode,
  ) {
    final usesCrlf = content.contains('\r\n');
    final lines = content.split(RegExp(r'\r?\n'));
    final out = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty ||
          trimmed == 'WEBVTT' ||
          trimmed.contains('-->') ||
          RegExp(r'^\d+$').hasMatch(trimmed)) {
        out.add(line);
        continue;
      }
      if (_classifySegmentScript(line) == _SegmentScript.chineseHan) {
        out.add(_applyOpenCcText(line, mode));
      } else {
        out.add(line);
      }
    }
    return out.join(usesCrlf ? '\r\n' : '\n');
  }

  static _SegmentScript _classifySegmentScript(String text) {
    var kana = 0;
    var han = 0;
    for (final rune in text.runes) {
      if ((rune >= 0x3040 && rune <= 0x309F) ||
          (rune >= 0x30A0 && rune <= 0x30FF) ||
          (rune >= 0xFF66 && rune <= 0xFF9F)) {
        kana++;
      } else if (_isCjkIdeograph(rune)) {
        han++;
      }
    }
    if (kana > 0) return _SegmentScript.japaneseKanaDominant;
    if (han > 0) return _SegmentScript.chineseHan;
    return _SegmentScript.latinOrNeutral;
  }

  static bool _isCjkIdeograph(int rune) {
    return (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF);
  }

  static int _findAssTextStartIndex(String dialogueLine) {
    // 标准 ASS Dialogue 字段共 9 个逗号（Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text）。
    var commas = 0;
    for (var i = 0; i < dialogueLine.length; i++) {
      if (dialogueLine.codeUnitAt(i) == 0x2C) {
        commas++;
        if (commas == 9) {
          return i + 1;
        }
      }
    }
    return -1;
  }

  static String? _extractAssDialoguePayload(String line) {
    final idx = _findAssTextStartIndex(line);
    return idx < 0 ? null : line.substring(idx);
  }

  static String _stripAssOverrideAndDrawing(String payload) {
    final buf = StringBuffer();
    var drawing = false;
    var cursor = 0;
    for (final m in _assOverrideBlockRegex.allMatches(payload)) {
      if (!drawing && m.start > cursor) {
        buf.write(payload.substring(cursor, m.start));
      }
      final tag = m.group(0)!;
      if (_assDrawingDisableRegex.hasMatch(tag)) {
        drawing = false;
      } else if (_assDrawingEnableRegex.hasMatch(tag)) {
        drawing = true;
      }
      cursor = m.end;
    }
    if (!drawing && cursor < payload.length) {
      buf.write(payload.substring(cursor));
    }
    return buf.toString().replaceAll(_assLineBreakRegex, '');
  }

  static String _applyOpenCcText(String text, SubtitleOpenCcMode mode) {
    var result = text;
    final phrases = mode == SubtitleOpenCcMode.toSimplified
        ? _t2sPhrases
        : _s2tPhrases;
    for (final entry in phrases.entries) {
      if (result.contains(entry.key)) {
        result = result.replaceAll(entry.key, entry.value);
      }
    }
    final charMap = mode == SubtitleOpenCcMode.toSimplified
        ? _t2sChars
        : _s2tChars;
    final out = StringBuffer();
    for (final rune in result.runes) {
      final ch = String.fromCharCode(rune);
      out.write(charMap[ch] ?? ch);
    }
    return out.toString();
  }

  /// 高频动漫双语字幕词组级繁简转换表（保证长词优先于单字消除歧义，如「後面 -> 后面」「皇后 -> 皇后」）。
  static const Map<String, String> _t2sPhrases = <String, String>{
    '軟體': '软件',
    '硬體': '硬件',
    '網路': '网络',
    '動畫': '动画',
    '繁體': '繁体',
    '簡體': '简体',
    '字幕組': '字幕组',
    '時間軸': '时间轴',
    '聲音': '声音',
    '畫面': '画面',
    '後面': '后面',
    '頭髮': '头发',
    '出發': '出发',
    '發現': '发现',
    '應該': '应该',
    '這個': '这个',
    '那個': '那个',
    '什麼': '什么',
    '怎麼': '怎么',
    '為什麼': '为什么',
    '沒關係': '没关系',
    '對不起': '对不起',
    '謝謝': '谢谢',
  };

  static const Map<String, String> _s2tPhrases = <String, String>{
    '软件': '軟體',
    '硬件': '硬體',
    '网络': '網路',
    '动画': '動畫',
    '繁体': '繁體',
    '简体': '簡體',
    '字幕组': '字幕組',
    '时间轴': '時間軸',
    '声音': '聲音',
    '画面': '畫面',
    '后面': '後面',
    '头发': '頭髮',
    '出发': '出發',
    '发现': '發現',
    '应该': '應該',
    '这个': '這個',
    '那个': '那個',
    '什么': '什麼',
    '怎么': '怎麼',
    '为什么': '為什麼',
    '没关系': '沒關係',
    '对不起': '對不起',
    '谢谢': '謝謝',
  };

  /// 常用繁简单字映射表（严格唯一键值，覆盖高频番剧对白单字）。
  static const Map<String, String> _t2sChars = <String, String>{
    '體': '体',
    '簡': '简',
    '國': '国',
    '學': '学',
    '愛': '爱',
    '會': '会',
    '說': '说',
    '話': '话',
    '語': '语',
    '請': '请',
    '讓': '让',
    '這': '这',
    '為': '为',
    '與': '与',
    '來': '来',
    '時': '时',
    '間': '间',
    '開': '开',
    '關': '关',
    '門': '门',
    '問': '问',
    '題': '题',
    '見': '见',
    '視': '视',
    '覺': '觉',
    '聽': '听',
    '聲': '声',
    '響': '响',
    '動': '动',
    '畫': '画',
    '書': '书',
    '寫': '写',
    '讀': '读',
    '點': '点',
    '頭': '头',
    '臉': '脸',
    '淚': '泪',
    '夢': '梦',
    '實': '实',
    '現': '现',
    '場': '场',
    '處': '处',
    '樣': '样',
    '種': '种',
    '類': '类',
    '組': '组',
    '線': '线',
    '經': '经',
    '結': '结',
    '給': '给',
    '紅': '红',
    '綠': '绿',
    '藍': '蓝',
    '黃': '黄',
    '銀': '银',
    '劍': '剑',
    '戰': '战',
    '勝': '胜',
    '敗': '败',
    '強': '强',
    '護': '护',
    '殺': '杀',
    '離': '离',
    '難': '难',
    '電': '电',
    '車': '车',
    '飛': '飞',
    '機': '机',
    '風': '风',
    '雲': '云',
    '龍': '龙',
    '鳥': '鸟',
    '魚': '鱼',
    '馬': '马',
    '長': '长',
    '東': '东',
    '華': '华',
    '無': '无',
    '萬': '万',
    '億': '亿',
    '兩': '两',
    '個': '个',
    '們': '们',
    '從': '从',
    '還': '还',
    '進': '进',
    '過': '过',
    '運': '运',
    '邊': '边',
    '達': '达',
    '遠': '远',
    '連': '连',
    '選': '选',
    '錯': '错',
    '對': '对',
    '應': '应',
    '該': '该',
    '當': '当',
    '發': '发',
    '變': '变',
    '歡': '欢',
    '樂': '乐',
    '氣': '气',
    '測': '测',
    '試': '试',
    '驗': '验',
    '證': '证',
    '轉': '转',
    '換': '换',
    '碼': '码',
    '號': '号',
    '標': '标',
    '準': '准',
    '確': '确',
    '認': '认',
    '記': '记',
    '錄': '录',
    '設': '设',
    '計': '计',
    '調': '调',
    '軸': '轴',
    '譯': '译',
    '雙': '双',
    '單': '单',
    '純': '纯',
    '淨': '净',
    '總': '总',
    '終': '终',
    '續': '续',
    '斷': '断',
    '舊': '旧',
    '輕': '轻',
    '載': '载',
    '傳': '传',
    '統': '统',
    '備': '备',
    '獨': '独',
    '專': '专',
    '屬': '属',
    '層': '层',
    '級': '级',
    '頁': '页',
    '項': '项',
    '條': '条',
    '節': '节',
    '衛': '卫',
    '師': '师',
    '團': '团',
    '隊': '队',
    '員': '员',
    '廠': '厂',
    '廳': '厅',
    '廣': '广',
    '慶': '庆',
    '歸': '归',
    '歲': '岁',
    '歷': '历',
    '殲': '歼',
    '滅': '灭',
    '靈': '灵',
    '煉': '炼',
    '燒': '烧',
    '熱': '热',
    '燈': '灯',
    '營': '营',
    '環': '环',
    '產': '产',
    '異': '异',
    '療': '疗',
    '監': '监',
    '盤': '盘',
    '眾': '众',
    '睜': '睁',
    '瞞': '瞒',
    '瞭': '了',
    '礎': '础',
    '禮': '礼',
    '稱': '称',
    '積': '积',
    '穩': '稳',
    '窮': '穷',
    '競': '竞',
    '筆': '笔',
    '範': '范',
    '築': '筑',
    '篩': '筛',
    '籌': '筹',
    '簽': '签',
    '糧': '粮',
    '緊': '紧',
    '約': '约',
    '紀': '纪',
    '納': '纳',
    '紙': '纸',
    '紛': '纷',
    '紡': '纺',
    '細': '细',
    '絕': '绝',
    '絡': '络',
    '絲': '丝',
    '綁': '绑',
    '綜': '综',
    '維': '维',
    '綱': '纲',
    '網': '网',
    '緒': '绪',
    '練': '练',
    '編': '编',
    '緩': '缓',
    '締': '缔',
    '緣': '缘',
    '縣': '县',
    '縫': '缝',
    '縮': '缩',
    '縱': '纵',
    '績': '绩',
    '織': '织',
    '繞': '绕',
    '繪': '绘',
    '繳': '缴',
    '繼': '继',
    '纖': '纤',
    '纜': '缆',
    '羅': '罗',
    '罰': '罚',
    '罵': '骂',
    '罷': '罢',
    '義': '义',
    '習': '习',
    '翹': '翘',
    '職': '职',
    '聯': '联',
    '聰': '聪',
    '肅': '肃',
    '脫': '脱',
    '腦': '脑',
    '腳': '脚',
    '臨': '临',
    '臺': '台',
    '興': '兴',
    '舉': '举',
    '艦': '舰',
    '艱': '艰',
    '藝': '艺',
    '葉': '叶',
    '著': '着',
    '補': '补',
    '裝': '装',
    '製': '制',
    '複': '复',
    '褲': '裤',
    '襲': '袭',
    '規': '规',
    '親': '亲',
    '覽': '览',
    '觀': '观',
    '觸': '触',
    '訂': '订',
    '討': '讨',
    '訓': '训',
    '議': '议',
    '訊': '讯',
    '講': '讲',
    '許': '许',
    '論': '论',
    '訪': '访',
    '評': '评',
    '識': '识',
    '詞': '词',
    '詩': '诗',
    '誠': '诚',
    '詳': '详',
    '誤': '误',
    '誰': '谁',
    '課': '课',
    '談': '谈',
    '諾': '诺',
    '貝': '贝',
    '負': '负',
    '財': '财',
    '責': '责',
    '賢': '贤',
    '貨': '货',
    '質': '质',
    '買': '买',
    '費': '费',
    '貼': '贴',
    '貴': '贵',
    '貸': '贷',
    '貿': '贸',
    '賀': '贺',
    '資': '资',
    '賞': '赏',
    '賣': '卖',
    '賽': '赛',
    '贊': '赞',
    '贈': '赠',
    '贏': '赢',
    '趕': '赶',
    '趙': '赵',
    '趨': '趋',
    '躍': '跃',
    '軌': '轨',
    '軍': '军',
    '軟': '软',
    '較': '较',
    '輔': '辅',
    '輛': '辆',
    '輝': '辉',
    '輩': '辈',
    '輪': '轮',
    '輯': '辑',
    '輸': '输',
    '轟': '轰',
    '辦': '办',
    '辭': '辞',
    '違': '违',
    '適': '适',
    '遺': '遗',
    '邁': '迈',
    '鄰': '邻',
    '鄭': '郑',
    '釋': '释',
    '針': '针',
    '錢': '钱',
    '錦': '锦',
    '鍵': '键',
    '鍾': '钟',
    '鎖': '锁',
    '鎮': '镇',
    '鏡': '镜',
    '鏈': '链',
    '鐵': '铁',
    '鑑': '鉴',
    '閉': '闭',
    '閒': '闲',
    '閃': '闪',
    '閣': '阁',
    '閱': '阅',
    '陣': '阵',
    '陰': '阴',
    '陳': '陈',
    '陸': '陆',
    '陽': '阳',
    '階': '阶',
    '際': '际',
    '隨': '随',
    '隱': '隐',
    '雜': '杂',
    '雞': '鸡',
    '霧': '雾',
    '靜': '静',
    '頂': '顶',
    '順': '顺',
    '須': '须',
    '預': '预',
    '領': '领',
    '頻': '频',
    '額': '额',
    '顏': '颜',
    '願': '愿',
    '顧': '顾',
    '顯': '显',
    '飄': '飘',
    '飯': '饭',
    '飲': '饮',
    '飾': '饰',
    '館': '馆',
    '驅': '驱',
    '駛': '驶',
    '駐': '驻',
    '駕': '驾',
    '騎': '骑',
    '騙': '骗',
    '驚': '惊',
    '髮': '发',
    '鬆': '松',
    '鬧': '闹',
    '鬱': '郁',
    '鮮': '鲜',
    '鳴': '鸣',
    '鳳': '凤',
    '麗': '丽',
    '麥': '麦',
    '麵': '面',
    '麼': '么',
    '黨': '党',
    '齊': '齐',
    '龜': '龟',
  };

  static final Map<String, String> _s2tChars = <String, String>{
    for (final entry in _t2sChars.entries) entry.value: entry.key,
  };
}
