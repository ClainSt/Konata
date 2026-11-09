// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get settings => '设置';

  @override
  String get appearance => '外观';

  @override
  String get scraping => '刮削服务';

  @override
  String get about => '关于';

  @override
  String get recordsSync => '记录与同步';

  @override
  String get language => '语言';

  @override
  String get library => '媒体库';

  @override
  String get sources => '媒体源';

  @override
  String get closeSettings => '关闭设置';

  @override
  String get backSettings => '返回设置';

  @override
  String get followSystem => '跟随系统';

  @override
  String get interfaceLanguage => '界面语言';

  @override
  String get languageSaveFailed => '语言设置保存失败，请重试';

  @override
  String get languageDescription => '界面语言与刮削资料语言独立管理。部分页面的翻译仍在完善中。';

  @override
  String get dayMode => '日间模式';

  @override
  String get nightMode => '夜间模式';

  @override
  String get themeMode => '主题模式';

  @override
  String get themeDescription => '选择应用界面的颜色主题';

  @override
  String get themeSaveFailed => '主题设置保存失败，请重试';

  @override
  String get accent => '主题色';

  @override
  String get accentDescription => '选择应用界面的强调色';

  @override
  String get accentSaveFailed => '主题色保存失败，请重试';

  @override
  String get red => '红色';

  @override
  String get pink => '粉色';

  @override
  String get lightBlue => '浅蓝色';

  @override
  String get switchLight => '切换到日间模式';

  @override
  String get switchDark => '切换到夜间模式';

  @override
  String get tmdbSettings => 'TMDB API 设置';

  @override
  String get credentialsConfigured => '已配置 · 支持访问令牌 / API Key';

  @override
  String get credentialsMissing => '未配置 · 设置访问令牌或 API Key';

  @override
  String get metadataServicesDescription => 'TMDB / Bangumi API、图片地址与独立连接测试';

  @override
  String get tmdbIdGuide => 'TMDB ID 增强识别';

  @override
  String get history => '播放记录';

  @override
  String get historyDescription => '查看续播位置、管理本地已看状态';

  @override
  String get historyFailed => '播放记录操作失败，请重试';

  @override
  String get clearHistoryQuestion => '清空播放记录？';

  @override
  String get removeHistoryQuestion => '删除这条播放记录？';

  @override
  String get removeHistoryDescription => '将移除续播位置和播放记录。媒体文件及作品绑定会保留。';

  @override
  String get cancel => '取消';

  @override
  String get confirmDelete => '确认删除';

  @override
  String get playFailed => '无法打开该媒体，请检查媒体源是否可用';

  @override
  String get refreshHistory => '刷新播放记录';

  @override
  String get clearHistory => '清空播放记录';

  @override
  String get readHistoryFailed => '读取播放记录失败';

  @override
  String get retry => '重试';

  @override
  String get noHistory => '暂无播放记录';

  @override
  String get unknownWork => '未知作品';

  @override
  String get watched => '已看';

  @override
  String get watching => '观看中';

  @override
  String get manageHistory => '管理播放记录';

  @override
  String get markUnwatched => '标记为未看';

  @override
  String get markWatched => '标记为已看';

  @override
  String get deleteRecord => '删除记录';

  @override
  String get enableLogs => '详细调试日志';

  @override
  String get logsDescription => '平时保留异常和必要的播放记录；复现问题前开启，可补充详细信息。';

  @override
  String get logsSaveFailed => '日志设置保存失败';

  @override
  String get openLogs => '打开日志目录';

  @override
  String get exportLogsSystem => '仅导出最近一次异常前后的 TXT 文本记录';

  @override
  String get logsDefaultPath => '应用数据目录 / logs';

  @override
  String get versionLabel => '版本 1.0.0';

  @override
  String get noLogs => '当前没有可导出的异常记录';

  @override
  String get exportLogs => '导出最近异常日志';

  @override
  String get logsAccessFailed => '无法访问日志目录，请检查系统文件应用';

  @override
  String get chooseVersion => '选择播放版本';

  @override
  String get closeVersion => '关闭版本选择';

  @override
  String get filenameHints => '技术信息来自文件名标记，仅供参考；未标明的音轨和字幕需在播放时确认。';

  @override
  String get unknownSource => '未知媒体源';

  @override
  String get unnamedSource => '未命名媒体源';

  @override
  String get releaseTag => '发布标记（未分类）';

  @override
  String get encoderTag => '压制组标记';

  @override
  String get subtitleGroupTag => '字幕组标记';

  @override
  String get sourceLabel => '媒体源';

  @override
  String get minimize => '最小化';

  @override
  String get maximize => '最大化';

  @override
  String get restoreWindow => '还原窗口';

  @override
  String get closeWindow => '关闭';

  @override
  String get apiGuideTitle => '如何获取 TMDB API';

  @override
  String get apiGuideBody =>
      '1. 打开 https://www.themoviedb.org/，注册或登录账号。\n\n2. 进入账户设置，找到 API 页面。建议在电脑浏览器中申请，手机页面可能不便操作。\n\n3. 按官方要求填写申请资料并同意使用条款。请根据实际用途如实填写。\n\n4. 获得凭据后，回到 Konata 的 TMDB API 设置。\n\n5. 选择“访问令牌”时，填写 API Read Access Token；选择“API Key”时，填写 API Key。两种凭据不能混用。\n\n6. 点击“测试连接”，验证成功后保存。凭据保存在系统安全存储中，请勿公开分享。\n\n账户 API 页面：https://www.themoviedb.org/settings/api';

  @override
  String get openApiPage => '打开 TMDB API 页面';

  @override
  String get gotIt => '知道了';

  @override
  String get browserCopyFailed => '无法打开浏览器，请复制下方网址手动访问';

  @override
  String get githubOpenFailed =>
      '无法打开浏览器，请访问 https://github.com/ClainSt/Konata';

  @override
  String get subtitleSimplified => '简体中文';

  @override
  String get subtitleTraditional => '繁体中文';

  @override
  String get subtitleBilingual => '中日字幕标记';

  @override
  String get subtitleAss => 'ASS 标记';

  @override
  String get subtitlePgs => 'PGS 标记';

  @override
  String get authMethod => 'TMDB 认证方式';

  @override
  String get accessToken => '访问令牌';

  @override
  String get closeTmdb => '关闭 TMDB 设置';

  @override
  String get enterCredentials => '请先填写所选认证方式的凭证';

  @override
  String get connectionOk => 'TMDB 连接验证成功';

  @override
  String get credentialTestFailed => '验证失败，请检查凭证和网络后重试';

  @override
  String get credentialSaveFailed => '凭据保存失败，请重试';

  @override
  String get secureCredentials => '保存在系统安全存储；两种凭证分别保存，可随时切换';

  @override
  String get metadataProviders => '元数据来源仅使用 TMDB 和 Bangumi，后者的公开搜索不需要此凭证。';

  @override
  String get testConnection => '测试连接';

  @override
  String get save => '保存';

  @override
  String get closeIdGuide => '关闭识别说明';

  @override
  String get idIntroTitle => '通过 TMDB ID 定位作品';

  @override
  String get idIntroBody =>
      '在作品文件夹名称中加入 TMDB ID，Konata 扫描时会优先按 ID 获取作品资料，减少同名作品或译名不同带来的匹配偏差。此能力默认生效，无需另开开关。';

  @override
  String get idFormatsTitle => '支持的命名格式';

  @override
  String idFormats(
    String standard,
    String alternate,
    String brackets,
    String movie,
  ) {
    return '推荐：$standard\n也支持：$alternate、$brackets\n标记不区分大小写，请保留花括号或方括号。电影可使用 $movie 明确类型。';
  }

  @override
  String get idExampleTitle => '目录示例';

  @override
  String idExample(String path) {
    return '$path\n\n建议将标记放在作品文件夹，而不是合集目录。不同作品分别放入各自的作品文件夹。';
  }

  @override
  String get idStepsTitle => '如何使用';

  @override
  String get idSteps =>
      '1. 在 TMDB 作品页面的网址中找到数字 ID，确认作品与类型正确。\n2. 自行在作品文件夹名称中加入标记。Konata 不会替你修改本地或云盘文件。\n3. 在媒体源中重新扫描对应目录，获取作品资料。已有作品也可在详情页使用“搜索并绑定作品”手动修正。';

  @override
  String get idNotesTitle => '识别时请注意';

  @override
  String get idNotes =>
      '• TMDB 凭证与 API 服务需要可用；填入 ID 不代表网络请求一定成功。\n• 集数建议使用 S01E01 等季集标记；特别篇可用 S00E01。作品 ID 仅定位作品，不替代季集识别。\n• 年份若填写，建议与 TMDB 条目一致；不确定时可以省略。\n• 人工锁定的作品资料与手动封面不会被自动刮削覆盖。\n• 无对应 TMDB 条目或信息不完整时，可在详情页手动确认绑定，不保证所有资源自动识别。';

  @override
  String get autoWatched => '自动标记已看';

  @override
  String get autoWatchedDescription =>
      '实际观看内容达到此比例时自动标记已看。跳转、暂停和重复观看不会额外累计；手动已看或未看状态优先。';

  @override
  String get watchSettingsSaveFailed => '观看设置保存失败，请重试';

  @override
  String get progressSaveFailed => '播放记录保存失败，将继续重试';

  @override
  String get apiAddress => 'API 地址';

  @override
  String get imageAddress => '图片服务器地址';

  @override
  String get testApi => 'API 连接测试';

  @override
  String get testImages => '图片服务器连接测试';

  @override
  String get connectionDetails => '连接详情';

  @override
  String get resetDefaults => '恢复默认';

  @override
  String get officialServers => '官方标准地址';

  @override
  String get closeMetadata => '关闭元数据服务设置';

  @override
  String get serverNotice =>
      '分别配置 API 与图片服务。Bangumi 默认使用非官方社区镜像；HTTP 地址会明文传输数据。';

  @override
  String get videoOutputRecovered => '画面输出已恢复。';

  @override
  String get autoFallback => '自动故障回退';

  @override
  String get fallbackDescription => '仅正式请求使用备用服务；连接测试始终使用当前输入地址';

  @override
  String get allowCustomCredentials => '允许向自定义 HTTPS TMDB 服务发送凭证';

  @override
  String get notTested => '未测试';

  @override
  String get testing => '测试中';

  @override
  String get serverConnected => '连接成功';

  @override
  String get connectionPartial => '部分功能异常';

  @override
  String get serverSaveFailed => '保存失败，请检查地址格式与存储权限';

  @override
  String get diagnosticCredentials => '请先设置 TMDB 凭证';

  @override
  String get diagnosticAuth => '认证失败，请检查凭证';

  @override
  String get diagnosticTimeout => '网络超时';

  @override
  String get diagnosticTls => 'TLS 连接失败';

  @override
  String get diagnosticNetwork => '网络连接失败';

  @override
  String get diagnosticInvalid => '地址、JSON 或图片无效';

  @override
  String get diagnosticHttp => '服务器返回错误';

  @override
  String get diagnosticFailed => '连接失败，请检查地址和访问授权';

  @override
  String get audioTracks => '音轨';

  @override
  String get subtitles => '字幕';

  @override
  String get chooseSubtitles => '选择字幕';

  @override
  String get chooseAudio => '选择音轨';

  @override
  String get subtitlesOff => '关闭字幕';

  @override
  String get trackAuto => '自动选择';

  @override
  String get rewind10 => '后退 10 秒';

  @override
  String get forward10 => '前进 10 秒';

  @override
  String get play => '播放';

  @override
  String get pause => '暂停';

  @override
  String get playbackFailed => '无法播放，请检查媒体文件和媒体源';

  @override
  String get audioOff => '关闭音轨';

  @override
  String get trackSwitchFailed => '音轨或字幕切换失败，请重试';

  @override
  String get addMedia => '添加媒体';

  @override
  String get localMedia => '本地媒体';

  @override
  String get networkMedia => '网络媒体';

  @override
  String get localFolder => '本地文件夹';

  @override
  String get addLocalFolder => '添加本地媒体文件夹';

  @override
  String get addLocalTitle => '添加本地文件夹';

  @override
  String get addWebdav => '添加 WebDAV 服务器';

  @override
  String get addSmb => '添加 SMB 共享';

  @override
  String get editSource => '编辑媒体源';

  @override
  String get sourceName => '媒体源名称';

  @override
  String get smbUrl => 'SMB 共享地址';

  @override
  String get webdavUrl => 'WebDAV 根目录 URL';

  @override
  String get chooseFolder => '选择文件夹';

  @override
  String get chooseMediaFolder => '选择本地媒体文件夹';

  @override
  String get usernameOptional => '用户名（可留空）';

  @override
  String get newPassword => '新密码（可留空）';

  @override
  String get passwordWillClear => '保存后清除已有密码';

  @override
  String get keepPassword => '留空保留原密码；用户名和密码均留空表示匿名访问';

  @override
  String get undoClearPassword => '撤销清除密码';

  @override
  String get clearSavedPassword => '清除已保存密码';

  @override
  String get sourceFieldsRequired => '名称和地址不能为空';

  @override
  String get invalidWebdav => '请输入有效的 WebDAV 地址';

  @override
  String get invalidSmb => '请输入有效的 SMB 共享地址';

  @override
  String get anonymousCredentials => '匿名访问时请同时留空用户名和密码';

  @override
  String get changeSourceTitle => '确认更改媒体源地址';

  @override
  String get changeSourceBody => '作品、人工绑定、观看进度及源 ID 将保留。如果新目录不包含原文件，需要重新扫描。';

  @override
  String get confirmChange => '确认修改';

  @override
  String get sourceFolderMissing => '目录或共享路径不存在';

  @override
  String get sourcePermissionDenied => '没有访问权限，请检查目录权限';

  @override
  String get cancelScan => '取消扫描';

  @override
  String get scanCancelled => '扫描已取消';

  @override
  String get scanStopping => '正在完成当前操作并停止…';

  @override
  String get sourceTestFailed => '连接失败，请检查地址、凭据和网络';

  @override
  String get sourceSaveFailed => '媒体源保存失败，请重试';

  @override
  String get localAccessible => '本地目录可访问';

  @override
  String get localMissing => '本地目录不存在';

  @override
  String get sourceConnectHint => '连接后可手动选择需要扫描的文件夹。';

  @override
  String get connectionName => '连接名称（可选）';

  @override
  String get folderPickerHint => '点击添加后将打开系统文件夹选择器，可直接选择本地目录。';

  @override
  String get smbUrlHint => 'SMB 地址（smb://主机/共享目录）';

  @override
  String get usernameCreate => '用户名（可选）';

  @override
  String get smbUsername => '用户名（可选，支持 域\\用户名）';

  @override
  String get passwordOptional => '密码（可选）';

  @override
  String get showPassword => '显示密码';

  @override
  String get hidePassword => '隐藏密码';

  @override
  String get guestHint => '无需认证时，用户名和密码留空即可。';

  @override
  String get add => '添加';

  @override
  String get sourceAddFailed => '媒体源添加失败，请检查地址后重试';

  @override
  String get scanProgress => '扫描进度';

  @override
  String get folderSearch => '搜索当前文件夹（名称 / TMDB ID）';

  @override
  String get clearSearch => '清除搜索';

  @override
  String get folderReadFailed => '目录读取失败，请检查路径或连接后重试';

  @override
  String get parentFolder => '.. 返回上级';

  @override
  String get fileLabel => '文件';

  @override
  String get help => '帮助';

  @override
  String get chooseScanHelpTitle => '怎样选择刮削文件夹？';

  @override
  String get chooseScanHelp =>
      '勾选文件夹即可加入刮削范围。既能勾选单部作品，也能勾选包含多部作品的上级目录。软件扫描后自动判断作品归属，对不确定的作品标记待复核。点击文件夹名称仍然可以进入子目录。';

  @override
  String get scanFolders => '正在扫描文件夹';

  @override
  String get scanMetadata => '正在自动刮削 TMDB / Bangumi';

  @override
  String get scanComplete => '扫描及自动刮削已完成';

  @override
  String get scanFailed => '扫描或自动刮削遇到错误';

  @override
  String get noScan => '尚无扫描记录';

  @override
  String get noScanHint => '还没有扫描过这个媒体源，选择文件夹后即可查看进度。';

  @override
  String get scanScope => '本次选中的扫描范围（含子目录视频）';

  @override
  String get visitedFolders => '具体已访问目录（仅统计该目录内视频）';

  @override
  String get noFoldersRead => '尚未读取到目录';

  @override
  String get scanningShort => '扫描中';

  @override
  String sourceConnected(int count) {
    return '连接成功，返回 $count 项';
  }

  @override
  String browseSource(String name) {
    return '浏览目录 · $name';
  }

  @override
  String itemCount(int count) {
    return '$count 项';
  }

  @override
  String videoCount(int count) {
    return '$count 个视频';
  }

  @override
  String folderMatches(int found, int total) {
    return '匹配 $found / $total 项';
  }

  @override
  String selectedScanFolders(int count) {
    return '已选刮削范围（$count）';
  }

  @override
  String scanSelectedFolders(int count) {
    return '扫描已选目录（$count）';
  }

  @override
  String scannedFolderCount(int count) {
    return '已扫描目录：$count';
  }

  @override
  String indexedVideoCount(int count) {
    return '索引视频：$count';
  }

  @override
  String scanMetadataCount(int done, int total) {
    return '元数据：$done/$total';
  }

  @override
  String scanSummary(int matched, int review, int failed) {
    return '成功：$matched · 待复核：$review · 失败：$failed';
  }

  @override
  String currentScanFolder(String path) {
    return '当前目录：$path';
  }

  @override
  String get addSource => '添加媒体源';

  @override
  String get localDirectory => '本地目录';

  @override
  String get browseScanFolders => '浏览云盘或本地目录并选取刮削文件夹';

  @override
  String get remove => '移除';

  @override
  String get removeSourceTitle => '移除媒体源？';

  @override
  String get removeSourceBody => '仅清除索引，不删除源文件。';

  @override
  String get addSourceFirst => '请先添加媒体源';

  @override
  String get noMatchingTitles => '暂无匹配作品';

  @override
  String get searchTitles => '搜索作品';

  @override
  String get closeSearch => '关闭搜索';

  @override
  String get manageHidden => '管理已隐藏作品';

  @override
  String sourceCount(int count) {
    return '$count 个媒体源';
  }

  @override
  String workCount(int count) {
    return '$count 部作品';
  }

  @override
  String get noHiddenTitles => '暂无已隐藏作品';

  @override
  String get keepHidden => '重新扫描后仍保持隐藏';

  @override
  String get restoreOnScan => '重新扫描后会自动恢复';

  @override
  String get restoreTitle => '恢复显示';

  @override
  String get titleNotFound => '未找到作品';

  @override
  String get scanBeforeRemove => '扫描或刮削进行中，请完成后再移除作品';

  @override
  String get removeWorkTitle => '从媒体库删除该作品？';

  @override
  String get removeWorkBody => '仅从 Konata 媒体库中移除，不会删除本地或云盘源文件、人工关联和观看进度。';

  @override
  String get rescanRestoresHint => '不勾选时，重新扫描该作品会再次显示';

  @override
  String get removeFromLibrary => '从媒体库移除';

  @override
  String get removeWorkFailed => '移除作品失败，请重试';

  @override
  String get manualMatch => '手动搜索并绑定';

  @override
  String get nameOrId => '名称或 TMDB ID';

  @override
  String get search => '搜索';

  @override
  String get searchFailed => '搜索失败，请检查凭据和网络后重试';

  @override
  String get bindFailed => '绑定保存失败，请重试';

  @override
  String get editMetadata => '编辑元数据';

  @override
  String get workTitle => '作品标题';

  @override
  String get year => '年份';

  @override
  String get optional => '可留空';

  @override
  String get synopsis => '作品简介';

  @override
  String get notLinked => '未绑定';

  @override
  String get bangumiIds => '关联 Bangumi ID';

  @override
  String get bangumiIdsHint =>
      '多个 ID 用逗号分隔，例如 302189, 331887。保存后按人工确认锁定，不会拆分作品。';

  @override
  String get searchAndLink => '搜索并绑定';

  @override
  String get invalidBangumiIds => '请输入有效的 Bangumi ID';

  @override
  String get invalidTitleYear => '请输入作品标题和有效年份';

  @override
  String get characterOrder => '角色排序';

  @override
  String get noCharactersYet => '暂无角色，请先在详情页加载资料';

  @override
  String get recropCover => '重新裁剪当前封面';

  @override
  String get editCover => '编辑封面';

  @override
  String get automaticCover => '恢复自动';

  @override
  String get importImage => '导入图片';

  @override
  String get coverFailed => '封面处理失败，请检查图片与存储空间';

  @override
  String get imageDecodeFailed => '图片解码失败';

  @override
  String get cropFailed => '裁剪导出失败，请重试';

  @override
  String get cropPoster => '裁剪封面 · 2:3';

  @override
  String get cropHint => '拖动调整位置 · 滚轮或双指缩放 · 框内即最终海报';

  @override
  String get lowResImage => '原图分辨率较低，将保留原有清晰度';

  @override
  String get reset => '重置';

  @override
  String get saving => '正在保存…';

  @override
  String get confirmSave => '确认保存';

  @override
  String get mainFeature => '正片';

  @override
  String get extraFiles => '特典';

  @override
  String get allExtras => '全部';

  @override
  String get otherExtra => '其他';

  @override
  String get unnamedVideo => '未命名视频';

  @override
  String get unnamedWork => '未命名作品';

  @override
  String get cast => '演员';

  @override
  String get crew => '制作人员';

  @override
  String get characters => '角色';

  @override
  String get collapseList => '收起列表';

  @override
  String get fullList => '完整列表';

  @override
  String get noExtras => '暂无特典文件';

  @override
  String get noLinkedEpisodes => '暂无已关联正片';

  @override
  String get backToLibrary => '返回媒体库';

  @override
  String get moreActions => '更多操作';

  @override
  String get noMainFeature => '暂无正片';

  @override
  String get startPlayback => '开始播放';

  @override
  String get noSynopsis => '暂无作品简介';

  @override
  String get collapseSynopsis => '收起简介';

  @override
  String get expandSynopsis => '展开简介';

  @override
  String get unwatchedStatus => '未看';

  @override
  String get commercial => '宣传广告';

  @override
  String get promoVideo => '宣传影像';

  @override
  String get cleanOpening => '无字幕片头';

  @override
  String get cleanEnding => '无字幕片尾';

  @override
  String get discMenu => '光盘菜单';

  @override
  String get specialEpisode => '特别篇';

  @override
  String episodeLabel(int number) {
    return '第$number集';
  }

  @override
  String detailEpisodeCount(int count) {
    return '$count 集';
  }

  @override
  String detailVersionCount(int count) {
    return '$count 个版本';
  }

  @override
  String resumeEpisode(String episode) {
    return '继续播放$episode';
  }

  @override
  String get resumePlayback => '继续播放';

  @override
  String get removeTitleAction => '删除该作品';

  @override
  String seekSeconds(int count) {
    return '$count 秒';
  }

  @override
  String get tmdbOpenFailed => '无法打开浏览器，请访问 https://www.themoviedb.org';

  @override
  String get manualEdit => '手动编辑';

  @override
  String get chooseSeason => '选择季';

  @override
  String get chooseEpisode => '选择集';

  @override
  String get keepMatch => '暂不改动';

  @override
  String get mappingHint => '选择作品和季，再为文件指定集数。更换作品时需为全部文件指定匹配。';

  @override
  String get mappingFailed => '保存失败，请检查匹配后重试';

  @override
  String get loadingMatches => '正在加载…';

  @override
  String get playbackStats => '统计数据';

  @override
  String get chapters => '章节';

  @override
  String get noChapters => '此视频没有章节信息';

  @override
  String get chapterReadFailed => '读取章节失败，请重试';

  @override
  String get statsUnavailable => '未知';

  @override
  String get subtitleJapanese => '日语';

  @override
  String get subtitleChinese => '中文（未标明简繁）';

  @override
  String get losslessAudio => '无损';

  @override
  String get externalTrack => '外挂';

  @override
  String get statVideo => '视频编码';

  @override
  String get statResolution => '分辨率';

  @override
  String get statFps => '帧率';

  @override
  String get statOutputFps => '输出帧率';

  @override
  String get statHwdec => '硬件解码';

  @override
  String get statDropped => '输出丢帧';

  @override
  String get statDecoderDropped => '解码丢帧';

  @override
  String get statAudio => '音频编码';

  @override
  String get statSampleRate => '采样率（Hz）';

  @override
  String get statChannels => '声道数';

  @override
  String get statBitrate => '音频码率（bps）';

  @override
  String get statCache => '缓冲时长（秒）';

  @override
  String get statAvsync => '音画偏差（秒）';

  @override
  String get timelinePreview => '时间轴预览';

  @override
  String get previewOn => '时间轴预览已开启';

  @override
  String get previewOff => '时间轴预览已关闭';

  @override
  String get subtitleSimplifiedJapanese => '简日双语';

  @override
  String get subtitleTraditionalJapanese => '繁日双语';

  @override
  String get containedTrack => '内封';

  @override
  String get importSubtitle => '导入字幕';

  @override
  String trackNumber(int number) {
    return '轨道 $number';
  }

  @override
  String get exportLibraryBackup => '导出媒体库备份';

  @override
  String get exportLibraryBackupDescription => '包含作品、观看记录和自定义封面；不包含视频和保存的凭据。';

  @override
  String get exportLibraryBackupDone => '备份导出成功';

  @override
  String get exportLibraryBackupFailed => '备份导出失败';

  @override
  String get exportLibraryBackupTooLarge => '备份体积过大，无法在此设备保存';

  @override
  String get inspectLibraryBackup => '检查备份文件';

  @override
  String get inspectLibraryBackupDescription => '只读取并验证备份，不导入或修改媒体库。';

  @override
  String get inspectLibraryBackupFailed => '备份文件校验失败';

  @override
  String get playerSettings => '播放器';

  @override
  String get mpvConfiguration => '原生 MPV 配置';

  @override
  String get mpvEnable => '启用自定义 mpv.conf 与 input.conf';

  @override
  String get mpvEnableDetail => '每次起播前读取 mpv.conf 和 input.conf。请仅使用可信配置。';

  @override
  String get mpvNextPlayback => '更改将在下次打开播放器时生效。';

  @override
  String get mpvEdit => '编辑';

  @override
  String get mpvImport => '导入文件';

  @override
  String get mpvReset => '恢复空白默认配置';

  @override
  String get mpvFolderReadError => '无法读取配置目录。请检查配置文件，或在播放器设置中重新选择目录。';

  @override
  String get mpvUseInternal => '使用应用内配置';

  @override
  String get fullscreen => '进入全屏';

  @override
  String get exitFullscreen => '退出全屏';

  @override
  String get mpvOpenDirectory => '选择配置目录';

  @override
  String get mpvError => 'MPV 设置操作失败';

  @override
  String get mpvSave => '保存';

  @override
  String get backupPreviewCounts => '作品 / 文件 / 来源 / 记录 / 封面';

  @override
  String get confirmEpisodeIdentity => '确认剧集身份';

  @override
  String get revokeEpisodeIdentity => '撤销身份确认';

  @override
  String get watchStateConflict => '观看状态有冲突';

  @override
  String get confirmEpisodeDescription => '请核对作品、季号和集号，仅在此文件确实对应这集时确认。';

  @override
  String get historyEventsRetained => '观看事件单独保留；删除续播历史不会将剧集标为未看或删除观看事件。';

  @override
  String get bangumiEpisodeMapping => 'Bangumi 剧集绑定';

  @override
  String get bangumiSubjectId => '作品 ID';

  @override
  String get bangumiEpisodeId => '章节 ID';

  @override
  String get bangumiEpisodeType => '章节类型';

  @override
  String get bangumiMainStory => '正片';

  @override
  String get verifyBangumiEpisode => '核验章节';

  @override
  String get bangumiMappingDescription =>
      '请核对作品、章节标题、编号与类型。Bangumi 编号可以与 TMDB 不同，此操作仅保存关联。';

  @override
  String get bangumiMappingFailed => '章节核验失败，请检查 ID 和类型后重试。';

  @override
  String get revokeBangumiMapping => '撤销剧集绑定';

  @override
  String get statMpvVersion => 'MPV 版本';

  @override
  String get statHwdecSetting => '解码设置';

  @override
  String get statPixelFormat => '解码像素格式';

  @override
  String get statUnderlyingPixelFormat => '硬解底层像素格式';

  @override
  String get statColorMatrix => '色彩矩阵';

  @override
  String get statColorPrimaries => '色彩原色';

  @override
  String get statTransferFunction => '传递函数';

  @override
  String get statColorRange => '色彩范围';

  @override
  String get statVideoOutput => '视频输出方式';

  @override
  String get statFilteredWidth => '滤镜后视频宽度';

  @override
  String get statFilteredHeight => '滤镜后视频高度';

  @override
  String get statCachePaused => '因缓冲暂停';

  @override
  String get statSourceDepth => '解码分量位深（已识别格式）';

  @override
  String get statTextureSize => 'Flutter 纹理尺寸';

  @override
  String get statFilteredDepth => '滤镜后分量位深';

  @override
  String get statTargetDepth => 'MPV 报告的目标位深';

  @override
  String get statTargetPrimaries => 'MPV 目标色彩原色';

  @override
  String get statTargetTransfer => 'MPV 目标传递函数';

  @override
  String get statPresentationDepth => '最终呈现位深（未测量）';

  @override
  String get statDecodedAudioFormat => '解码音频样本格式';

  @override
  String get statOutputAudioFormat => '音频接口样本格式';

  @override
  String get statOutputSampleRate => '音频接口采样率';

  @override
  String get statOutputChannels => '音频接口声道布局';

  @override
  String get statAudioOutput => '音频输出方式';

  @override
  String get restoreLibraryBackup => '从备份恢复';

  @override
  String get restoreLibraryBackupDescription =>
      '选择 ZIP 备份，预览后恢复媒体库、记录、手动封面和基础设置。';

  @override
  String get restoreLibraryBackupWarning =>
      '这会替换当前媒体库和播放记录，不会合并。恢复前会自动备份当前数据；失败时回退。\n\n视频文件和本机扩展设置不在备份中。来源密码需要重新填写；跨设备的本地目录需要在“编辑来源”中重新选择并授权。恢复不会自动扫描或连接来源。';

  @override
  String get restoringLibraryBackup => '正在恢复，请稍候…';

  @override
  String get restoreLibraryBackupDone => '恢复完成。需要时请编辑来源，重新选择目录或填写密码。';

  @override
  String get restoreLibraryBackupFailed => '恢复未完成，请检查备份和可用空间后重试。';

  @override
  String get restoreLibraryBackupBusy => '请等待扫描结束后再恢复备份。';

  @override
  String get previousLibraryBackup => '恢复前的备份';

  @override
  String get previousLibraryBackupDescription => '保留最近两次恢复前的备份，可预览后恢复。';

  @override
  String get noPreviousLibraryBackup => '还没有自动生成的恢复前备份。';

  @override
  String get restoreCurrentLibrary => '当前媒体库（作品 / 文件 / 来源）';

  @override
  String get extensions => '扩展';

  @override
  String get extensionsDescription =>
      '在此开启可选功能，开启后可在“刮削服务”调整相关设置。关闭后停止相关请求并释放临时资源。';

  @override
  String get characterDetails => '角色与声优';

  @override
  String get characterDetailsDescription => '在作品详情页显示 Bangumi 角色与声优资料。';

  @override
  String get voiceActorPhotos => '显示声优照片';

  @override
  String get creditsDetails => '真人演员与制作人员';

  @override
  String get creditsDetailsDescription => '在真人影视详情页显示 TMDB 演员与制作人员。';

  @override
  String get creditsServiceSettings => '使用共用的 TMDB 凭据，点击打开 API 设置。';

  @override
  String get optionalFeatureFailed => '暂时无法加载或保存，请重试。';

  @override
  String get optionalNoResults => '暂无相关资料。';

  @override
  String get animationCategory => '动画';

  @override
  String get liveActionCategory => '真人影视';

  @override
  String get featureOff => '关闭';

  @override
  String get voiceActors => '声优';

  @override
  String get sage => '灰绿';

  @override
  String get allWorks => '全部作品';

  @override
  String compactWorkCount(int count) {
    return '$count 部';
  }

  @override
  String get bangumiPeopleData => 'Bangumi角色/声优资料';

  @override
  String get tmdbPeopleData => 'TMDB真人资料';

  @override
  String get peopleBar => '角色栏';

  @override
  String get peopleFallbackTmdb => '关闭 Bangumi 资料时，统一使用 TMDB 资料。';

  @override
  String get peopleFallbackHidden => '关闭 Bangumi 资料时，不显示角色栏。';

  @override
  String get historySelectAll => '全选';

  @override
  String get historyDeselectAll => '取消全选';

  @override
  String historySelectionCount(int count) {
    return '已选 $count 项';
  }

  @override
  String deleteHistorySelectionQuestion(int count) {
    return '删除选中的 $count 条播放记录？';
  }

  @override
  String get imageCache => '图片缓存';

  @override
  String get measuringCache => '正在计算…';

  @override
  String get cacheSizeUnavailable => '暂时无法读取';

  @override
  String get openCacheDirectory => '打开缓存目录';

  @override
  String get cacheDirectoryUnavailable => '暂时无法打开缓存目录。';

  @override
  String get detailBackdrop => '详情页背景图';

  @override
  String get cacheSettingFailed => '设置保存失败，请重试。';

  @override
  String get nameOrBangumiId => '名称或 Bangumi ID';

  @override
  String get unclassified => '待归类';

  @override
  String get assignToWork => '归入作品';

  @override
  String get workName => '作品名称';

  @override
  String get createClassification => '以此名称创建作品';

  @override
  String get classificationHint =>
      '仅调整媒体库归属，不移动或重命名原始文件。选取同一媒体源的文件后，可批量归入已有作品或新建作品。';

  @override
  String get selectSourceFiles => '选择此媒体源全部文件';
}

