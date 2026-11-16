import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 作品详情页展示偏好设置（本地 SharedPreferences 持久化，实时生效）。
class DetailDisplayPreferences {
  /// 创建详情页展示偏好。
  const DetailDisplayPreferences({
    this.showRawVideoFilename = true,
    this.showCdTab = true,
    this.showScanTab = true,
  });

  /// 选集/特典卡片上是否显示原始视频文件名。
  final bool showRawVideoFilename;

  /// 是否在作品详情页底部导航与完整列表中展示「CD」分类页签。
  final bool showCdTab;

  /// 是否在作品详情页底部导航与完整列表中展示「Scan」分类页签。
  final bool showScanTab;

  /// 复制并修改部分展示偏好字段。
  DetailDisplayPreferences copyWith({
    bool? showRawVideoFilename,
    bool? showCdTab,
    bool? showScanTab,
  }) {
    return DetailDisplayPreferences(
      showRawVideoFilename: showRawVideoFilename ?? this.showRawVideoFilename,
      showCdTab: showCdTab ?? this.showCdTab,
      showScanTab: showScanTab ?? this.showScanTab,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DetailDisplayPreferences &&
        other.showRawVideoFilename == showRawVideoFilename &&
        other.showCdTab == showCdTab &&
        other.showScanTab == showScanTab;
  }

  @override
  int get hashCode =>
      Object.hash(showRawVideoFilename, showCdTab, showScanTab);
}

/// 详情页展示偏好状态管理器。
class DetailDisplayPreferencesNotifier
    extends StateNotifier<DetailDisplayPreferences> {
  /// 初始化并异步加载本地持久化配置。
  DetailDisplayPreferencesNotifier()
    : super(const DetailDisplayPreferences()) {
    _loadFromPrefs();
  }

  static const String _keyShowRawVideoFilename =
      'konata.detail.show_raw_video_filename';
  static const String _keyShowCdTab = 'konata.detail.show_cd_tab';
  static const String _keyShowScanTab = 'konata.detail.show_scan_tab';

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      state = DetailDisplayPreferences(
        showRawVideoFilename:
            prefs.getBool(_keyShowRawVideoFilename) ?? true,
        showCdTab: prefs.getBool(_keyShowCdTab) ?? true,
        showScanTab: prefs.getBool(_keyShowScanTab) ?? true,
      );
    } catch (_) {
      // 无 SharedPreferences 插件环境的纯单元测试保持默认配置即可。
    }
  }

  /// 切换选集/特典卡片原始文件名显示。
  Future<void> setShowRawVideoFilename(bool value) async {
    state = state.copyWith(showRawVideoFilename: value);
    await _persistBool(_keyShowRawVideoFilename, value);
  }

  /// 切换详情页「CD」页签显示。
  Future<void> setShowCdTab(bool value) async {
    state = state.copyWith(showCdTab: value);
    await _persistBool(_keyShowCdTab, value);
  }

  /// 切换详情页「Scan」页签显示。
  Future<void> setShowScanTab(bool value) async {
    state = state.copyWith(showScanTab: value);
    await _persistBool(_keyShowScanTab, value);
  }

  Future<void> _persistBool(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {
      // 忽略测试环境插件未注册异常。
    }
  }
}

/// 全局详情页展示偏好 Provider。
final detailDisplayPreferencesProvider =
    StateNotifierProvider<
      DetailDisplayPreferencesNotifier,
      DetailDisplayPreferences
    >((ref) => DetailDisplayPreferencesNotifier());
