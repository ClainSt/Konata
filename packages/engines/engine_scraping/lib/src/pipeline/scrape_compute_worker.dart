import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../matching/directory_grouper.dart';
import '../matching/work_matcher.dart';
import '../models/tmdb_models.dart';
import '../parsing/release_groups.dart';
import '../scraping/bangumi_models.dart';
import '../scraping/bangumi_tmdb_index.dart';
import '../scraping/scrape_domain_adapter.dart';
import '../scraping/work_matcher.dart' as legacy;

/// 后台 Isolate 纯计算工作器。
///
/// 将耗时较大的目录聚合、合集拆簇、BDRip 词法解析与候选打分放入独立 Isolate 执行，避免阻塞 UI 线程。
/// 批量扫描期间可通过 [openSession] 创建可复用的常驻 Isolate 会话，消除数百次冷启动开销。
class ScrapeComputeWorker {
  /// 创建计算工作器实例。
  const ScrapeComputeWorker({this.useIsolate = true});

  /// 是否启用独立 Isolate 执行；单元测试中也可按需切换。
  final bool useIsolate;

  /// 开启可复用的计算会话；调用方需在扫描结束的 `finally` 块中调用 [ScrapeComputeSession.dispose]。
  ScrapeComputeSession openSession() =>
      ScrapeComputeSession(useIsolate: useIsolate);

  /// 在后台 Isolate 中执行目录抗碎裂归拢、多作品合集拆簇与槽位预解析。
  Future<List<GroupedWorkFolder>> groupFiles({
    required String sourceId,
    required List<ScannedFileInput> files,
    Map<String, String> nfoByFolder = const {},
    Map<String, String> localCoverByFolder = const {},
  }) async {
    final groups = await ReleaseGroups.prepare();
    if (!useIsolate) {
      return Future.value(
        ScrapeDomainAdapter.groupAndSplitFiles(
          sourceId: sourceId,
          files: files,
          nfoByFolder: nfoByFolder,
          localCoverByFolder: localCoverByFolder,
        ),
      );
    }
    return Isolate.run(() {
      ReleaseGroups.usePrepared(groups);
      return ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: sourceId,
        files: files,
        nfoByFolder: nfoByFolder,
        localCoverByFolder: localCoverByFolder,
      );
    });
  }

  /// 在后台 Isolate 中执行 Bangumi 候选多维打分。
  Future<({
    legacy.MatchTier tier,
    ScoredBangumiCandidate? best,
    List<ScoredBangumiCandidate> topCandidates,
  })>
  evaluateBangumiMatch(
    GroupedWorkFolder folder,
    List<BangumiSubjectCandidate> candidates,
  ) async {
    final groups = await ReleaseGroups.prepare();
    if (!useIsolate) {
      final res = ScrapeDomainAdapter.evaluateBangumiMatch(folder, candidates);
      return (
        tier: res.tier,
        best: res.best,
        topCandidates: res.topCandidates,
      );
    }
    return Isolate.run(() {
      ReleaseGroups.usePrepared(groups);
      final res = ScrapeDomainAdapter.evaluateBangumiMatch(folder, candidates);
      return (
        tier: res.tier,
        best: res.best,
        topCandidates: res.topCandidates,
      );
    });
  }

  /// 在后台 Isolate 中执行作品候选多维打分、季级身份消歧与漏斗决策（含 Bangumi 联合互证）。
  Future<MatchDecision> evaluateMatch(
    GroupedWorkFolder folder,
    List<TmdbWorkDetail> candidates, {
    List<BangumiSubjectCandidate> bangumiCandidates = const [],
    BangumiTmdbIndex? mappingIndex,
  }) async {
    final groups = await ReleaseGroups.prepare();
    final activeMapping = mappingIndex ?? BangumiTmdbIndex.bundledSnapshot?.index;
    if (!useIsolate) {
      return Future.value(
        ScrapeDomainAdapter.evaluateMatch(
          folder,
          candidates,
          bangumiCandidates: bangumiCandidates,
          mappingIndex: activeMapping,
        ),
      );
    }
    return Isolate.run(() {
      ReleaseGroups.usePrepared(groups);
      return ScrapeDomainAdapter.evaluateMatch(
        folder,
        candidates,
        bangumiCandidates: bangumiCandidates,
        mappingIndex: activeMapping,
      );
    });
  }
}

