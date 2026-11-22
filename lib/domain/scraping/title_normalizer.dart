/// 零依赖轻量番剧/影视标题归一化工具，统一处理简繁体中文、全半角 ASCII、
/// 日语假名、Unicode 罗马数字及标题专用乘号分隔符。
/// 用于本地标题归并、索引建键与跨源高召回匹配。
///
/// 繁简汉字对照字符映射表提取自 OpenCC 开放中文转换项目的 `TSCharacters` 词典
/// （遵循 Apache License 2.0 开源许可协议）。
class TitleNormalizer {
  const TitleNormalizer._();

  // 高频繁简汉字与常见影视/动画片名词汇子集映射（按单个 Unicode 码元一比一对齐）。
  // 确保高频作品译名在简繁差异下保持相同归一键。
  static const String _traditionalChars =
      '並亂亞來係俠個倫側偵偽傑傘備傢傳傷僅價儀億優兒內兩冊凍凱創劇劍劑動務勝勞勢勳勵勸區協卻厭參吳員問啟喚喪喬單嗎嗚嘆嘯噁噴嚇嚴囉國圍園圓圖團執堅報場塗墊墜墮墳壇壓壘壞壯壺壽夠夢夥奧奪奮娛婦媽嬰孫學宮實寧審寫寬寵寶將專尋對導尷屆屬岡島峽嵐嶺巔師帶幣幫幹幾庫廠廢廣廳張強彈彙後從復徵徹惡惱愛態慶慾憐憑憤憲憶應懷懸戀戰戲戶捲掃採揚換揮損搖撲擊擬擴攝敗敘敵數斷於時曆曉書會東條楓業極構槍樂樓標樣機橫檔櫻歐歡歷歸殘殺毀氣決況涼淨減準溫滅滾漢潔潛澤灣災為無煉熱爭爺爾獄獎獨獵獸獻現瑪環產畫異當疊療發盡監盤眾確禮種稱穩窮競筆範築簡籃紀約紅紋納紐純紙級紛細終組結絕給統絲經維網緊線緣編緩練縮縱總織繞繪繫繼續羅義習聖聯聰聲職聽腦臉臨臺與興舉艦莊華萊萬蒼蓮薩藍藥蘇蘭處號蟲術衛衝裏裝裡製複襲見規視親覺覽觀計訊討訓記設許訴診証評詞試詩話該詳語誤說誰課調談請論諜諸證識譯議護變讓讚負財貢貧貨販貪責貴買費貼貿賀資賞賢賣賦質賴賺賽贈贊贏趕趙跡踐躍軀車軌軍軒軟載輕輛輝輩輪輯輸轉轎辭農迴這連週進遊運過達違遙遜遠適遲遷選遺邁還邊邏郵鄉鄰醫釋針釣鈴銀銅鋸鋼錄錢錦錯鍊鍋鍵鎖鎮鏈鏡鐘鐵鑑長門閃閉開閏閒間閣閥閱閻闘關陣陰陽隊階際隨險隱隻雖雙雜雞離難雲電霧靈靜韓響頁頂項順須預領頭頻題額顏願類顧顯風飄飛飢飯飲飼飽飾養餘館馬駐騎騙騷驅驗驚體髮鬆鬥鬧鬱魚魯鮮鯉鯨鳥鳳鳴鴻鵝鶴鷹麗麥麵黃點黨齊齒齡龍龜葉';