/// The translations for Chinese, using the Han script (`zh_Hans`).
class AppLocalizationsZhHans extends AppLocalizationsZh {
  AppLocalizationsZhHans() : super('zh_Hans');

  @override
  String get settings => '设置';

  @override
  String get appearance => '外观';

  @override
  String get scraping => '刮削服务';

  @override
  String get about => '关于';

  @override
  String get recordsSync => '记录与同步';

  @override
  String get language => '语言';

  @override
  String get library => '媒体库';

  @override
  String get sources => '媒体源';

  @override
  String get closeSettings => '关闭设置';

  @override
  String get backSettings => '返回设置';

  @override
  String get followSystem => '跟随系统';

  @override
  String get interfaceLanguage => '界面语言';

  @override
  String get languageSaveFailed => '语言设置保存失败，请重试';

  @override
  String get languageDescription => '界面语言与刮削资料语言独立管理。部分页面的翻译仍在完善中。';

  @override
  String get dayMode => '日间模式';

  @override
  String get nightMode => '夜间模式';

  @override
  String get themeMode => '主题模式';

  @override
  String get themeDescription => '选择应用界面的颜色主题';

  @override
  String get themeSaveFailed => '主题设置保存失败，请重试';

  @override
  String get accent => '主题色';

  @override
  String get accentDescription => '选择应用界面的强调色';