/// 单次扫描会话内复用的常驻后台计算工作器（懒启动单条 Isolate，结束即彻底回收端口与线程）。
class ScrapeComputeSession implements ScrapeComputeWorker {
  /// 创建可复用计算会话。
  ScrapeComputeSession({required this.useIsolate});

  @override
  final bool useIsolate;

  Isolate? _isolate;
  SendPort? _workerPort;
  ReceivePort? _handshakePort;
  ReceivePort? _responsePort;
  StreamSubscription<Object?>? _responseSub;
  Future<SendPort>? _starting;
  bool _disposed = false;
  int _nextRequestId = 1;
  final Map<int, Completer<Object?>> _pending = {};

  @override
  ScrapeComputeSession openSession() => this;

  @override
  Future<List<GroupedWorkFolder>> groupFiles({
    required String sourceId,
    required List<ScannedFileInput> files,
    Map<String, String> nfoByFolder = const {},
    Map<String, String> localCoverByFolder = const {},
  }) async {
    if (!useIsolate) {
      await ReleaseGroups.prepare();
      return ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: sourceId,
        files: files,
        nfoByFolder: nfoByFolder,
        localCoverByFolder: localCoverByFolder,
      );
    }
    final res = await _dispatch(
      _GroupFilesTask(
        sourceId: sourceId,
        files: files,
        nfoByFolder: nfoByFolder,
        localCoverByFolder: localCoverByFolder,
      ),
    );
    return res as List<GroupedWorkFolder>;
  }

  @override
  Future<({
    legacy.MatchTier tier,
    ScoredBangumiCandidate? best,
    List<ScoredBangumiCandidate> topCandidates,
  })>
  evaluateBangumiMatch(
    GroupedWorkFolder folder,
    List<BangumiSubjectCandidate> candidates,
  ) async {
    if (!useIsolate) {
      await ReleaseGroups.prepare();
      final res = ScrapeDomainAdapter.evaluateBangumiMatch(folder, candidates);
      return (
        tier: res.tier,
        best: res.best,
        topCandidates: res.topCandidates,
      );
    }
    final res = await _dispatch(
      _EvalBangumiTask(folder: folder, candidates: candidates),
    );
    return res as ({
      legacy.MatchTier tier,
      ScoredBangumiCandidate? best,
      List<ScoredBangumiCandidate> topCandidates,
    });
  }

  @override
  Future<MatchDecision> evaluateMatch(
    GroupedWorkFolder folder,
    List<TmdbWorkDetail> candidates, {
    List<BangumiSubjectCandidate> bangumiCandidates = const [],
    BangumiTmdbIndex? mappingIndex,
  }) async {
    final activeMapping = mappingIndex ?? BangumiTmdbIndex.bundledSnapshot?.index;
    if (!useIsolate) {
      await ReleaseGroups.prepare();
      return ScrapeDomainAdapter.evaluateMatch(
        folder,
        candidates,
        bangumiCandidates: bangumiCandidates,
        mappingIndex: activeMapping,
      );
    }
    final res = await _dispatch(
      _EvalMatchTask(
        folder: folder,
        candidates: candidates,
        bangumiCandidates: bangumiCandidates,
        mappingIndex: activeMapping,
      ),
    );
    return res as MatchDecision;
  }

  Future<Object?> _dispatch(_ComputeTask task) async {
    final groups = await ReleaseGroups.prepare();
    if (_disposed) {
      return _executeTaskSync(task);
    }
    final port = await _ensureWorkerPort(groups);
    if (_disposed) {
      return _executeTaskSync(task);
    }
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send((id: id, task: task));
    return completer.future;
  }

  Future<SendPort> _ensureWorkerPort(Uint8List groups) {
    if (_workerPort != null) return Future.value(_workerPort!);
    if (_starting != null) return _starting!;

    final startCompleter = Completer<SendPort>();
    _starting = startCompleter.future;
    final handshakePort = ReceivePort();
    _handshakePort = handshakePort;
    final responsePort = ReceivePort();
    _responsePort = responsePort;

    _responseSub = responsePort.listen((message) {
      if (message is! ({int id, Object? value, Object? error})) return;
      final pending = _pending.remove(message.id);
      if (pending == null || pending.isCompleted) return;
      if (message.error != null) {
        pending.completeError(message.error!);
      } else {
        pending.complete(message.value);
      }
    });

    Isolate.spawn(
      _persistentWorkerMain,
      (handshake: handshakePort.sendPort, reply: responsePort.sendPort, groups: groups),
      debugName: 'konata_scrape_compute',
    ).then((iso) async {
      _isolate = iso;
      final workerSendPort = await handshakePort.first as SendPort;
      handshakePort.close();
      if (identical(_handshakePort, handshakePort)) {
        _handshakePort = null;
      }
      if (_disposed) {
        iso.kill(priority: Isolate.immediate);
        if (!startCompleter.isCompleted) {
          startCompleter.completeError(StateError('计算会话已释放'));
        }
        return;
      }
      _workerPort = workerSendPort;
      if (!startCompleter.isCompleted) {
        startCompleter.complete(workerSendPort);
      }
    }).catchError((Object error, StackTrace stackTrace) {
      handshakePort.close();
      if (identical(_handshakePort, handshakePort)) {
        _handshakePort = null;
      }
      _starting = null;
      if (!startCompleter.isCompleted) {
        startCompleter.completeError(error, stackTrace);
      }
    });

    return startCompleter.future;
  }

  /// 释放常驻 Isolate 与通信端口，并终止所有未决回调，杜绝泄漏。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final port = _workerPort;
    _workerPort = null;
    if (port != null) {
      port.send(null);
    }
    final iso = _isolate;
    _isolate = null;
    iso?.kill(priority: Isolate.immediate);
    _handshakePort?.close();
    _handshakePort = null;
    await _responseSub?.cancel();
    _responseSub = null;
    _responsePort?.close();
    _responsePort = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('后台计算会话已关闭'));
      }
    }
    _pending.clear();
  }
}