  static const String _simplifiedChars =
      '并乱亚来系侠个伦侧侦伪杰伞备家传伤仅价仪亿优儿内两册冻凯创剧剑剂动务胜劳势勋励劝区协却厌参吴员问启唤丧乔单吗呜叹啸恶喷吓严啰国围园圆图团执坚报场涂垫坠堕坟坛压垒坏壮壶寿够梦伙奥夺奋娱妇妈婴孙学宫实宁审写宽宠宝将专寻对导尬届属冈岛峡岚岭巅师带币帮干几库厂废广厅张强弹汇后从复征彻恶恼爱态庆欲怜凭愤宪忆应怀悬恋战戏户卷扫采扬换挥损摇扑击拟扩摄败叙敌数断于时历晓书会东条枫业极构枪乐楼标样机横档樱欧欢历归残杀毁气决况凉净减准温灭滚汉洁潜泽湾灾为无炼热争爷尔狱奖独猎兽献现玛环产画异当叠疗发尽监盘众确礼种称稳穷竞笔范筑简篮纪约红纹纳纽纯纸级纷细终组结绝给统丝经维网紧线缘编缓练缩纵总织绕绘系继续罗义习圣联聪声职听脑脸临台与兴举舰庄华莱万苍莲萨蓝药苏兰处号虫术卫冲里装里制复袭见规视亲觉览观计讯讨训记设许诉诊证评词试诗话该详语误说谁课调谈请论谍诸证识译议护变让赞负财贡贫货贩贪责贵买费贴贸贺资赏贤卖赋质赖赚赛赠赞赢赶赵迹践跃躯车轨军轩软载轻辆辉辈轮辑输转轿辞农回这连周进游运过达违遥逊远适迟迁选遗迈还边逻邮乡邻医释针钓铃银铜锯钢录钱锦错炼锅键锁镇链镜钟铁鉴长门闪闭开闰闲间阁阀阅阎斗关阵阴阳队阶际随险隐只虽双杂鸡离难云电雾灵静韩响页顶项顺须预领头频题额颜愿类顾显风飘飞饥饭饮饲饱饰养余馆马驻骑骗骚驱验惊体发松斗闹郁鱼鲁鲜鲤鲸鸟凤鸣鸿鹅鹤鹰丽麦面黄点党齐齿龄龙龟叶';

  static const List<String> _romanFolded = [
    'i',
    'ii',
    'iii',
    'iv',
    'v',
    'vi',
    'vii',
    'viii',
    'ix',
    'x',
    'xi',
    'xii',
  ];

  static const String _halfwidthBaseHiragana =
      'をぁぃぅぇぉゃゅょっーあいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわん';

  static final Map<int, int> _tradToSimp = Map<int, int>.unmodifiable(
    _buildTradToSimpMap(),
  );

  static Map<int, int> _buildTradToSimpMap() {
    final tradRunes = _traditionalChars.runes.toList(growable: false);
    final simpRunes = _simplifiedChars.runes.toList(growable: false);
    assert(tradRunes.length == simpRunes.length);
    return <int, int>{
      for (var i = 0; i < tradRunes.length; i++) tradRunes[i]: simpRunes[i],
    };
  }