  @override
  String get accentSaveFailed => '主题色保存失败，请重试';

  @override
  String get red => '红色';

  @override
  String get pink => '粉色';

  @override
  String get lightBlue => '浅蓝色';

  @override
  String get switchLight => '切换到日间模式';

  @override
  String get switchDark => '切换到夜间模式';

  @override
  String get tmdbSettings => 'TMDB API 设置';

  @override
  String get credentialsConfigured => '已配置 · 支持访问令牌 / API Key';

  @override
  String get credentialsMissing => '未配置 · 设置访问令牌或 API Key';

  @override
  String get metadataServicesDescription => 'TMDB / Bangumi API、图片地址与独立连接测试';

  @override
  String get tmdbIdGuide => 'TMDB ID 增强识别';

  @override
  String get history => '播放记录';

  @override
  String get historyDescription => '查看续播位置、管理本地已看状态';

  @override
  String get historyFailed => '播放记录操作失败，请重试';

  @override
  String get clearHistoryQuestion => '清空播放记录？';

  @override
  String get removeHistoryQuestion => '删除这条播放记录？';

  @override
  String get removeHistoryDescription => '将移除续播位置和播放记录。媒体文件及作品绑定会保留。';

  @override
  String get cancel => '取消';

  @override
  String get confirmDelete => '确认删除';

  @override
  String get playFailed => '无法打开该媒体，请检查媒体源是否可用';

  @override
  String get refreshHistory => '刷新播放记录';

  @override
  String get clearHistory => '清空播放记录';

  @override
  String get readHistoryFailed => '读取播放记录失败';

  @override
  String get retry => '重试';

  @override
  String get noHistory => '暂无播放记录';

  @override
  String get unknownWork => '未知作品';

  @override
  String get watched => '已看';

  @override
  String get watching => '观看中';

  @override
  String get manageHistory => '管理播放记录';

  @override
  String get markUnwatched => '标记为未看';

  @override
  String get markWatched => '标记为已看';

  @override
  String get deleteRecord => '删除记录';

  @override
  String get enableLogs => '详细调试日志';

  @override
  String get logsDescription => '平时保留异常和必要的播放记录；复现问题前开启，可补充详细信息。';

  @override
  String get logsSaveFailed => '日志设置保存失败';

  @override
  String get openLogs => '打开日志目录';

  @override
  String get exportLogsSystem => '仅导出最近一次异常前后的 TXT 文本记录';

  @override
  String get logsDefaultPath => '应用数据目录 / logs';

  @override
  String get versionLabel => '版本 1.0.0';

  @override
  String get noLogs => '当前没有可导出的异常记录';

  @override
  String get exportLogs => '导出最近异常日志';

  @override
  String get logsAccessFailed => '无法访问日志目录，请检查系统文件应用';

  @override
  String get chooseVersion => '选择播放版本';

  @override
  String get closeVersion => '关闭版本选择';

  @override
  String get filenameHints => '技术信息来自文件名标记，仅供参考；未标明的音轨和字幕需在播放时确认。';

  @override
  String get unknownSource => '未知媒体源';

  @override
  String get unnamedSource => '未命名媒体源';

  @override
  String get releaseTag => '发布标记（未分类）';

  @override
  String get encoderTag => '压制组标记';

  @override
  String get subtitleGroupTag => '字幕组标记';

  @override
  String get sourceLabel => '媒体源';

  @override
  String get minimize => '最小化';

  @override
  String get maximize => '最大化';

  @override
  String get restoreWindow => '还原窗口';

