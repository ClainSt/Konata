import 'dart:async';

import '../value_objects/ids.dart';

/// 跨包低频领域事件基类（所有跨 Feature 状态协同通知均须在此穷尽定义）。
///
/// 性能红线：严禁将超过 5Hz 的高频信号（如播放进度、歌词逐字扫白时钟、
/// 悬浮小窗拖拽坐标、滚动偏移量）发布至此总线；高频路径必须直连叶子监听者。
sealed class DomainEvent {
  /// 构造带 UTC 毫秒时间戳的低频领域事件。
  const DomainEvent({required this.occurredAtMs});

  /// 事件发生的 UTC 毫秒时间戳。
  final int occurredAtMs;
}

/// 媒体库作品元数据或收录状态发生变更事件。
final class LibraryWorkChangedEvent extends DomainEvent {
  /// 创建作品变更事件。
  const LibraryWorkChangedEvent({
    required this.workId,
    required this.reason,
    required super.occurredAtMs,
  });

  /// 发生变更的作品标识。
  final WorkId workId;

  /// 变更原因（例如 `scraped`、`edited`、`deleted`、`merged`）。
  final String reason;
}

/// 媒体源新增、编辑、扫描完成或删除事件。
final class MediaSourceChangedEvent extends DomainEvent {
  /// 创建媒体源变更事件。
  const MediaSourceChangedEvent({
    required this.sourceId,
    required this.reason,
    required super.occurredAtMs,
  });

  /// 发生变更的媒体源标识。
  final SourceId sourceId;

  /// 变更原因（例如 `added`、`updated`、`scanned`、`removed`）。
  final String reason;
}

/// 逻辑剧集达到完播阈值或人工标记观看状态变更事件（供第三方追番同步订阅）。
final class EpisodeCompletionChangedEvent extends DomainEvent {
  /// 创建单集完播状态变更事件。
  const EpisodeCompletionChangedEvent({
    required this.workId,
    required this.episodeId,
    required this.completed,
    required super.occurredAtMs,
  });

  /// 所属作品标识。
  final WorkId workId;

  /// 发生状态变化的逻辑剧集标识。
  final EpisodeId episodeId;

  /// 是否已标记为看完。
  final bool completed;
}

/// 跨设备同步或本地备份恢复完成事件。
final class SyncCompletedEvent extends DomainEvent {
  /// 创建同步完成事件。
  const SyncCompletedEvent({
    required this.channel,
    required this.updatedSliceIds,
    required super.occurredAtMs,
  });

  /// 同步通道标识（如 `webdav`、`local_backup`）。
  final String channel;

  /// 本次实际写入变更的切片标识集合。
  final Set<String> updatedSliceIds;
}

/// 配置切片发生变更事件。
final class PrefsSliceChangedEvent extends DomainEvent {
  /// 创建配置切片变更事件。
  const PrefsSliceChangedEvent({
    required this.namespace,
    required super.occurredAtMs,
  });

  /// 发生变更的配置命名空间。
  final String namespace;
}

/// 跨包低频领域事件总线端口。
///
/// 严禁向本总线推送超过 5Hz 的高频刷新信号（例如播放时钟、歌词扫白、拖拽坐标）。
abstract interface class DomainEventBus {
  /// 全量低频领域事件广播流。
  Stream<DomainEvent> get stream;

  /// 仅订阅特定子类型的低频领域事件。
  Stream<T> on<T extends DomainEvent>();

  /// 发布一条低频领域事件。
  void publish(DomainEvent event);

  /// 释放总线订阅资源。
  Future<void> dispose();
}

/// 纯 Dart 默认内存实现，基于广播流分发低频领域事件。
final class InMemoryDomainEventBus implements DomainEventBus {
  /// 创建内存领域事件总线。
  InMemoryDomainEventBus();

  final StreamController<DomainEvent> _controller =
      StreamController<DomainEvent>.broadcast();

  bool _disposed = false;

  @override
  Stream<DomainEvent> get stream => _controller.stream;

  @override
  Stream<T> on<T extends DomainEvent>() =>
      _controller.stream.where((event) => event is T).cast<T>();

  @override
  void publish(DomainEvent event) {
    if (_disposed || _controller.isClosed) {
      return;
    }
    _controller.add(event);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.close();
  }
}