  /// 将高频繁体汉字转换为对应简体汉字，同时完整保留 ASCII 字母大小写、
  /// 日语假名及原有标点结构。
  static String toSimplified(String input) {
    if (input.isEmpty) return input;
    var changed = false;
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      final mapped = _tradToSimp[rune];
      if (mapped != null) {
        changed = true;
        buffer.writeCharCode(mapped);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return changed ? buffer.toString() : input;
  }

  /// 将全角字符、乘号（`×`/`✕`/`✖`）、Unicode 罗马数字（`Ⅰ..Ⅻ`）、
  /// 日语片假名（含半角片假名及长音符）以及繁体中文统一折叠为规范小写比较形式，
  /// 适用于跨文字体系的模糊及精确片名比对。
  /// 屏蔽全半角与平片假名写法差异。
  static String fold(String input) {
    final len = input.length;
    if (len == 0) return '';
    // 检测是否含非 BMP 代理对；常规片名均落入 BMP，可直接按 UTF-16 码元单趟扫描避免 runes 列表分配。
    var hasSurrogate = false;
    for (var i = 0; i < len; i++) {
      final u = input.codeUnitAt(i);
      if (u >= 0xD800 && u <= 0xDFFF) {
        hasSurrogate = true;
        break;
      }
    }
    if (hasSurrogate) {
      return _foldRunes(input.runes.toList(growable: false));
    }

    final buffer = StringBuffer();
    var lastWasProlonged = false;
    var pendingSpace = false;

    void writeSpace() {
      if (buffer.isNotEmpty) pendingSpace = true;
    }

    void flushSpace() {
      if (pendingSpace) {
        buffer.writeCharCode(0x20);
        pendingSpace = false;
      }
    }

    for (var i = 0; i < len; i++) {
      final rune = input.codeUnitAt(i);
      if (rune == 0x20 ||
          rune == 0x09 ||
          rune == 0x0A ||
          rune == 0x0D ||
          rune == 0x0C ||
          rune == 0x0B ||
          rune == 0x3000 ||
          rune == 0x00A0) {
        lastWasProlonged = false;
        writeSpace();
        continue;
      }
      if (rune >= 0x41 && rune <= 0x5A) {
        lastWasProlonged = false;
        flushSpace();
        buffer.writeCharCode(rune + 32);
        continue;
      }
      if (rune < 0x80) {
        lastWasProlonged = false;
        flushSpace();
        buffer.writeCharCode(rune);
        continue;
      }
      if (rune >= 0xFF01 && rune <= 0xFF5E) {
        lastWasProlonged = false;
        final half = rune - 0xFEE0;
        if (_isMultiplier(half)) {
          writeSpace();
          flushSpace();
          buffer.writeCharCode(0x78);
          writeSpace();
        } else {
          flushSpace();
          buffer.writeCharCode(
            half >= 0x41 && half <= 0x5A ? half + 32 : half,
          );
        }
        continue;
      }
      if (_isMultiplier(rune)) {
        lastWasProlonged = false;
        writeSpace();
        flushSpace();
        buffer.writeCharCode(0x78);
        writeSpace();
        continue;
      }
      if (rune >= 0x2160 && rune <= 0x216B) {
        lastWasProlonged = false;
        flushSpace();
        buffer.write(_romanFolded[rune - 0x2160]);
        continue;
      }
      if (rune >= 0x2170 && rune <= 0x217B) {
        lastWasProlonged = false;
        flushSpace();
        buffer.write(_romanFolded[rune - 0x2170]);
        continue;
      }
      if (rune == 0x30FC || rune == 0xFF70) {
        if (!lastWasProlonged) {
          flushSpace();
          buffer.writeCharCode(0x30FC);
          lastWasProlonged = true;
        }
        continue;
      }
      if (rune >= 0xFF66 && rune <= 0xFF9D) {
        lastWasProlonged = false;
        flushSpace();
        final next = i + 1 < len ? input.codeUnitAt(i + 1) : 0;
        final voiced = _combineHalfwidthKatakana(rune, next);
        if (voiced != null) {
          buffer.write(voiced);
          i++;
        } else {
          buffer.write(_halfwidthBaseHiragana[rune - 0xFF66]);
        }
        continue;
      }
      if (rune == 0xFF9E || rune == 0xFF9F) {
        // 未附着在可转换基础假名之后的孤立半角浊音/半浊音符号直接折叠剔除。
        continue;
      }

      lastWasProlonged = false;
      flushSpace();
      if (rune >= 0x30A1 && rune <= 0x30F6) {
        buffer.writeCharCode(rune - 0x60);
      } else if (rune == 0x30FD || rune == 0x30FE) {
        buffer.writeCharCode(rune - 0x60);
      } else if (rune >= 0x00C0 && rune <= 0x024F ||
          (rune >= 0x0370 && rune <= 0x052F)) {
        // 含拉丁扩展/希腊/西里尔大小写字符时交由标准小写转换确保等价。
        buffer.write(String.fromCharCode(rune).toLowerCase());
      } else {
        buffer.writeCharCode(_tradToSimp[rune] ?? rune);
      }
    }

    return buffer.toString();
  }

  static String _foldRunes(List<int> runes) {
    final buffer = StringBuffer();
    var lastWasProlonged = false;

    for (var i = 0; i < runes.length; i++) {
      final rune = runes[i];
      if (rune >= 0xFF01 && rune <= 0xFF5E) {
        lastWasProlonged = false;
        final half = rune - 0xFEE0;
        if (_isMultiplier(half)) {
          buffer.write(' x ');
        } else {
          buffer.writeCharCode(half);
        }
        continue;
      }
      if (rune == 0x3000) {
        lastWasProlonged = false;
        buffer.write(' ');
        continue;
      }
      if (_isMultiplier(rune)) {
        lastWasProlonged = false;
        buffer.write(' x ');
        continue;
      }
      if (rune >= 0x2160 && rune <= 0x216B) {
        lastWasProlonged = false;
        buffer.write(_romanFolded[rune - 0x2160]);
        continue;
      }
      if (rune >= 0x2170 && rune <= 0x217B) {
        lastWasProlonged = false;
        buffer.write(_romanFolded[rune - 0x2170]);
        continue;
      }
      if (rune == 0x30FC || rune == 0xFF70) {
        if (!lastWasProlonged) {
          buffer.write('ー');
          lastWasProlonged = true;
        }
        continue;
      }
      if (rune >= 0xFF66 && rune <= 0xFF9D) {
        lastWasProlonged = false;
        final next = i + 1 < runes.length ? runes[i + 1] : 0;
        final voiced = _combineHalfwidthKatakana(rune, next);
        if (voiced != null) {
          buffer.write(voiced);
          i++;
        } else {
          buffer.write(_halfwidthBaseHiragana[rune - 0xFF66]);
        }
        continue;
      }
      if (rune == 0xFF9E || rune == 0xFF9F) {
        continue;
      }

      lastWasProlonged = false;
      if (rune >= 0x30A1 && rune <= 0x30F6) {
        buffer.writeCharCode(rune - 0x60);
      } else if (rune == 0x30FD || rune == 0x30FE) {
        buffer.writeCharCode(rune - 0x60);
      } else {
        buffer.writeCharCode(_tradToSimp[rune] ?? rune);
      }
    }

    return buffer
        .toString()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool _isMultiplier(int rune) =>
      rune == 0x00D7 || // ×
      rune == 0x2715 || // ✕
      rune == 0x2716 || // ✖
      rune == 0x2A2F; // ⨯

  static String? _combineHalfwidthKatakana(int base, int mark) {
    if (mark == 0xFF9E) {
      // 半角浊音符号（`ﾞ`）
      if (base == 0xFF73) return 'ゔ'; // ｳﾞ
      if (base >= 0xFF76 && base <= 0xFF84) {
        // 清音假名 `ｶ-ｺ`、`ｻ-ｿ`、`ﾀ-ﾄ` 对应平假名码位加 1 转浊音。
        final hira = _halfwidthBaseHiragana.codeUnitAt(base - 0xFF66);
        return String.fromCharCode(hira + 1);
      }
      if (base >= 0xFF8A && base <= 0xFF8E) {
        // `ﾊ-ﾎ` 对应平假名码位加 1 转为 `ば-ぼ`。
        final hira = _halfwidthBaseHiragana.codeUnitAt(base - 0xFF66);
        return String.fromCharCode(hira + 1);
      }
    } else if (mark == 0xFF9F && base >= 0xFF8A && base <= 0xFF8E) {
      // 半角半浊音符号（`ﾟ`）使 `ﾊ-ﾎ` 码位加 2 转为 `ぱ-ぽ`。
      final hira = _halfwidthBaseHiragana.codeUnitAt(base - 0xFF66);
      return String.fromCharCode(hira + 2);
    }
    return null;
  }

  static final RegExp _kanaPattern = RegExp(r'[\u3040-\u30ff\uff65-\uff9f]');

  static bool containsKana(String input) => _kanaPattern.hasMatch(input);

  static const Map<String, String> _digraphKana = {
    'きゃ': 'kya', 'きゅ': 'kyu', 'きょ': 'kyo',
    'ぎゃ': 'gya', 'ぎゅ': 'gyu', 'ぎょ': 'gyo',
    'しゃ': 'sha', 'しゅ': 'shu', 'しょ': 'sho', 'しぇ': 'she',
    'じゃ': 'ja', 'じゅ': 'ju', 'じょ': 'jo', 'じぇ': 'je',
    'ちゃ': 'cha', 'ちゅ': 'chu', 'ちょ': 'cho', 'ちぇ': 'che',
    'にゃ': 'nya', 'にゅ': 'nyu', 'にょ': 'nyo',
    'ひゃ': 'hya', 'ひゅ': 'hyu', 'ひょ': 'hyo',
    'びゃ': 'bya', 'びゅ': 'byu', 'びょ': 'byo',
    'ぴゃ': 'pya', 'ぴゅ': 'pyu', 'ぴょ': 'pyo',
    'みゃ': 'mya', 'みゅ': 'myu', 'みょ': 'myo',
    'りゃ': 'rya', 'りゅ': 'ryu', 'りょ': 'ryo',
    'ふぁ': 'fa', 'ふぃ': 'fi', 'ふぇ': 'fe', 'ふぉ': 'fo', 'ふゅ': 'fyu',
    'てぃ': 'ti', 'でぃ': 'di', 'とぅ': 'tu', 'どぅ': 'du',
    'うぃ': 'wi', 'うぇ': 'we', 'うぉ': 'wo',
    'ゔぁ': 'va', 'ゔぃ': 'vi', 'ゔぇ': 've', 'ゔぉ': 'vo',
    'ちぃ': 'chi', 'じぃ': 'ji', 'しぃ': 'shi', 'きぃ': 'kyi',
    'つぁ': 'tsa', 'つぃ': 'tsi', 'つぇ': 'tse', 'つぉ': 'tso',
  };

  static const Map<String, String> _monographKana = {
    'あ': 'a', 'い': 'i', 'う': 'u', 'え': 'e', 'お': 'o',
    'ぁ': 'a', 'ぃ': 'i', 'ぅ': 'u', 'ぇ': 'e', 'ぉ': 'o',
    'か': 'ka', 'き': 'ki', 'く': 'ku', 'け': 'ke', 'こ': 'ko',
    'が': 'ga', 'ぎ': 'gi', 'ぐ': 'gu', 'げ': 'ge', 'ご': 'go',
    'さ': 'sa', 'し': 'shi', 'す': 'su', 'せ': 'se', 'そ': 'so',
    'ざ': 'za', 'じ': 'ji', 'ず': 'zu', 'ぜ': 'ze', 'ぞ': 'zo',
    'た': 'ta', 'ち': 'chi', 'つ': 'tsu', 'て': 'te', 'と': 'to',
    'だ': 'da', 'ぢ': 'ji', 'づ': 'zu', 'で': 'de', 'ど': 'do',
    'な': 'na', 'に': 'ni', 'ぬ': 'nu', 'ね': 'ne', 'の': 'no',
    'は': 'ha', 'ひ': 'hi', 'ふ': 'fu', 'へ': 'he', 'ほ': 'ho',
    'ば': 'ba', 'び': 'bi', 'ぶ': 'bu', 'べ': 'be', 'ぼ': 'bo',
    'ぱ': 'pa', 'ぴ': 'pi', 'ぷ': 'pu', 'ぺ': 'pe', 'ぽ': 'po',
    'ま': 'ma', 'み': 'mi', 'む': 'mu', 'め': 'me', 'も': 'mo',
    'や': 'ya', 'ゆ': 'yu', 'よ': 'yo',
    'ゃ': 'ya', 'ゅ': 'yu', 'ょ': 'yo',
    'ら': 'ra', 'り': 'ri', 'る': 'ru', 'れ': 're', 'ろ': 'ro',
    'わ': 'wa', 'ゐ': 'wi', 'ゑ': 'we', 'を': 'wo', 'ん': 'n',
    'ゔ': 'v', 'ー': '',
  };

  static bool _isHiraganaCode(int rune) => rune >= 0x3041 && rune <= 0x309F || rune == 0x30FC;

  /// 将字符串 [input] 中的连续日语假名音译为 ASCII 罗马音，
  /// 同时保留拉丁字符并在文字切换边界自动补齐空格分词。
  static String kanaToRomaji(String input) {
    if (!containsKana(input)) return input;
    final folded = fold(input);
    final out = StringBuffer();
    var i = 0;
    var prevWasKana = false;
    while (i < folded.length) {
      final ch = folded[i];
      if (ch == 'っ') {
        if (i + 1 < folded.length) {
          final next = folded.substring(i + 1, i + 2);
          final nextRomaji = _monographKana[next];
          if (nextRomaji != null && nextRomaji.isNotEmpty) {
            final c = nextRomaji[0];
            if (!'aeiouy'.contains(c)) out.write(c);
          }
        }
        prevWasKana = true;
        i++;
        continue;
      }
      final two = i + 1 < folded.length ? folded.substring(i, i + 2) : null;
      final di = two == null ? null : _digraphKana[two];
      if (di != null) {
        if (!prevWasKana && out.isNotEmpty && folded[i - 1] != ' ') {
          // 当紧邻前驱为非空白字符时，在混合文字边界插入空格分隔。
          out.write(' ');
        }
        out.write(di);
        prevWasKana = true;
        i += 2;
        continue;
      }
      final mono = _monographKana[ch];
      if (mono != null) {
        if (!prevWasKana && out.isNotEmpty && folded[i - 1] != ' ') {
          out.write(' ');
        }
        out.write(mono);
        prevWasKana = true;
        i++;
        continue;
      }
      if (prevWasKana && ch != ' ' && !_isHiraganaCode(ch.codeUnitAt(0))) {
        out.write(' ');
      }
      prevWasKana = false;
      out.write(ch);
      i++;
    }
    return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 将英语外来词拼写与日语罗马音折叠至统一语音近音形式
  ///（如将 `igh->ai`、`ph->f`、`l->r`、`v->b`、`y->i` 规范化等价）。
  static String phoneticLatinFold(String input) {
    var s = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (s.isEmpty) return '';
    s = s
        .replaceAll('igh', 'ai')
        .replaceAll('ear', 'ar')
        .replaceAll('ee', 'i')
        .replaceAll('oo', 'u')
        .replaceAll('ph', 'f')
        .replaceAll('qu', 'ku')
        .replaceAll('th', 's')
        .replaceAllMapped(RegExp(r'c(?=[eiy])'), (_) => 's')
        .replaceAll('c', 'k')
        .replaceAll('l', 'r')
        .replaceAll('v', 'b')
        .replaceAll('y', 'i')
        .replaceAllMapped(RegExp(r'([a-z])\1+'), (m) => m.group(1)!);
    return s;
  }

  /// 在执行 `[phoneticLatinFold]` 后提取辅音骨架并可选保留首元音特征。
  static String phoneticSkeleton(String input) {
    final f = phoneticLatinFold(input);
    if (f.isEmpty) return '';
    final out = StringBuffer(f[0]);
    for (var i = 1; i < f.length; i++) {
      final ch = f[i];
      if (ch == 'a' || ch == 'e' || ch == 'i' || ch == 'o' || ch == 'u' || ch == 'y') {
        continue;
      }
      if (out.isNotEmpty && out.toString().codeUnitAt(out.length - 1) == ch.codeUnitAt(0)) {
        continue;
      }
      out.write(ch);
    }
    return out.toString();
  }

  /// 判定本地标题或文件名拉丁词元 `[token]` 是否能由音译罗马音组件在语音上覆盖。
  /// 用于跨日文假名与英文字母拼写的召回率补足。
  static bool phoneticTokenCovered(
    String token, {
    required String romajiFolded,
    required String romajiSkeleton,
    required List<String> romajiWords,
  }) {
    if (romajiFolded.isEmpty) return false;
    final ft = phoneticLatinFold(token);
    if (ft.length < 3) return false;
    if (romajiFolded.contains(ft)) return true;
    // 英语短元音 `u` 在日语片假名外来词中普遍音译为 `a`（如 `fun->ファン`、`love/club/cut/sun`）。
    if (ft.contains('u') && romajiFolded.contains(ft.replaceAll('u', 'a'))) {
      return true;
    }
    if (ft.length >= 5 && romajiFolded.contains(ft.substring(0, 4))) return true;
    final st = phoneticSkeleton(token);
    if (st.length >= 3 && romajiSkeleton.contains(st)) return true;
    for (final w in romajiWords) {
      final fw = phoneticLatinFold(w);
      final sw = phoneticSkeleton(w);
      if (st.length >= 3 && sw == st) return true;
      final minLen = ft.length < fw.length ? ft.length : fw.length;
      final maxLen = ft.length > fw.length ? ft.length : fw.length;
      if (ft.length >= 5 &&
          fw.length >= 4 &&
          (ft.length - fw.length).abs() <= 3) {
        final lcs = _longestCommonSubseqLen(ft, fw);
        final minRequired = minLen <= 4 ? minLen : minLen - 1;
        if (lcs >= minRequired && lcs * 100 >= maxLen * 65) {
          return true;
        }
      }
    }
    return false;
  }

  static double _bigramDice(String a, String b) {
    if (a.length < 2 || b.length < 2) return 0;
    if (a == b) return 1;
    final grams = <int, int>{};
    for (var i = 0; i < a.length - 1; i++) {
      final g = (a.codeUnitAt(i) << 16) | a.codeUnitAt(i + 1);
      grams[g] = (grams[g] ?? 0) + 1;
    }
    var shared = 0;
    for (var i = 0; i < b.length - 1; i++) {
      final g = (b.codeUnitAt(i) << 16) | b.codeUnitAt(i + 1);
      final left = grams[g];
      if (left != null && left > 0) {
        shared++;
        grams[g] = left - 1;
      }
    }
    return 2 * shared / (a.length + b.length - 2);
  }

  /// 预编译含假名远程标题的语音特征，供多提示比对复用，避免重复假名音译。
  static PreparedKanaTarget? prepareKanaTarget(String remoteRaw) {
    if (!containsKana(remoteRaw)) return null;
    final romaji = kanaToRomaji(remoteRaw);
    final romajiWords = RegExp(r'[a-z0-9]{3,}')
        .allMatches(romaji.toLowerCase())
        .map((m) => m.group(0)!)
        .toList(growable: false);
    if (romajiWords.isEmpty) return null;
    final kanaLatin = romajiWords.join(' ');
    final romajiFolded = phoneticLatinFold(kanaLatin);
    if (romajiFolded.length < 6) return null;
    final romajiSkeleton = phoneticSkeleton(kanaLatin);
    final wordFolds = [
      for (final w in romajiWords)
        (
          word: w,
          folded: phoneticLatinFold(w),
          skeleton: phoneticSkeleton(w),
        ),
    ];
    return PreparedKanaTarget._(
      romajiWords: romajiWords,
      romajiFolded: romajiFolded,
      romajiSkeleton: romajiSkeleton,
      wordFolds: wordFolds,
    );
  }

  /// 预编译纯拉丁本地提示的语音特征，供与多条远程假名别名快速比对。
  static PreparedLocalAscii? prepareLocalAscii(String localAscii) {
    if (RegExp(r'[\u3040-\u9fff]').hasMatch(localAscii)) return null;
    final localTokens = RegExp(r'[a-z0-9]{3,}')
        .allMatches(localAscii.toLowerCase())
        .map((m) => m.group(0)!)
        .toList(growable: false);
    if (localTokens.length < 2) return null;
    final localFolded = phoneticLatinFold(localAscii);
    if (localFolded.length < 6) return null;
    final localSkeleton = phoneticSkeleton(localAscii);
    return PreparedLocalAscii._(
      tokens: localTokens,
      folded: localFolded,
      skeleton: localSkeleton,
    );
  }

  /// 使用预编译特征计算拉丁提示与假名远程片名之间的跨语种语音相似度（`0..0.88`）。
  static double romajiKanaSimilarityPrepared(
    PreparedLocalAscii local,
    PreparedKanaTarget target,
  ) {
    final localTokens = local.tokens;
    var covered = 0;
    for (final token in localTokens) {
      if (phoneticTokenCovered(
        token,
        romajiFolded: target.romajiFolded,
        romajiSkeleton: target.romajiSkeleton,
        romajiWords: target.romajiWords,
      )) {
        covered++;
      }
    }
    final localRatio = covered / localTokens.length;
    if (covered < 2 || localRatio < 0.35) return 0;

    var remoteCovered = 0;
    var uncoveredDistinctiveRemote = 0;
    var coveredKanaChars = 0;
    var totalKanaChars = 0;
    for (final wfItem in target.wordFolds) {
      totalKanaChars += wfItem.folded.length;
      final hit = localTokens.any(
        (lt) => phoneticTokenCovered(
          lt,
          romajiFolded: wfItem.folded,
          romajiSkeleton: wfItem.skeleton,
          romajiWords: [wfItem.word],
        ),
      );
      if (hit) {
        remoteCovered++;
        coveredKanaChars += wfItem.folded.length;
      } else if (wfItem.folded.length >= 4) {
        uncoveredDistinctiveRemote++;
      }
    }
    final remoteRatio = remoteCovered / target.romajiWords.length;
    if (remoteCovered < 2 && target.romajiWords.length >= 2) return 0;

    final foldDice = _bigramDice(local.folded, target.romajiFolded);
    final skelDice = _bigramDice(local.skeleton, target.romajiSkeleton);
    final alignment = localRatio * 0.6 + remoteRatio * 0.4;
    var score =
        0.48 +
        0.24 * alignment +
        0.22 * (skelDice > foldDice ? skelDice : foldDice);
    // 当远程片名包含本地未覆盖的显著假名副标题词时按未覆盖数衰减，避免同系列兄弟作（如两部特别篇）
    // 仅凭共享主标题假名互相抵消分差；若已覆盖 >= 4 个拉丁词且覆盖 >= 65% 假名音长（仅余 1 处
    // 外来语片假名拼写差异如 `ツインエンジェル`），则免除单段惩罚；假名全覆盖且覆盖度高时给予微增。
    final dominantKanaCoverage =
        uncoveredDistinctiveRemote == 1 &&
        covered >= 4 &&
        remoteCovered >= 2 &&
        totalKanaChars > 0 &&
        coveredKanaChars * 100 >= totalKanaChars * 65;
    if (uncoveredDistinctiveRemote > 0 &&
        remoteRatio < 0.70 &&
        !dominantKanaCoverage) {
      score -= 0.14 * uncoveredDistinctiveRemote;
      if (score < 0) score = 0;
    } else if (uncoveredDistinctiveRemote == 0 &&
        remoteRatio >= 0.90 &&
        localRatio >= 0.45 &&
        covered >= 4) {
      score += 0.11;
    }
    return score > 0.88 ? 0.88 : score;
  }

  /// 估算纯 ASCII/罗马音本地片名与含日语假名远程片名之间的跨语种语音相似度
  /// （取值区间 `0..0.88`）。
  static double romajiKanaSimilarity(String localAscii, String remoteRaw) {
    final target = prepareKanaTarget(remoteRaw);
    if (target == null) return 0;
    final local = prepareLocalAscii(localAscii);
    if (local == null) return 0;
    return romajiKanaSimilarityPrepared(local, target);
  }

  static int _longestCommonSubseqLen(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final dp = List<int>.filled(b.length + 1, 0);
    for (var i = 0; i < a.length; i++) {
      var prev = 0;
      for (var j = 0; j < b.length; j++) {
        final temp = dp[j + 1];
        if (a.codeUnitAt(i) == b.codeUnitAt(j)) {
          dp[j + 1] = prev + 1;
        } else if (dp[j] > dp[j + 1]) {
          dp[j + 1] = dp[j];
        }
        prev = temp;
      }
    }
    return dp[b.length];
  }
}

/// 预编译的远程含假名标题语音特征（供跨提示比对复用）。
class PreparedKanaTarget {
  const PreparedKanaTarget._({
    required this.romajiWords,
    required this.romajiFolded,
    required this.romajiSkeleton,
    required this.wordFolds,
  });

  final List<String> romajiWords;
  final String romajiFolded;
  final String romajiSkeleton;
  final List<({String word, String folded, String skeleton})> wordFolds;
}

/// 预编译的本地纯拉丁标题语音特征（供与多条假名别名比对复用）。
class PreparedLocalAscii {
  const PreparedLocalAscii._({
    required this.tokens,
    required this.folded,
    required this.skeleton,
  });

  final List<String> tokens;
  final String folded;
  final String skeleton;
}