  @override
  String get closeWindow => '关闭';

  @override
  String get apiGuideTitle => '如何获取 TMDB API';

  @override
  String get apiGuideBody =>
      '1. 打开 https://www.themoviedb.org/，注册或登录账号。\n\n2. 进入账户设置，找到 API 页面。建议在电脑浏览器中申请，手机页面可能不便操作。\n\n3. 按官方要求填写申请资料并同意使用条款。请根据实际用途如实填写。\n\n4. 获得凭据后，回到 Konata 的 TMDB API 设置。\n\n5. 选择“访问令牌”时，填写 API Read Access Token；选择“API Key”时，填写 API Key。两种凭据不能混用。\n\n6. 点击“测试连接”，验证成功后保存。凭据保存在系统安全存储中，请勿公开分享。\n\n账户 API 页面：https://www.themoviedb.org/settings/api';

  @override
  String get openApiPage => '打开 TMDB API 页面';

  @override
  String get gotIt => '知道了';

  @override
  String get browserCopyFailed => '无法打开浏览器，请复制下方网址手动访问';

  @override
  String get githubOpenFailed =>
      '无法打开浏览器，请访问 https://github.com/ClainSt/Konata';

  @override
  String get subtitleSimplified => '简体中文';

  @override
  String get subtitleTraditional => '繁体中文';

  @override
  String get subtitleBilingual => '中日字幕标记';

  @override
  String get subtitleAss => 'ASS 标记';

  @override
  String get subtitlePgs => 'PGS 标记';

  @override
  String get authMethod => 'TMDB 认证方式';

  @override
  String get accessToken => '访问令牌';

  @override
  String get closeTmdb => '关闭 TMDB 设置';

  @override
  String get enterCredentials => '请先填写所选认证方式的凭证';

  @override
  String get connectionOk => 'TMDB 连接验证成功';

  @override
  String get credentialTestFailed => '验证失败，请检查凭证和网络后重试';

  @override
  String get credentialSaveFailed => '凭据保存失败，请重试';

  @override
  String get secureCredentials => '保存在系统安全存储；两种凭证分别保存，可随时切换';

  @override
  String get metadataProviders => '元数据来源仅使用 TMDB 和 Bangumi，后者的公开搜索不需要此凭证。';

  @override
  String get testConnection => '测试连接';

  @override
  String get save => '保存';

  @override
  String get closeIdGuide => '关闭识别说明';

  @override
  String get idIntroTitle => '通过 TMDB ID 定位作品';

  @override
  String get idIntroBody =>
      '在作品文件夹名称中加入 TMDB ID，Konata 扫描时会优先按 ID 获取作品资料，减少同名作品或译名不同带来的匹配偏差。此能力默认生效，无需另开开关。';

  @override
  String get idFormatsTitle => '支持的命名格式';

  @override
  String idFormats(
    String standard,
    String alternate,
    String brackets,
    String movie,
  ) {
    return '推荐：$standard\n也支持：$alternate、$brackets\n标记不区分大小写，请保留花括号或方括号。电影可使用 $movie 明确类型。';
  }

  @override
  String get idExampleTitle => '目录示例';

  @override
  String idExample(String path) {
    return '$path\n\n建议将标记放在作品文件夹，而不是合集目录。不同作品分别放入各自的作品文件夹。';
  }

  @override
  String get idStepsTitle => '如何使用';

  @override
  String get idSteps =>
      '1. 在 TMDB 作品页面的网址中找到数字 ID，确认作品与类型正确。\n2. 自行在作品文件夹名称中加入标记。Konata 不会替你修改本地或云盘文件。\n3. 在媒体源中重新扫描对应目录，获取作品资料。已有作品也可在详情页使用“搜索并绑定作品”手动修正。';

  @override
  String get idNotesTitle => '识别时请注意';

  @override
  String get idNotes =>
      '• TMDB 凭证与 API 服务需要可用；填入 ID 不代表网络请求一定成功。\n• 集数建议使用 S01E01 等季集标记；特别篇可用 S00E01。作品 ID 仅定位作品，不替代季集识别。\n• 年份若填写，建议与 TMDB 条目一致；不确定时可以省略。\n• 人工锁定的作品资料与手动封面不会被自动刮削覆盖。\n• 无对应 TMDB 条目或信息不完整时，可在详情页手动确认绑定，不保证所有资源自动识别。';

  @override
  String get autoWatched => '自动标记已看';

  @override
  String get autoWatchedDescription =>
      '实际观看内容达到此比例时自动标记已看。跳转、暂停和重复观看不会额外累计；手动已看或未看状态优先。';

  @override
  String get watchSettingsSaveFailed => '观看设置保存失败，请重试';

  @override
  String get progressSaveFailed => '播放记录保存失败，将继续重试';

  @override
  String get apiAddress => 'API 地址';

  @override
  String get imageAddress => '图片服务器地址';

  @override
  String get testApi => 'API 连接测试';

  @override
  String get testImages => '图片服务器连接测试';

  @override
  String get connectionDetails => '连接详情';

  @override
  String get resetDefaults => '恢复默认';

  @override
  String get officialServers => '官方标准地址';

  @override
  String get closeMetadata => '关闭元数据服务设置';

  @override
  String get serverNotice =>
      '分别配置 API 与图片服务。Bangumi 默认使用非官方社区镜像；HTTP 地址会明文传输数据。';

  @override
  String get videoOutputRecovered => '画面输出已恢复。';

  @override
  String get autoFallback => '自动故障回退';

  @override
  String get fallbackDescription => '仅正式请求使用备用服务；连接测试始终使用当前输入地址';

  @override
  String get allowCustomCredentials => '允许向自定义 HTTPS TMDB 服务发送凭证';

  @override
  String get notTested => '未测试';

  @override
  String get testing => '测试中';

  @override
  String get serverConnected => '连接成功';

  @override
  String get connectionPartial => '部分功能异常';

  @override
  String get serverSaveFailed => '保存失败，请检查地址格式与存储权限';

  @override
  String get diagnosticCredentials => '请先设置 TMDB 凭证';

  @override
  String get diagnosticAuth => '认证失败，请检查凭证';

  @override
  String get diagnosticTimeout => '网络超时';

  @override
  String get diagnosticTls => 'TLS 连接失败';

  @override
  String get diagnosticNetwork => '网络连接失败';

  @override
  String get diagnosticInvalid => '地址、JSON 或图片无效';

  @override
  String get diagnosticHttp => '服务器返回错误';

  @override
  String get diagnosticFailed => '连接失败，请检查地址和访问授权';

  @override
  String get audioTracks => '音轨';

  @override
  String get subtitles => '字幕';

  @override
  String get chooseSubtitles => '选择字幕';

  @override
  String get chooseAudio => '选择音轨';

  @override
  String get subtitlesOff => '关闭字幕';

  @override
  String get trackAuto => '自动选择';

  @override
  String get rewind10 => '后退 10 秒';

  @override
  String get forward10 => '前进 10 秒';

  @override
  String get play => '播放';

  @override
  String get pause => '暂停';

  @override
  String get playbackFailed => '无法播放，请检查媒体文件和媒体源';

  @override
  String get audioOff => '关闭音轨';

  @override
  String get trackSwitchFailed => '音轨或字幕切换失败，请重试';

  @override
  String get addMedia => '添加媒体';

  @override
  String get localMedia => '本地媒体';

  @override
  String get networkMedia => '网络媒体';

  @override
  String get localFolder => '本地文件夹';

  @override
  String get addLocalFolder => '添加本地媒体文件夹';

  @override
  String get addLocalTitle => '添加本地文件夹';

  @override
  String get addWebdav => '添加 WebDAV 服务器';

  @override
  String get addSmb => '添加 SMB 共享';

  @override
  String get editSource => '编辑媒体源';

  @override
  String get sourceName => '媒体源名称';

  @override
  String get smbUrl => 'SMB 共享地址';

  @override
  String get webdavUrl => 'WebDAV 根目录 URL';

  @override
  String get chooseFolder => '选择文件夹';

  @override
  String get chooseMediaFolder => '选择本地媒体文件夹';

  @override
  String get usernameOptional => '用户名（可留空）';

  @override
  String get newPassword => '新密码（可留空）';

  @override
  String get passwordWillClear => '保存后清除已有密码';

  @override
  String get keepPassword => '留空保留原密码；用户名和密码均留空表示匿名访问';

  @override
  String get undoClearPassword => '撤销清除密码';

  @override
  String get clearSavedPassword => '清除已保存密码';

  @override
  String get sourceFieldsRequired => '名称和地址不能为空';

  @override
  String get invalidWebdav => '请输入有效的 WebDAV 地址';

  @override
  String get invalidSmb => '请输入有效的 SMB 共享地址';

  @override
  String get anonymousCredentials => '匿名访问时请同时留空用户名和密码';

  @override
  String get changeSourceTitle => '确认更改媒体源地址';

  @override
  String get changeSourceBody => '作品、人工绑定、观看进度及源 ID 将保留。如果新目录不包含原文件，需要重新扫描。';

  @override
  String get confirmChange => '确认修改';

  @override
  String get sourceFolderMissing => '目录或共享路径不存在';

  @override
  String get sourcePermissionDenied => '没有访问权限，请检查目录权限';

  @override
  String get cancelScan => '取消扫描';

  @override
  String get scanCancelled => '扫描已取消';

  @override
  String get scanStopping => '正在完成当前操作并停止…';

  @override
  String get sourceTestFailed => '连接失败，请检查地址、凭据和网络';

  @override
  String get sourceSaveFailed => '媒体源保存失败，请重试';

  @override
  String get localAccessible => '本地目录可访问';

  @override
  String get localMissing => '本地目录不存在';

  @override
  String get sourceConnectHint => '连接后可手动选择需要扫描的文件夹。';

  @override
  String get connectionName => '连接名称（可选）';

  @override
  String get folderPickerHint => '点击添加后将打开系统文件夹选择器，可直接选择本地目录。';

  @override
  String get smbUrlHint => 'SMB 地址（smb://主机/共享目录）';

  @override
  String get usernameCreate => '用户名（可选）';

  @override
  String get smbUsername => '用户名（可选，支持 域\\用户名）';

  @override
  String get passwordOptional => '密码（可选）';

  @override
  String get showPassword => '显示密码';

  @override
  String get hidePassword => '隐藏密码';

  @override
  String get guestHint => '无需认证时，用户名和密码留空即可。';

  @override
  String get add => '添加';

  @override
  String get sourceAddFailed => '媒体源添加失败，请检查地址后重试';

  @override
  String get scanProgress => '扫描进度';

  @override
  String get folderSearch => '搜索当前文件夹（名称 / TMDB ID）';

  @override
  String get clearSearch => '清除搜索';

  @override
  String get folderReadFailed => '目录读取失败，请检查路径或连接后重试';

  @override
  String get parentFolder => '.. 返回上级';

  @override
  String get fileLabel => '文件';

  @override
  String get help => '帮助';

  @override
  String get chooseScanHelpTitle => '怎样选择刮削文件夹？';

  @override
  String get chooseScanHelp =>
      '勾选文件夹即可加入刮削范围。既能勾选单部作品，也能勾选包含多部作品的上级目录。软件扫描后自动判断作品归属，对不确定的作品标记待复核。点击文件夹名称仍然可以进入子目录。';

  @override
  String get scanFolders => '正在扫描文件夹';

  @override
  String get scanMetadata => '正在自动刮削 TMDB / Bangumi';

  @override
  String get scanComplete => '扫描及自动刮削已完成';

  @override
  String get scanFailed => '扫描或自动刮削遇到错误';

  @override
  String get noScan => '尚无扫描记录';

  @override
  String get noScanHint => '还没有扫描过这个媒体源，选择文件夹后即可查看进度。';

  @override
  String get scanScope => '本次选中的扫描范围（含子目录视频）';

  @override
  String get visitedFolders => '具体已访问目录（仅统计该目录内视频）';

  @override
  String get noFoldersRead => '尚未读取到目录';

  @override
  String get scanningShort => '扫描中';

  @override
  String sourceConnected(int count) {
    return '连接成功，返回 $count 项';
  }

  @override
  String browseSource(String name) {
    return '浏览目录 · $name';
  }

  @override
  String itemCount(int count) {
    return '$count 项';
  }

  @override
  String videoCount(int count) {
    return '$count 个视频';
  }

  @override
  String folderMatches(int found, int total) {
    return '匹配 $found / $total 项';
  }

  @override
  String selectedScanFolders(int count) {
    return '已选刮削范围（$count）';
  }

  @override
  String scanSelectedFolders(int count) {
    return '扫描已选目录（$count）';
  }

  @override
  String scannedFolderCount(int count) {
    return '已扫描目录：$count';
  }

  @override
  String indexedVideoCount(int count) {
    return '索引视频：$count';
  }

  @override
  String scanMetadataCount(int done, int total) {
    return '元数据：$done/$total';
  }

  @override
  String scanSummary(int matched, int review, int failed) {
    return '成功：$matched · 待复核：$review · 失败：$failed';
  }