sealed class _ComputeTask {
  const _ComputeTask();
}

final class _GroupFilesTask extends _ComputeTask {
  const _GroupFilesTask({
    required this.sourceId,
    required this.files,
    required this.nfoByFolder,
    required this.localCoverByFolder,
  });

  final String sourceId;
  final List<ScannedFileInput> files;
  final Map<String, String> nfoByFolder;
  final Map<String, String> localCoverByFolder;
}

final class _EvalBangumiTask extends _ComputeTask {
  const _EvalBangumiTask({required this.folder, required this.candidates});

  final GroupedWorkFolder folder;
  final List<BangumiSubjectCandidate> candidates;
}

final class _EvalMatchTask extends _ComputeTask {
  const _EvalMatchTask({
    required this.folder,
    required this.candidates,
    required this.bangumiCandidates,
    required this.mappingIndex,
  });

  final GroupedWorkFolder folder;
  final List<TmdbWorkDetail> candidates;
  final List<BangumiSubjectCandidate> bangumiCandidates;
  final BangumiTmdbIndex? mappingIndex;
}

Object? _executeTaskSync(_ComputeTask task) {
  switch (task) {
    case _GroupFilesTask():
      return ScrapeDomainAdapter.groupAndSplitFiles(
        sourceId: task.sourceId,
        files: task.files,
        nfoByFolder: task.nfoByFolder,
        localCoverByFolder: task.localCoverByFolder,
      );
    case _EvalBangumiTask():
      final res = ScrapeDomainAdapter.evaluateBangumiMatch(
        task.folder,
        task.candidates,
      );
      return (
        tier: res.tier,
        best: res.best,
        topCandidates: res.topCandidates,
      );
    case _EvalMatchTask():
      return ScrapeDomainAdapter.evaluateMatch(
        task.folder,
        task.candidates,
        bangumiCandidates: task.bangumiCandidates,
        mappingIndex: task.mappingIndex,
      );
  }
}

void _persistentWorkerMain(
  ({SendPort handshake, SendPort reply, Uint8List groups}) ports,
) {
  ReleaseGroups.usePrepared(ports.groups);
  final inbox = ReceivePort();
  ports.handshake.send(inbox.sendPort);
  inbox.listen((message) {
    if (message == null) {
      inbox.close();
      return;
    }
    if (message is! ({int id, _ComputeTask task})) return;
    try {
      final result = _executeTaskSync(message.task);
      ports.reply.send((id: message.id, value: result, error: null));
    } catch (error) {
      try {
        ports.reply.send((id: message.id, value: null, error: error));
      } catch (_) {
        ports.reply.send((
          id: message.id,
          value: null,
          error: StateError(error.toString()),
        ));
      }
    }
  });
}
