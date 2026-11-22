import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 作品详情页展示偏好设置（本地 SharedPreferences 持久化，实时生效）。
class DetailDisplayPreferences {
  /// 创建详情页展示偏好。
  const DetailDisplayPreferences({
    this.showTitleText = false,
    this.showTitleLogo = true,
    this.showOverview = true,
    this.showRawVideoFilename = true,
    this.showCdTab = true,
    this.showScanTab = true,
  });

  /// 详情页主视觉区是否展示文字标题（及副标题原名）。
  final bool showTitleText;

  /// 详情页主视觉区是否展示透明标题徽标（Logo）。
  final bool showTitleLogo;

  /// 详情页主视觉区是否展示作品简介正文与展开按钮。
  final bool showOverview;

  /// 选集/特典卡片上是否显示原始视频文件名。
  final bool showRawVideoFilename;

  /// 是否在作品详情页底部导航与完整列表中展示「CD」分类页签。
  final bool showCdTab;

  /// 是否在作品详情页底部导航与完整列表中展示「Scan」分类页签。
  final bool showScanTab;

  /// 复制并修改部分展示偏好字段。
  DetailDisplayPreferences copyWith({
    bool? showTitleText,
    bool? showTitleLogo,
    bool? showOverview,
    bool? showRawVideoFilename,
    bool? showCdTab,
    bool? showScanTab,
  }) {
    return DetailDisplayPreferences(
      showTitleText: showTitleText ?? this.showTitleText,
      showTitleLogo: showTitleLogo ?? this.showTitleLogo,
      showOverview: showOverview ?? this.showOverview,
      showRawVideoFilename: showRawVideoFilename ?? this.showRawVideoFilename,
      showCdTab: showCdTab ?? this.showCdTab,
      showScanTab: showScanTab ?? this.showScanTab,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DetailDisplayPreferences &&
        other.showTitleText == showTitleText &&
        other.showTitleLogo == showTitleLogo &&
        other.showOverview == showOverview &&
        other.showRawVideoFilename == showRawVideoFilename &&
        other.showCdTab == showCdTab &&
        other.showScanTab == showScanTab;
  }

  @override
  int get hashCode => Object.hash(
    showTitleText,
    showTitleLogo,
    showOverview,
    showRawVideoFilename,
    showCdTab,
    showScanTab,
  );
}

/// 详情页展示偏好状态管理器。
class DetailDisplayPreferencesNotifier
    extends Notifier<DetailDisplayPreferences> {
  /// 创建详情页展示偏好状态管理器。
  DetailDisplayPreferencesNotifier({
    this.initialState,
    this.enablePersistence = true,
  });

  /// 可选初始状态（供单元测试直接注入预置展示偏好）。
  final DetailDisplayPreferences? initialState;

  /// 是否启用本地 SharedPreferences 持久化（单元测试可置 `false`）。
  final bool enablePersistence;

  @override
  DetailDisplayPreferences build() {
    if (enablePersistence) {
      unawaited(_loadFromPrefs());
    }
    return initialState ?? const DetailDisplayPreferences();
  }

  static const String _keyShowTitleText = 'konata.detail.show_title_text';
  static const String _keyShowTitleLogo = 'konata.detail.show_title_logo';
  static const String _keyShowOverview = 'konata.detail.show_overview';
  static const String _keyShowRawVideoFilename =
      'konata.detail.show_raw_video_filename';
  static const String _keyShowCdTab = 'konata.detail.show_cd_tab';
  static const String _keyShowScanTab = 'konata.detail.show_scan_tab';

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = DetailDisplayPreferences(
        showTitleText: prefs.getBool(_keyShowTitleText) ?? false,
        showTitleLogo: prefs.getBool(_keyShowTitleLogo) ?? true,
        showOverview: prefs.getBool(_keyShowOverview) ?? true,
        showRawVideoFilename: prefs.getBool(_keyShowRawVideoFilename) ?? true,
        showCdTab: prefs.getBool(_keyShowCdTab) ?? true,
        showScanTab: prefs.getBool(_keyShowScanTab) ?? true,
      );
    } catch (error) {
      // 无 SharedPreferences 插件环境的纯单元测试保持默认配置即可。
      developer.log('可恢复异常已记录', name: 'konata.detail_display_preferences_provider', error: error);
    }
  }

  /// 切换详情页文字标题显示。
  Future<void> setShowTitleText(bool value) async {
    state = state.copyWith(showTitleText: value);
    await _persistBool(_keyShowTitleText, value);
  }

  /// 切换详情页标题徽标（Logo）显示。
  Future<void> setShowTitleLogo(bool value) async {
    state = state.copyWith(showTitleLogo: value);
    await _persistBool(_keyShowTitleLogo, value);
  }

  /// 切换详情页作品简介显示。
  Future<void> setShowOverview(bool value) async {
    state = state.copyWith(showOverview: value);
    await _persistBool(_keyShowOverview, value);
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
    } catch (error) {
      // 忽略测试环境插件未注册异常。
      developer.log('可恢复异常已记录', name: 'konata.detail_display_preferences_provider', error: error);
    }
  }
}

/// 全局详情页展示偏好 Provider。
final detailDisplayPreferencesProvider =
    NotifierProvider<
      DetailDisplayPreferencesNotifier,
      DetailDisplayPreferences
    >(DetailDisplayPreferencesNotifier.new);