  @override
  String currentScanFolder(String path) {
    return '当前目录：$path';
  }

  @override
  String get addSource => '添加媒体源';

  @override
  String get localDirectory => '本地目录';

  @override
  String get browseScanFolders => '浏览云盘或本地目录并选取刮削文件夹';

  @override
  String get remove => '移除';

  @override
  String get removeSourceTitle => '移除媒体源？';

  @override
  String get removeSourceBody => '仅清除索引，不删除源文件。';

  @override
  String get addSourceFirst => '请先添加媒体源';

  @override
  String get noMatchingTitles => '暂无匹配作品';

  @override
  String get searchTitles => '搜索作品';

  @override
  String get closeSearch => '关闭搜索';

  @override
  String get manageHidden => '管理已隐藏作品';

  @override
  String sourceCount(int count) {
    return '$count 个媒体源';
  }

  @override
  String workCount(int count) {
    return '$count 部作品';
  }

  @override
  String get noHiddenTitles => '暂无已隐藏作品';

  @override
  String get keepHidden => '重新扫描后仍保持隐藏';

  @override
  String get restoreOnScan => '重新扫描后会自动恢复';

  @override
  String get restoreTitle => '恢复显示';

  @override
  String get titleNotFound => '未找到作品';

  @override
  String get scanBeforeRemove => '扫描或刮削进行中，请完成后再移除作品';

  @override
  String get removeWorkTitle => '从媒体库删除该作品？';

  @override
  String get removeWorkBody => '仅从 Konata 媒体库中移除，不会删除本地或云盘源文件、人工关联和观看进度。';

  @override
  String get rescanRestoresHint => '不勾选时，重新扫描该作品会再次显示';

  @override
  String get removeFromLibrary => '从媒体库移除';

  @override
  String get removeWorkFailed => '移除作品失败，请重试';

  @override
  String get manualMatch => '手动搜索并绑定';

  @override
  String get nameOrId => '名称或 TMDB ID';

  @override
  String get search => '搜索';

  @override
  String get searchFailed => '搜索失败，请检查凭据和网络后重试';

  @override
  String get bindFailed => '绑定保存失败，请重试';

  @override
  String get editMetadata => '编辑元数据';

  @override
  String get workTitle => '作品标题';

  @override
  String get year => '年份';

  @override
  String get optional => '可留空';

  @override
  String get synopsis => '作品简介';

  @override
  String get notLinked => '未绑定';

  @override
  String get bangumiIds => '关联 Bangumi ID';

  @override
  String get bangumiIdsHint =>
      '多个 ID 用逗号分隔，例如 302189, 331887。保存后按人工确认锁定，不会拆分作品。';

  @override
  String get searchAndLink => '搜索并绑定';

  @override
  String get invalidBangumiIds => '请输入有效的 Bangumi ID';

  @override
  String get invalidTitleYear => '请输入作品标题和有效年份';

  @override
  String get characterOrder => '角色排序';

  @override
  String get noCharactersYet => '暂无角色，请先在详情页加载资料';

  @override
  String get recropCover => '重新裁剪当前封面';

  @override
  String get editCover => '编辑封面';

  @override
  String get automaticCover => '恢复自动';

  @override
  String get importImage => '导入图片';

  @override
  String get coverFailed => '封面处理失败，请检查图片与存储空间';

  @override
  String get imageDecodeFailed => '图片解码失败';

  @override
  String get cropFailed => '裁剪导出失败，请重试';

  @override
  String get cropPoster => '裁剪封面 · 2:3';

  @override
  String get cropHint => '拖动调整位置 · 滚轮或双指缩放 · 框内即最终海报';

  @override
  String get lowResImage => '原图分辨率较低，将保留原有清晰度';

  @override
  String get reset => '重置';

  @override
  String get saving => '正在保存…';

  @override
  String get confirmSave => '确认保存';

  @override
  String get mainFeature => '正片';

  @override
  String get extraFiles => '特典';

  @override
  String get allExtras => '全部';

  @override
  String get otherExtra => '其他';

  @override
  String get unnamedVideo => '未命名视频';

  @override
  String get unnamedWork => '未命名作品';

  @override
  String get cast => '演员';

  @override
  String get crew => '制作人员';

  @override
  String get characters => '角色';

  @override
  String get collapseList => '收起列表';

  @override
  String get fullList => '完整列表';

  @override
  String get noExtras => '暂无特典文件';

  @override
  String get noLinkedEpisodes => '暂无已关联正片';

  @override
  String get backToLibrary => '返回媒体库';

  @override
  String get moreActions => '更多操作';

  @override
  String get noMainFeature => '暂无正片';

  @override
  String get startPlayback => '开始播放';

  @override
  String get noSynopsis => '暂无作品简介';

  @override
  String get collapseSynopsis => '收起简介';

  @override
  String get expandSynopsis => '展开简介';

  @override
  String get unwatchedStatus => '未看';

  @override
  String get commercial => '宣传广告';

  @override
  String get promoVideo => '宣传影像';

  @override
  String get cleanOpening => '无字幕片头';

  @override
  String get cleanEnding => '无字幕片尾';

  @override
  String get discMenu => '光盘菜单';

  @override
  String get specialEpisode => '特别篇';

  @override
  String episodeLabel(int number) {
    return '第$number集';
  }

  @override
  String detailEpisodeCount(int count) {
    return '$count 集';
  }

  @override
  String detailVersionCount(int count) {
    return '$count 个版本';
  }

  @override
  String resumeEpisode(String episode) {
    return '继续播放$episode';
  }

  @override
  String get resumePlayback => '继续播放';

  @override
  String get removeTitleAction => '删除该作品';

  @override
  String seekSeconds(int count) {
    return '$count 秒';
  }

  @override
  String get tmdbOpenFailed => '无法打开浏览器，请访问 https://www.themoviedb.org';

  @override
  String get manualEdit => '手动编辑';

  @override
  String get chooseSeason => '选择季';

  @override
  String get chooseEpisode => '选择集';

  @override
  String get keepMatch => '暂不改动';

  @override
  String get mappingHint => '选择作品和季，再为文件指定集数。更换作品时需为全部文件指定匹配。';

  @override
  String get mappingFailed => '保存失败，请检查匹配后重试';

  @override
  String get loadingMatches => '正在加载…';

  @override
  String get playbackStats => '统计数据';

  @override
  String get chapters => '章节';

  @override
  String get noChapters => '此视频没有章节信息';

  @override
  String get chapterReadFailed => '读取章节失败，请重试';

  @override
  String get statsUnavailable => '未知';

  @override
  String get subtitleJapanese => '日语';

  @override
  String get subtitleChinese => '中文（未标明简繁）';

  @override
  String get losslessAudio => '无损';

  @override
  String get externalTrack => '外挂';

  @override
  String get statVideo => '视频编码';

  @override
  String get statResolution => '分辨率';

  @override
  String get statFps => '帧率';

  @override
  String get statOutputFps => '输出帧率';

  @override
  String get statHwdec => '硬件解码';

  @override
  String get statDropped => '输出丢帧';

  @override
  String get statDecoderDropped => '解码丢帧';

  @override
  String get statAudio => '音频编码';

  @override
  String get statSampleRate => '采样率（Hz）';

  @override
  String get statChannels => '声道数';

  @override
  String get statBitrate => '音频码率（bps）';

  @override
  String get statCache => '缓冲时长（秒）';

  @override
  String get statAvsync => '音画偏差（秒）';

  @override
  String get timelinePreview => '时间轴预览';

  @override
  String get previewOn => '时间轴预览已开启';

  @override
  String get previewOff => '时间轴预览已关闭';

  @override
  String get subtitleSimplifiedJapanese => '简日双语';

  @override
  String get subtitleTraditionalJapanese => '繁日双语';

  @override
  String get containedTrack => '内封';

  @override
  String get importSubtitle => '导入字幕';

  @override
  String trackNumber(int number) {
    return '轨道 $number';
  }

  @override
  String get exportLibraryBackup => '导出媒体库备份';

  @override
  String get exportLibraryBackupDescription => '包含作品、观看记录和自定义封面；不包含视频和保存的凭据。';

  @override
  String get exportLibraryBackupDone => '备份导出成功';

  @override
  String get exportLibraryBackupFailed => '备份导出失败';

  @override
  String get exportLibraryBackupTooLarge => '备份体积过大，无法在此设备保存';

  @override
  String get inspectLibraryBackup => '检查备份文件';

  @override
  String get inspectLibraryBackupDescription => '只读取并验证备份，不导入或修改媒体库。';

  @override
  String get inspectLibraryBackupFailed => '备份文件校验失败';

  @override
  String get playerSettings => '播放器';

  @override
  String get mpvConfiguration => '原生 MPV 配置';

  @override
  String get mpvEnable => '启用自定义 mpv.conf 与 input.conf';

  @override
  String get mpvEnableDetail => '每次起播前读取 mpv.conf 和 input.conf。请仅使用可信配置。';

  @override
  String get mpvNextPlayback => '更改将在下次打开播放器时生效。';

  @override
  String get mpvEdit => '编辑';

  @override
  String get mpvImport => '导入文件';

  @override
  String get mpvReset => '恢复空白默认配置';

  @override
  String get mpvFolderReadError => '无法读取配置目录。请检查配置文件，或在播放器设置中重新选择目录。';

  @override
  String get mpvUseInternal => '使用应用内配置';

  @override
  String get fullscreen => '进入全屏';

  @override
  String get exitFullscreen => '退出全屏';

  @override
  String get mpvOpenDirectory => '选择配置目录';

  @override
  String get mpvError => 'MPV 设置操作失败';

  @override
  String get mpvSave => '保存';

  @override
  String get backupPreviewCounts => '作品 / 文件 / 来源 / 记录 / 封面';

  @override
  String get confirmEpisodeIdentity => '确认剧集身份';

  @override
  String get revokeEpisodeIdentity => '撤销身份确认';

  @override
  String get watchStateConflict => '观看状态有冲突';

  @override
  String get confirmEpisodeDescription => '请核对作品、季号和集号，仅在此文件确实对应这集时确认。';

  @override
  String get historyEventsRetained => '观看事件单独保留；删除续播历史不会将剧集标为未看或删除观看事件。';

  @override
  String get bangumiEpisodeMapping => 'Bangumi 剧集绑定';

  @override
  String get bangumiSubjectId => '作品 ID';

  @override
  String get bangumiEpisodeId => '章节 ID';

  @override
  String get bangumiEpisodeType => '章节类型';

  @override
  String get bangumiMainStory => '正片';

  @override
  String get verifyBangumiEpisode => '核验章节';

  @override
  String get bangumiMappingDescription =>
      '请核对作品、章节标题、编号与类型。Bangumi 编号可以与 TMDB 不同，此操作仅保存关联。';

  @override
  String get bangumiMappingFailed => '章节核验失败，请检查 ID 和类型后重试。';

  @override
  String get revokeBangumiMapping => '撤销剧集绑定';

  @override
  String get statMpvVersion => 'MPV 版本';

  @override
  String get statHwdecSetting => '解码设置';

  @override
  String get statPixelFormat => '解码像素格式';

  @override
  String get statUnderlyingPixelFormat => '硬解底层像素格式';

  @override
  String get statColorMatrix => '色彩矩阵';

  @override
  String get statColorPrimaries => '色彩原色';

  @override
  String get statTransferFunction => '传递函数';

  @override
  String get statColorRange => '色彩范围';

  @override
  String get statVideoOutput => '视频输出方式';

  @override
  String get statFilteredWidth => '滤镜后视频宽度';

  @override
  String get statFilteredHeight => '滤镜后视频高度';

  @override
  String get statCachePaused => '因缓冲暂停';

  @override
  String get statSourceDepth => '解码分量位深（已识别格式）';

  @override
  String get statTextureSize => 'Flutter 纹理尺寸';

  @override
  String get statFilteredDepth => '滤镜后分量位深';

  @override
  String get statTargetDepth => 'MPV 报告的目标位深';

  @override
  String get statTargetPrimaries => 'MPV 目标色彩原色';

  @override
  String get statTargetTransfer => 'MPV 目标传递函数';

  @override
  String get statPresentationDepth => '最终呈现位深（未测量）';

  @override
  String get statDecodedAudioFormat => '解码音频样本格式';

  @override
  String get statOutputAudioFormat => '音频接口样本格式';

  @override
  String get statOutputSampleRate => '音频接口采样率';

  @override
  String get statOutputChannels => '音频接口声道布局';

  @override
  String get statAudioOutput => '音频输出方式';

  @override
  String get restoreLibraryBackup => '从备份恢复';

  @override
  String get restoreLibraryBackupDescription =>
      '选择 ZIP 备份，预览后恢复媒体库、记录、手动封面和基础设置。';

  @override
  String get restoreLibraryBackupWarning =>
      '这会替换当前媒体库和播放记录，不会合并。恢复前会自动备份当前数据；失败时回退。\n\n视频文件和本机扩展设置不在备份中。来源密码需要重新填写；跨设备的本地目录需要在“编辑来源”中重新选择并授权。恢复不会自动扫描或连接来源。';

