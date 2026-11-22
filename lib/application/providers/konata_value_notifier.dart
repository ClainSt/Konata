import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 轻量级强类型可变值状态容器（基于 Riverpod 3.x 标准 [Notifier]，零遗留依赖）。
///
/// 统一承接导航页签、搜索词、弹窗收展与悬浮小窗几何等轻量 UI/会话值状态，
/// 同时对外提供 `state` 读写与函数式 [update] 接口。
class KonataValueNotifier<T> extends Notifier<T> {
  /// 使用初始值工厂创建状态容器（每次构建或重置时惰性计算初始值）。
  KonataValueNotifier(this._initialValueBuilder);

  /// 使用固定初始值创建状态容器。
  factory KonataValueNotifier.value(T initialValue) =>
      KonataValueNotifier<T>(() => initialValue);

  final T Function() _initialValueBuilder;

  @override
  T build() => _initialValueBuilder();

  /// 当前状态容器是否仍处于活跃挂载周期。
  bool get isMounted => ref.mounted;

  /// 读取当前状态值。
  @override
  T get state => super.state;

  /// 更新当前状态值并在值变更时通知订阅者。
  @override
  set state(T value) => super.state = value;

  /// 基于当前状态执行函数式更新并返回最新状态。
  T update(T Function(T current) updater) {
    final next = updater(super.state);
    super.state = next;
    return next;
  }
}

/// 关闭 Riverpod 3.x 根作用域默认指数退避自动重试策略。
///
/// Konata 的网络链路（TMDB / Bangumi / Fanart / WebDAV / SMB）均已内置显式超时、
/// 单层重试预算与域名冷却熔断器；在根 [ProviderScope] 显式返回 `null` 可避免双层放大重试。
Duration? konataNoProviderRetry(int retryCount, Object error) => null;