  @override
  String get restoringLibraryBackup => '正在恢复，请稍候…';

  @override
  String get restoreLibraryBackupDone => '恢复完成。需要时请编辑来源，重新选择目录或填写密码。';

  @override
  String get restoreLibraryBackupFailed => '恢复未完成，请检查备份和可用空间后重试。';

  @override
  String get restoreLibraryBackupBusy => '请等待扫描结束后再恢复备份。';

  @override
  String get previousLibraryBackup => '恢复前的备份';

  @override
  String get previousLibraryBackupDescription => '保留最近两次恢复前的备份，可预览后恢复。';

  @override
  String get noPreviousLibraryBackup => '还没有自动生成的恢复前备份。';

  @override
  String get restoreCurrentLibrary => '当前媒体库（作品 / 文件 / 来源）';

  @override
  String get extensions => '扩展';

  @override
  String get extensionsDescription =>
      '在此开启可选功能，开启后可在“刮削服务”调整相关设置。关闭后停止相关请求并释放临时资源。';

  @override
  String get characterDetails => '角色与声优';

  @override
  String get characterDetailsDescription => '在作品详情页显示 Bangumi 角色与声优资料。';

  @override
  String get voiceActorPhotos => '显示声优照片';

  @override
  String get creditsDetails => '真人演员与制作人员';

  @override
  String get creditsDetailsDescription => '在真人影视详情页显示 TMDB 演员与制作人员。';

  @override
  String get creditsServiceSettings => '使用共用的 TMDB 凭据，点击打开 API 设置。';

  @override
  String get optionalFeatureFailed => '暂时无法加载或保存，请重试。';

  @override
  String get optionalNoResults => '暂无相关资料。';

  @override
  String get animationCategory => '动画';

  @override
  String get liveActionCategory => '真人影视';

  @override
  String get featureOff => '关闭';

  @override
  String get voiceActors => '声优';

  @override
  String get sage => '灰绿';

  @override
  String get allWorks => '全部作品';

  @override
  String compactWorkCount(int count) {
    return '$count 部';
  }

  @override
  String get bangumiPeopleData => 'Bangumi角色/声优资料';

  @override
  String get tmdbPeopleData => 'TMDB真人资料';

  @override
  String get peopleBar => '角色栏';

  @override
  String get peopleFallbackTmdb => '关闭 Bangumi 资料时，统一使用 TMDB 资料。';

  @override
  String get peopleFallbackHidden => '关闭 Bangumi 资料时，不显示角色栏。';

  @override
  String get historySelectAll => '全选';

  @override
  String get historyDeselectAll => '取消全选';

  @override
  String historySelectionCount(int count) {
    return '已选 $count 项';
  }

  @override
  String deleteHistorySelectionQuestion(int count) {
    return '删除选中的 $count 条播放记录？';
  }

  @override
  String get imageCache => '图片缓存';

  @override
  String get measuringCache => '正在计算…';

  @override
  String get cacheSizeUnavailable => '暂时无法读取';

  @override
  String get openCacheDirectory => '打开缓存目录';

  @override
  String get cacheDirectoryUnavailable => '暂时无法打开缓存目录。';

  @override
  String get detailBackdrop => '详情页背景图';

  @override
  String get cacheSettingFailed => '设置保存失败，请重试。';

  @override
  String get nameOrBangumiId => '名称或 Bangumi ID';

  @override
  String get unclassified => '待归类';

  @override
  String get assignToWork => '归入作品';

  @override
  String get workName => '作品名称';

  @override
  String get createClassification => '以此名称创建作品';

  @override
  String get classificationHint =>
      '仅调整媒体库归属，不移动或重命名原始文件。选取同一媒体源的文件后，可批量归入已有作品或新建作品。';

  @override
  String get selectSourceFiles => '选择此媒体源全部文件';
}

/// The translations for Chinese, using the Han script (`zh_Hant`).
class AppLocalizationsZhHant extends AppLocalizationsZh {
  AppLocalizationsZhHant() : super('zh_Hant');

  @override
  String get settings => '設定';

  @override
  String get appearance => '外觀';

  @override
  String get scraping => '刮削服務';

  @override
  String get about => '關於';

  @override
  String get recordsSync => '記錄與同步';

  @override
  String get language => '語言';

  @override
  String get library => '媒體庫';

  @override
  String get sources => '媒體來源';

  @override
  String get closeSettings => '關閉設定';

  @override
  String get backSettings => '返回設定';

  @override
  String get followSystem => '跟隨系統';

  @override
  String get interfaceLanguage => '介面語言';

  @override
  String get languageSaveFailed => '語言設定儲存失敗，請重試';

  @override
  String get languageDescription => '介面語言與刮削資料語言獨立管理。部分頁面的翻譯仍在完善中。';

  @override
  String get dayMode => '日間模式';

  @override
  String get nightMode => '夜間模式';

  @override
  String get themeMode => '主題模式';

  @override
  String get themeDescription => '選擇應用介面的顏色主題';

  @override
  String get themeSaveFailed => '主題設定儲存失敗，請重試';

  @override
  String get accent => '主題色';

  @override
  String get accentDescription => '選擇應用介面的強調色';

  @override
  String get accentSaveFailed => '主題色儲存失敗，請重試';

  @override
  String get red => '紅色';

  @override
  String get pink => '粉色';

  @override
  String get lightBlue => '淺藍色';

  @override
  String get switchLight => '切換至日間模式';

  @override
  String get switchDark => '切換至夜間模式';

  @override
  String get tmdbSettings => 'TMDB API 設定';

  @override
  String get credentialsConfigured => '已設定 · 支援存取權杖 / API Key';

  @override
  String get credentialsMissing => '未設定 · 設定存取權杖或 API Key';

  @override
  String get metadataServicesDescription => 'TMDB / Bangumi API、圖片位址與獨立連線測試';

  @override
  String get tmdbIdGuide => 'TMDB ID 增強識別';

  @override
  String get history => '播放記錄';

  @override
  String get historyDescription => '查看續播位置、管理本機已看狀態';

  @override
  String get historyFailed => '播放記錄操作失敗，請重試';

  @override
  String get clearHistoryQuestion => '清空播放記錄？';

  @override
  String get removeHistoryQuestion => '刪除此播放記錄？';

  @override
  String get removeHistoryDescription => '將移除續播位置和播放記錄。媒體檔案及作品綁定會保留。';

  @override
  String get cancel => '取消';

  @override
  String get confirmDelete => '確認刪除';

  @override
  String get playFailed => '無法開啟此媒體，請檢查媒體來源是否可用';

  @override
  String get refreshHistory => '重新整理播放記錄';

  @override
  String get clearHistory => '清空播放記錄';

  @override
  String get readHistoryFailed => '讀取播放記錄失敗';

  @override
  String get retry => '重試';

  @override
  String get noHistory => '暫無播放記錄';

  @override
  String get unknownWork => '未知作品';

  @override
  String get watched => '已看';

  @override
  String get watching => '觀看中';

  @override
  String get manageHistory => '管理播放記錄';

  @override
  String get markUnwatched => '標記為未看';

  @override
  String get markWatched => '標記為已看';

  @override
  String get deleteRecord => '刪除記錄';

  @override
  String get enableLogs => '詳細除錯日誌';

  @override
  String get logsDescription => '平時保留異常與必要的播放記錄；重現問題前開啟，可補充詳細資訊。';

  @override
  String get logsSaveFailed => '日誌設定儲存失敗';

  @override
  String get openLogs => '開啟日誌目錄';

  @override
  String get exportLogsSystem => '僅匯出最近一次異常前後的 TXT 文字記錄';

  @override
  String get logsDefaultPath => '應用程式資料目錄 / logs';

  @override
  String get versionLabel => '版本 1.0.0';

  @override
  String get noLogs => '目前沒有可匯出的異常記錄';

  @override
  String get exportLogs => '匯出最近異常日誌';

  @override
  String get logsAccessFailed => '無法存取日誌目錄，請檢查系統檔案應用程式';

  @override
  String get chooseVersion => '選擇播放版本';

  @override
  String get closeVersion => '關閉版本選擇';

  @override
  String get filenameHints => '技術資訊來自檔案名稱標記，僅供參考；未標明的音軌和字幕需在播放時確認。';

  @override
  String get unknownSource => '未知媒體來源';

  @override
  String get unnamedSource => '未命名媒體來源';

  @override
  String get releaseTag => '發佈標記（未分類）';

  @override
  String get encoderTag => '壓製組標記';

  @override
  String get subtitleGroupTag => '字幕組標記';

  @override
  String get sourceLabel => '媒體來源';

  @override
  String get minimize => '最小化';

  @override
  String get maximize => '最大化';

  @override
  String get restoreWindow => '還原視窗';

  @override
  String get closeWindow => '關閉';

  @override
  String get apiGuideTitle => '如何取得 TMDB API';

  @override
  String get apiGuideBody =>
      '1. 開啟 https://www.themoviedb.org/，註冊或登入帳號。\n\n2. 進入帳戶設定，找到 API 頁面。建議使用電腦瀏覽器申請。\n\n3. 依官方要求如實填寫申請資料並同意使用條款。\n\n4. 取得憑證後，返回 Konata 的 TMDB API 設定。\n\n5. 選擇「存取權杖」時填入 API Read Access Token；選擇「API Key」時填入 API Key。兩種憑證不能混用。\n\n6. 點選「測試連線」，成功後儲存。憑證保存在系統安全儲存中，請勿公開分享。\n\n帳戶 API 頁面：https://www.themoviedb.org/settings/api';

  @override
  String get openApiPage => '開啟 TMDB API 頁面';

  @override
  String get gotIt => '知道了';

  @override
  String get browserCopyFailed => '無法開啟瀏覽器，請複製下方網址手動開啟';

  @override
  String get githubOpenFailed =>
      '無法開啟瀏覽器，請瀏覽 https://github.com/ClainSt/Konata';

  @override
  String get subtitleSimplified => '簡體中文';

  @override
  String get subtitleTraditional => '繁體中文';

  @override
  String get subtitleBilingual => '中日字幕標記';

  @override
  String get subtitleAss => 'ASS 標記';

  @override
  String get subtitlePgs => 'PGS 標記';

  @override
  String get authMethod => 'TMDB 驗證方式';

  @override
  String get accessToken => '存取權杖';

  @override
  String get closeTmdb => '關閉 TMDB 設定';

  @override
  String get enterCredentials => '請先填寫所選驗證方式的憑證';

  @override
  String get connectionOk => 'TMDB 連線驗證成功';

  @override
  String get credentialTestFailed => '驗證失敗，請檢查憑證和網路後重試';

  @override
  String get credentialSaveFailed => '憑證儲存失敗，請重試';

  @override
  String get secureCredentials => '保存在系統安全儲存中；兩種憑證分別儲存，可隨時切換';

  @override
  String get metadataProviders => '中繼資料僅來自 TMDB 和 Bangumi，後者的公開搜尋無需此憑證。';

  @override
  String get testConnection => '測試連線';

  @override
  String get save => '儲存';

  @override
  String get closeIdGuide => '關閉識別說明';

  @override
  String get idIntroTitle => '透過 TMDB ID 定位作品';

  @override
  String get idIntroBody =>
      '在作品資料夾名稱加入 TMDB ID，掃描時會優先按 ID 取得資料，減少同名或譯名差異造成的誤配。預設生效，無需開關。';

  @override
  String get idFormatsTitle => '支援的命名格式';

  @override
  String idFormats(
    String standard,
    String alternate,
    String brackets,
    String movie,
  ) {
    return '建議：$standard\n亦支援：$alternate、$brackets\n標記不區分大小寫，請保留括號。電影可用 $movie 指定類型。';
  }

  @override
  String get idExampleTitle => '目錄範例';

  @override
  String idExample(String path) {
    return '$path\n\n標記應放在作品資料夾，不是合集目錄。不同作品各用一個資料夾。';
  }

  @override
  String get idStepsTitle => '使用方式';

  @override
  String get idSteps =>
      '1. 從 TMDB 網址取得數字 ID，確認作品和類型。\n2. 自行在作品資料夾名稱加入標記。Konata 不會更改本機或雲端檔案。\n3. 重新掃描資料夾取得資料。已有作品亦可在詳情頁搜尋並手動綁定。';

  @override
  String get idNotesTitle => '注意事項';

  @override
  String get idNotes =>
      '• TMDB 憑證和 API 仍須可用。\n• 季集建議用 S01E01，特別篇用 S00E01。作品 ID 不取代季集辨識。\n• 年份應與 TMDB 一致；不確定可省略。\n• 手動鎖定的資料和封面不會被自動覆寫。\n• 缺少或不完整的 TMDB 條目需手動確認，不能保證全部自動辨識。';

  @override
  String get autoWatched => '自動標記已看';

  @override
  String get autoWatchedDescription =>
      '實際觀看內容達此比例時自動標記已看。跳轉、暫停和重複觀看不會額外累計；手動已看或未看狀態優先。';

  @override
  String get watchSettingsSaveFailed => '觀看設定儲存失敗，請重試';

  @override
  String get progressSaveFailed => '播放記錄儲存失敗，將繼續重試';

  @override
  String get apiAddress => 'API 位址';

  @override
  String get imageAddress => '圖片伺服器位址';

  @override
  String get testApi => 'API 連線測試';

  @override
  String get testImages => '圖片伺服器連線測試';

  @override
  String get connectionDetails => '連線詳情';

  @override
  String get resetDefaults => '恢復預設';

  @override
  String get officialServers => '官方標準位址';

  @override
  String get closeMetadata => '關閉中繼資料服務設定';

  @override
  String get serverNotice =>
      '分別設定 API 與圖片服務。Bangumi 預設使用非官方社群鏡像；HTTP 位址會以明文傳輸資料。';

  @override
  String get videoOutputRecovered => '畫面輸出已恢復。';

  @override
  String get autoFallback => '自動故障回退';

  @override
  String get fallbackDescription => '僅正式請求使用備用服務；連線測試一律使用目前輸入的位址';

  @override
  String get allowCustomCredentials => '允許向自訂 HTTPS TMDB 服務傳送憑證';

  @override
  String get notTested => '未測試';

  @override
  String get testing => '測試中';

  @override
  String get serverConnected => '連線成功';

  @override
  String get connectionPartial => '部分功能異常';

  @override
  String get serverSaveFailed => '儲存失敗，請檢查位址格式與儲存權限';

  @override
  String get diagnosticCredentials => '請先設定 TMDB 憑證';

  @override
  String get diagnosticAuth => '驗證失敗，請檢查憑證';

  @override
  String get diagnosticTimeout => '網路逾時';

  @override
  String get diagnosticTls => 'TLS 連線失敗';

  @override
  String get diagnosticNetwork => '網路連線失敗';

  @override
  String get diagnosticInvalid => '位址、JSON 或圖片無效';

  @override
  String get diagnosticHttp => '伺服器回傳錯誤';

  @override
  String get diagnosticFailed => '連線失敗，請檢查位址和存取授權';

  @override
  String get audioTracks => '音軌';

  @override
  String get subtitles => '字幕';

  @override
  String get chooseSubtitles => '選擇字幕';

  @override
  String get chooseAudio => '選擇音軌';

  @override
  String get subtitlesOff => '關閉字幕';

  @override
  String get trackAuto => '自動選擇';

  @override
  String get rewind10 => '倒退 10 秒';

  @override
  String get forward10 => '快轉 10 秒';

  @override
  String get play => '播放';

  @override
  String get pause => '暫停';

  @override
  String get playbackFailed => '無法播放，請檢查媒體檔案和媒體來源';

  @override
  String get audioOff => '關閉音軌';

  @override
  String get trackSwitchFailed => '音軌或字幕切換失敗，請重試';

  @override
  String get addMedia => '新增媒體';

  @override
  String get localMedia => '本機媒體';

  @override
  String get networkMedia => '網路媒體';

  @override
  String get localFolder => '本機資料夾';

  @override
  String get addLocalFolder => '新增本機媒體資料夾';

  @override
  String get addLocalTitle => '新增本機資料夾';

  @override
  String get addWebdav => '新增 WebDAV 伺服器';

  @override
  String get addSmb => '新增 SMB 共用';

  @override
  String get editSource => '編輯媒體來源';

  @override
  String get sourceName => '媒體來源名稱';

  @override
  String get smbUrl => 'SMB 共用位址';

  @override
  String get webdavUrl => 'WebDAV 根目錄 URL';

  @override
  String get chooseFolder => '選擇資料夾';

  @override
  String get chooseMediaFolder => '選擇本機媒體資料夾';

  @override
  String get usernameOptional => '使用者名稱（可留空）';

  @override
  String get newPassword => '新密碼（可留空）';

  @override
  String get passwordWillClear => '儲存後清除現有密碼';

  @override
  String get keepPassword => '使用者名稱不變時留空保留原密碼；兩者皆留空為匿名存取';

  @override
  String get undoClearPassword => '復原清除密碼';

  @override
  String get clearSavedPassword => '清除已儲存的密碼';

  @override
  String get sourceFieldsRequired => '名稱和位址不能留空';

  @override
  String get invalidWebdav => '請輸入有效的 WebDAV 位址';

  @override
  String get invalidSmb => '請輸入有效的 SMB 共用位址';

  @override
  String get anonymousCredentials => '匿名存取時請同時留空使用者名稱和密碼';

  @override
  String get changeSourceTitle => '確認變更媒體來源位址';

  @override
  String get changeSourceBody => '作品、手動綁定、觀看進度及來源 ID 將保留。新目錄若不含原檔案，需重新掃描。';

  @override
  String get confirmChange => '確認修改';

  @override
  String get sourceFolderMissing => '目錄或共用路徑不存在';

  @override
  String get sourcePermissionDenied => '沒有存取權限，請檢查目錄權限';

  @override
  String get cancelScan => '取消掃描';

  @override
  String get scanCancelled => '掃描已取消';

  @override
  String get scanStopping => '正在完成目前操作並停止…';

  @override
  String get sourceTestFailed => '連線失敗，請檢查位址、憑證和網路';

  @override
  String get sourceSaveFailed => '媒體來源儲存失敗，請重試';

  @override
  String get localAccessible => '本機目錄可存取';

  @override
  String get localMissing => '本機目錄不存在';

  @override
  String get sourceConnectHint => '連線後可選擇要掃描的資料夾。';

  @override
  String get connectionName => '連線名稱（選填）';

  @override
  String get folderPickerHint => '點選新增後即可選擇本機資料夾。';

  @override
  String get smbUrlHint => 'SMB 位址（smb://主機/共用目錄）';

  @override
  String get usernameCreate => '使用者名稱（選填）';

  @override
  String get smbUsername => '使用者名稱（選填，支援 網域\\使用者名稱）';

  @override
  String get passwordOptional => '密碼（選填）';

  @override
  String get showPassword => '顯示密碼';

  @override
  String get hidePassword => '隱藏密碼';

  @override
  String get guestHint => '無需驗證時，使用者名稱和密碼留空即可。';

  @override
  String get add => '新增';

  @override
  String get sourceAddFailed => '媒體來源新增失敗，請檢查位址後重試';

  @override
  String get scanProgress => '掃描進度';

  @override
  String get folderSearch => '搜尋目前資料夾（名稱 / TMDB ID）';

  @override
  String get clearSearch => '清除搜尋';

  @override
  String get folderReadFailed => '目錄讀取失敗，請檢查路徑或連線後重試';

  @override
  String get parentFolder => '.. 返回上層';

  @override
  String get fileLabel => '檔案';

  @override
  String get help => '說明';

  @override
  String get chooseScanHelpTitle => '如何選擇掃描資料夾？';

  @override
  String get chooseScanHelp =>
      '勾選單部作品或多部作品的上層資料夾即可加入掃描。掃描後自動判斷作品歸屬，不確定者標記待複核。點選名稱仍可瀏覽子目錄。';

  @override
  String get scanFolders => '正在掃描資料夾';

  @override
  String get scanMetadata => '正在取得 TMDB / Bangumi 資料';

  @override
  String get scanComplete => '掃描及資料取得已完成';

  @override
  String get scanFailed => '掃描或資料取得發生錯誤';

  @override
  String get noScan => '尚無掃描記錄';

  @override
  String get noScanHint => '此媒體來源尚未掃描，選擇資料夾後即可查看進度。';

  @override
  String get scanScope => '本次選取範圍（含子目錄影片）';

  @override
  String get visitedFolders => '已讀取目錄（僅計算目錄內影片）';

  @override
  String get noFoldersRead => '尚未讀取目錄';

  @override
  String get scanningShort => '掃描中';

  @override
  String sourceConnected(int count) {
    return '連線成功，回傳 $count 項';
  }

  @override
  String browseSource(String name) {
    return '瀏覽目錄 · $name';
  }

  @override
  String itemCount(int count) {
    return '$count 項';
  }

  @override
  String videoCount(int count) {
    return '$count 個影片';
  }

  @override
  String folderMatches(int found, int total) {
    return '符合 $found / $total 項';
  }

  @override
  String selectedScanFolders(int count) {
    return '已選掃描範圍（$count）';
  }

  @override
  String scanSelectedFolders(int count) {
    return '掃描已選目錄（$count）';
  }

  @override
  String scannedFolderCount(int count) {
    return '已掃描目錄：$count';
  }

  @override
  String indexedVideoCount(int count) {
    return '索引影片：$count';
  }

  @override
  String scanMetadataCount(int done, int total) {
    return '中繼資料：$done/$total';
  }

  @override
  String scanSummary(int matched, int review, int failed) {
    return '成功：$matched · 待複核：$review · 失敗：$failed';
  }

  @override
  String currentScanFolder(String path) {
    return '目前目錄：$path';
  }

  @override
  String get addSource => '新增媒體來源';

  @override
  String get localDirectory => '本機目錄';

  @override
  String get browseScanFolders => '瀏覽雲端或本機目錄並選取掃描資料夾';

  @override
  String get remove => '移除';

  @override
  String get removeSourceTitle => '移除媒體來源？';

  @override
  String get removeSourceBody => '僅清除索引，不刪除來源檔案。';

  @override
  String get addSourceFirst => '請先新增媒體來源';

  @override
  String get noMatchingTitles => '暫無符合的作品';

  @override
  String get searchTitles => '搜尋作品';

  @override
  String get closeSearch => '關閉搜尋';

  @override
  String get manageHidden => '管理已隱藏作品';

  @override
  String sourceCount(int count) {
    return '$count 個媒體來源';
  }

  @override
  String workCount(int count) {
    return '$count 部作品';
  }

  @override
  String get noHiddenTitles => '暫無已隱藏作品';

  @override
  String get keepHidden => '重新掃描後仍保持隱藏';

  @override
  String get restoreOnScan => '重新掃描後會自動恢復';

  @override
  String get restoreTitle => '恢復顯示';

  @override
  String get titleNotFound => '找不到作品';

  @override
  String get scanBeforeRemove => '掃描或資料取得進行中，請完成後再移除作品';

  @override
  String get removeWorkTitle => '從媒體庫移除此作品？';

  @override
  String get removeWorkBody => '僅從 Konata 媒體庫移除，不會刪除來源檔案、手動關聯和觀看進度。';

  @override
  String get rescanRestoresHint => '未勾選時，重新掃描此作品將再次顯示';

  @override
  String get removeFromLibrary => '從媒體庫移除';

  @override
  String get removeWorkFailed => '移除作品失敗，請重試';

  @override
  String get manualMatch => '手動搜尋並綁定';

  @override
  String get nameOrId => '名稱或 TMDB ID';

  @override
  String get search => '搜尋';

  @override
  String get searchFailed => '搜尋失敗，請檢查憑證和網路後重試';

  @override
  String get bindFailed => '綁定儲存失敗，請重試';

  @override
  String get editMetadata => '編輯中繼資料';

  @override
  String get workTitle => '作品標題';

  @override
  String get year => '年份';

  @override
  String get optional => '可留空';

  @override
  String get synopsis => '作品簡介';

  @override
  String get notLinked => '未綁定';

  @override
  String get bangumiIds => '關聯 Bangumi ID';

  @override
  String get bangumiIdsHint =>
      '多個 ID 以逗號分隔，例如 302189, 331887。儲存後鎖定為手動確認，不會拆分作品。';

  @override
  String get searchAndLink => '搜尋並綁定';

  @override
  String get invalidBangumiIds => '請輸入有效的 Bangumi ID';

  @override
  String get invalidTitleYear => '請輸入作品標題和有效年份';

  @override
  String get characterOrder => '角色排序';

  @override
  String get noCharactersYet => '暫無角色，請先在詳情頁載入資料';

  @override
  String get recropCover => '重新裁剪目前封面';

  @override
  String get editCover => '編輯封面';

  @override
  String get automaticCover => '恢復自動';

  @override
  String get importImage => '匯入圖片';

  @override
  String get coverFailed => '封面處理失敗，請檢查圖片與儲存空間';

  @override
  String get imageDecodeFailed => '圖片解碼失敗';

  @override
  String get cropFailed => '裁剪匯出失敗，請重試';

  @override
  String get cropPoster => '裁剪封面 · 2:3';

  @override
  String get cropHint => '拖曳調整位置 · 滾輪或雙指縮放 · 框內即最終海報';

  @override
  String get lowResImage => '原圖解析度較低，將保留原有清晰度';

  @override
  String get reset => '重設';

  @override
  String get saving => '正在儲存…';

  @override
  String get confirmSave => '確認儲存';

  @override
  String get mainFeature => '正片';

  @override
  String get extraFiles => '特典';

  @override
  String get allExtras => '全部';

  @override
  String get otherExtra => '其他';

  @override
  String get unnamedVideo => '未命名影片';

  @override
  String get unnamedWork => '未命名作品';

  @override
  String get cast => '演員';

  @override
  String get crew => '製作人員';

  @override
  String get characters => '角色';

  @override
  String get collapseList => '收起列表';

  @override
  String get fullList => '完整列表';

  @override
  String get noExtras => '暫無特典檔案';

  @override
  String get noLinkedEpisodes => '暫無已關聯正片';

  @override
  String get backToLibrary => '返回媒體庫';

  @override
  String get moreActions => '更多操作';

  @override
  String get noMainFeature => '暫無正片';

  @override
  String get startPlayback => '開始播放';

  @override
  String get noSynopsis => '暫無作品簡介';

  @override
  String get collapseSynopsis => '收起簡介';

  @override
  String get expandSynopsis => '展開簡介';

  @override
  String get unwatchedStatus => '未看';

  @override
  String get commercial => '宣傳廣告';

  @override
  String get promoVideo => '宣傳影片';

  @override
  String get cleanOpening => '無字幕片頭';

  @override
  String get cleanEnding => '無字幕片尾';

  @override
  String get discMenu => '光碟選單';

  @override
  String get specialEpisode => '特別篇';

  @override
  String episodeLabel(int number) {
    return '第$number集';
  }

  @override
  String detailEpisodeCount(int count) {
    return '$count 集';
  }

  @override
  String detailVersionCount(int count) {
    return '$count 個版本';
  }

  @override
  String resumeEpisode(String episode) {
    return '繼續播放$episode';
  }

  @override
  String get resumePlayback => '繼續播放';

  @override
  String get removeTitleAction => '刪除此作品';

  @override
  String seekSeconds(int count) {
    return '$count 秒';
  }

  @override
  String get tmdbOpenFailed => '無法開啟瀏覽器，請前往 https://www.themoviedb.org';

  @override
  String get manualEdit => '手動編輯';

  @override
  String get chooseSeason => '選擇季';

  @override
  String get chooseEpisode => '選擇集';

  @override
  String get keepMatch => '暫不改動';

  @override
  String get mappingHint => '選擇作品和季，再為檔案指定集數。更換作品時需為全部檔案指定匹配。';

  @override
  String get mappingFailed => '儲存失敗，請檢查匹配後重試';

  @override
  String get loadingMatches => '正在載入…';

  @override
  String get playbackStats => '統計數據';

  @override
  String get chapters => '章節';

  @override
  String get noChapters => '此影片沒有章節資訊';

  @override
  String get chapterReadFailed => '讀取章節失敗，請重試';

  @override
  String get statsUnavailable => '未知';

  @override
  String get subtitleJapanese => '日語';

  @override
  String get subtitleChinese => '中文（未標明簡繁）';

  @override
  String get losslessAudio => '無損';

  @override
  String get externalTrack => '外掛';

  @override
  String get statVideo => '影片編碼';

  @override
  String get statResolution => '解析度';

  @override
  String get statFps => '影格率';

  @override
  String get statOutputFps => '輸出影格率';

  @override
  String get statHwdec => '硬體解碼';

  @override
  String get statDropped => '輸出掉格';

  @override
  String get statDecoderDropped => '解碼掉格';

  @override
  String get statAudio => '音訊編碼';

  @override
  String get statSampleRate => '取樣率（Hz）';

  @override
  String get statChannels => '聲道數';

  @override
  String get statBitrate => '音訊位元率（bps）';

  @override
  String get statCache => '緩衝時長（秒）';

  @override
  String get statAvsync => '影音偏差（秒）';

  @override
  String get timelinePreview => '時間軸預覽';

  @override
  String get previewOn => '時間軸預覽已開啟';

  @override
  String get previewOff => '時間軸預覽已關閉';

  @override
  String get subtitleSimplifiedJapanese => '簡日雙語';

  @override
  String get subtitleTraditionalJapanese => '繁日雙語';

  @override
  String get containedTrack => '內封';

  @override
  String get importSubtitle => '匯入字幕';

  @override
  String trackNumber(int number) {
    return '軌道 $number';
  }

  @override
  String get exportLibraryBackup => '匯出媒體庫備份';

  @override
  String get exportLibraryBackupDescription => '包含作品、觀看紀錄與自訂封面；不包含影片及已儲存憑證。';

  @override
  String get exportLibraryBackupDone => '備份匯出成功';

  @override
  String get exportLibraryBackupFailed => '備份匯出失敗';

  @override
  String get exportLibraryBackupTooLarge => '備份檔案太大，無法在此裝置儲存';

  @override
  String get inspectLibraryBackup => '檢查備份檔案';

  @override
  String get inspectLibraryBackupDescription => '唯讀驗證備份，不匯入或修改媒體庫。';

  @override
  String get inspectLibraryBackupFailed => '備份檔案驗證失敗';

  @override
  String get playerSettings => '播放器';

  @override
  String get mpvConfiguration => '原生 MPV 設定';

  @override
  String get mpvEnable => '啟用自訂 mpv.conf 與 input.conf';

  @override
  String get mpvEnableDetail => '每次播放前讀取 mpv.conf 與 input.conf。請僅使用可信設定。';

  @override
  String get mpvNextPlayback => '變更將在下次開啟播放器時生效。';

  @override
  String get mpvEdit => '編輯';

  @override
  String get mpvImport => '匯入檔案';

  @override
  String get mpvReset => '還原空白預設設定';

  @override
  String get mpvFolderReadError => '無法讀取設定目錄。請檢查設定檔，或在播放器設定中重新選擇目錄。';

  @override
  String get mpvUseInternal => '使用應用程式內設定';

  @override
  String get fullscreen => '進入全螢幕';

  @override
  String get exitFullscreen => '離開全螢幕';

  @override
  String get mpvOpenDirectory => '選擇設定目錄';

  @override
  String get mpvError => 'MPV 設定操作失敗';

  @override
  String get mpvSave => '儲存';

  @override
  String get backupPreviewCounts => '作品 / 檔案 / 來源 / 紀錄 / 封面';

  @override
  String get confirmEpisodeIdentity => '確認劇集身分';

  @override
  String get revokeEpisodeIdentity => '撤銷身分確認';

  @override
  String get watchStateConflict => '觀看狀態有衝突';

  @override
  String get confirmEpisodeDescription => '請核對作品、季號和集號，僅在此檔案確實對應這集時確認。';

  @override
  String get historyEventsRetained => '觀看事件分開保留；刪除續播歷史不會將劇集標為未看或刪除觀看事件。';

  @override
  String get bangumiEpisodeMapping => 'Bangumi 劇集綁定';

  @override
  String get bangumiSubjectId => '作品 ID';

  @override
  String get bangumiEpisodeId => '章節 ID';

  @override
  String get bangumiEpisodeType => '章節類型';

  @override
  String get bangumiMainStory => '正片';

  @override
  String get verifyBangumiEpisode => '核驗章節';

  @override
  String get bangumiMappingDescription =>
      '請核對作品、章節標題、編號與類型。Bangumi 編號可以與 TMDB 不同，此操作僅儲存關聯。';

  @override
  String get bangumiMappingFailed => '章節核驗失敗，請檢查 ID 和類型後重試。';

  @override
  String get revokeBangumiMapping => '撤銷劇集綁定';

  @override
  String get statMpvVersion => 'MPV 版本';

  @override
  String get statHwdecSetting => '解碼設定';

  @override
  String get statPixelFormat => '解碼像素格式';

  @override
  String get statUnderlyingPixelFormat => '硬解底層像素格式';

  @override
  String get statColorMatrix => '色彩矩陣';

  @override
  String get statColorPrimaries => '色彩原色';

  @override
  String get statTransferFunction => '傳遞函數';

  @override
  String get statColorRange => '色彩範圍';

  @override
  String get statVideoOutput => '視訊輸出方式';

  @override
  String get statFilteredWidth => '濾鏡後視訊寬度';

  @override
  String get statFilteredHeight => '濾鏡後視訊高度';

  @override
  String get statCachePaused => '因緩衝暫停';

  @override
  String get statSourceDepth => '解碼分量位元深度（已識別格式）';

  @override
  String get statTextureSize => 'Flutter 紋理尺寸';

  @override
  String get statFilteredDepth => '濾鏡後分量位深';

  @override
  String get statTargetDepth => 'MPV 回報的目標位深';

  @override
  String get statTargetPrimaries => 'MPV 目標色彩原色';

  @override
  String get statTargetTransfer => 'MPV 目標傳遞函數';

  @override
  String get statPresentationDepth => '最終呈現位深（未測量）';

  @override
  String get statDecodedAudioFormat => '解碼音訊樣本格式';

  @override
  String get statOutputAudioFormat => '音訊介面樣本格式';

  @override
  String get statOutputSampleRate => '音訊介面取樣率';

  @override
  String get statOutputChannels => '音訊介面聲道配置';

  @override
  String get statAudioOutput => '音訊輸出方式';

  @override
  String get restoreLibraryBackup => '從備份還原';

  @override
  String get restoreLibraryBackupDescription =>
      '選擇 ZIP 備份，預覽後還原媒體庫、紀錄、手動封面和基本設定。';

  @override
  String get restoreLibraryBackupWarning =>
      '這會取代目前的媒體庫和播放紀錄，不會合併。還原前會自動備份目前資料；失敗時回復。\n\n影片檔案和本機擴充設定不在備份中。來源密碼需要重新填寫；跨裝置的本機目錄需要在「編輯來源」中重新選擇並授權。還原不會自動掃描或連線來源。';

  @override
  String get restoringLibraryBackup => '正在還原，請稍候…';

  @override
  String get restoreLibraryBackupDone => '還原完成。需要時請編輯來源，重新選擇目錄或填寫密碼。';

  @override
  String get restoreLibraryBackupFailed => '還原未完成，請檢查備份和可用空間後重試。';

  @override
  String get restoreLibraryBackupBusy => '請等待掃描結束後再還原備份。';

  @override
  String get previousLibraryBackup => '還原前的備份';

  @override
  String get previousLibraryBackupDescription => '保留最近兩次還原前的備份，可預覽後還原。';

  @override
  String get noPreviousLibraryBackup => '還沒有自動產生的還原前備份。';

  @override
  String get restoreCurrentLibrary => '目前媒體庫（作品 / 檔案 / 來源）';

  @override
  String get extensions => '擴充功能';

  @override
  String get extensionsDescription =>
      '在此開啟可選功能，開啟後可在「刮削服務」調整相關設定。關閉後停止相關請求並釋放暫存資源。';

  @override
  String get characterDetails => '角色與聲優';

  @override
  String get characterDetailsDescription => '在作品詳情頁顯示 Bangumi 角色與聲優資料。';

  @override
  String get voiceActorPhotos => '顯示聲優照片';

  @override
  String get creditsDetails => '真人演員與製作人員';

  @override
  String get creditsDetailsDescription => '在真人影視詳情頁顯示 TMDB 演員與製作人員。';

  @override
  String get creditsServiceSettings => '使用共用的 TMDB 憑證，點擊開啟 API 設定。';

  @override
  String get optionalFeatureFailed => '暫時無法載入或儲存，請重試。';

  @override
  String get optionalNoResults => '暫無相關資料。';

  @override
  String get animationCategory => '動畫';

  @override
  String get liveActionCategory => '真人影視';

  @override
  String get featureOff => '關閉';

  @override
  String get voiceActors => '聲優';

  @override
  String get sage => '灰綠';

  @override
  String get allWorks => '全部作品';

  @override
  String compactWorkCount(int count) {
    return '$count 部';
  }

  @override
  String get bangumiPeopleData => 'Bangumi角色/聲優資料';

  @override
  String get tmdbPeopleData => 'TMDB真人資料';

  @override
  String get peopleBar => '角色欄';

  @override
  String get peopleFallbackTmdb => '關閉 Bangumi 資料時，統一使用 TMDB 資料。';

  @override
  String get peopleFallbackHidden => '關閉 Bangumi 資料時，不顯示角色欄。';

  @override
  String get historySelectAll => '全選';

  @override
  String get historyDeselectAll => '取消全選';

  @override
  String historySelectionCount(int count) {
    return '已選 $count 項';
  }

  @override
  String deleteHistorySelectionQuestion(int count) {
    return '刪除選取的 $count 筆播放紀錄？';
  }

  @override
  String get imageCache => '圖片快取';

  @override
  String get measuringCache => '正在計算…';

  @override
  String get cacheSizeUnavailable => '暫時無法讀取';

  @override
  String get openCacheDirectory => '開啟快取目錄';

  @override
  String get cacheDirectoryUnavailable => '暫時無法開啟快取目錄。';

  @override
  String get detailBackdrop => '詳情頁背景圖';

  @override
  String get cacheSettingFailed => '設定儲存失敗，請重試。';

  @override
  String get nameOrBangumiId => '名稱或 Bangumi ID';

  @override
  String get unclassified => '待歸類';

  @override
  String get assignToWork => '歸入作品';

  @override
  String get workName => '作品名稱';

  @override
  String get createClassification => '以此名稱建立作品';

  @override
  String get classificationHint =>
      '僅調整媒體庫歸屬，不移動或重新命名原始檔案。選取同一媒體源的檔案後，可批次歸入已有作品或新建作品。';

  @override
  String get selectSourceFiles => '選取此媒體源全部檔案';
}
