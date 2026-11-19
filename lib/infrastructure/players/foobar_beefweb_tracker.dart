import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;

/// 外部音频进度持久化回调签名。
typedef FoobarPersistCallback =
    Future<void> Function(
      int positionSeconds,
      int durationSeconds, {
      required bool isFinal,
    });

/// 基于 foobar2000 `foo_beefweb` 本地 HTTP 接口的秒级进度追踪与续播控制器。
class FoobarBeefwebTracker {
  const FoobarBeefwebTracker._();

  /// 默认 Beefweb 本地回环地址。
  static const String defaultBaseUrl = 'http://127.0.0.1:8880';

  /// 追踪 foobar2000 播放生命周期并回写秒级进度。
  ///
  /// 返回值表示追踪结束时是否可立即注销远程流会话：
  /// - 当已接入 Beefweb 或独立窗口进程自然退出时返回 `true`；
  /// - 当未安装 Beefweb 且命令行子进程因后台常驻单实例转发而秒退时返回 `false`，
  ///   交由 `LocalStreamBridge` 基于 `activeStreams` 引用计数与空闲回收器安全托管，避免断流或弹 CMD 黑框。
  static Future<bool> trackProcess({
    required String targetUrlOrPath,
    required Future<int> exitCodeFuture,
    required FoobarPersistCallback onPersist,
    int startSeconds = 0,
    bool keepRemoteSessionAlive = false,
    String baseUrl = defaultBaseUrl,
  }) async {
    final launchedAt = DateTime.now();
    var processExited = false;
    var exitedFast = false;

    unawaited(
      exitCodeFuture
          .then((_) {
            processExited = true;
            exitedFast =
                DateTime.now().difference(launchedAt) <
                const Duration(seconds: 4);
          })
          .catchError((_) {
            processExited = true;
          }),
    );

    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500)
      ..findProxy = (_) => 'DIRECT';

    var lastPos = startSeconds > 0 ? startSeconds : 0;
    var lastDur = 0;
    var lastPersistAt = DateTime.fromMillisecondsSinceEpoch(0);
    var hasObservedTarget = false;
    var seekApplied = startSeconds <= 5;
    var consecutiveMisses = 0;
    var beefwebAvailable = false;

    try {
      while (true) {
        final snapshot = await _queryActiveState(client, baseUrl);
        if (snapshot == null) {
          consecutiveMisses++;
          if (!beefwebAvailable) {
            if (processExited || consecutiveMisses >= 4) {
              break;
            }
          } else if (consecutiveMisses >= 3) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }

        beefwebAvailable = true;
        consecutiveMisses = 0;

        final state = snapshot.playbackState;
        final isMatch = _matchesTarget(
          activePath: snapshot.path,
          targetUrlOrPath: targetUrlOrPath,
        );

        if ((state == 'playing' || state == 'paused') && isMatch) {
          hasObservedTarget = true;

          if (!seekApplied && snapshot.durationSeconds > startSeconds) {
            seekApplied = true;
            await _postSeek(client, baseUrl, startSeconds);
            await Future<void>.delayed(const Duration(milliseconds: 600));
            continue;
          }

          if (snapshot.positionSeconds >= 0) {
            lastPos = snapshot.positionSeconds;
          }
          if (snapshot.durationSeconds > 0) {
            lastDur = snapshot.durationSeconds;
          }

          final now = DateTime.now();
          if (lastDur > 0 &&
              now.difference(lastPersistAt) >= const Duration(seconds: 4)) {
            lastPersistAt = now;
            await onPersist(lastPos, lastDur, isFinal: false);
          }
        } else if (hasObservedTarget) {
          if (state == 'stopped') {
            if (lastDur > 0 && (lastDur - lastPos).abs() <= 5) {
              lastPos = lastDur;
            }
            break;
          }
          if (!isMatch && snapshot.path.isNotEmpty) {
            break;
          }
        }

        if (processExited && !exitedFast) {
          break;
        }

        if (!hasObservedTarget &&
            processExited &&
            DateTime.now().difference(launchedAt) >
                const Duration(seconds: 8)) {
          break;
        }

        await Future<void>.delayed(const Duration(seconds: 2));
      }

      if (hasObservedTarget && lastDur > 0) {
        await onPersist(lastPos, lastDur, isFinal: true);
        return true;
      }

      if (!beefwebAvailable) {
        if (!processExited) {
          await exitCodeFuture;
          exitedFast =
              DateTime.now().difference(launchedAt) <
              const Duration(seconds: 4);
        }
        if (exitedFast && keepRemoteSessionAlive) {
          return false;
        }
      }
      return true;
    } finally {
      client.close(force: true);
    }
  }

  static Future<_BeefwebSnapshot?> _queryActiveState(
    HttpClient client,
    String baseUrl,
  ) async {
    try {
      final uri = Uri.parse(
        '$baseUrl/api/player?columns=%25path%25,%25title%25',
      );
      final req = await client
          .getUrl(uri)
          .timeout(const Duration(milliseconds: 800));
      final resp = await req.close().timeout(const Duration(milliseconds: 800));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.drain<void>();
        return null;
      }
      final raw = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(milliseconds: 800));
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final player = decoded['player'];
      if (player is! Map) return null;

      final playbackState = player['playbackState']?.toString() ?? '';
      final activeItem = player['activeItem'];
      var posSec = 0;
      var durSec = 0;
      var itemPath = '';

      if (activeItem is Map) {
        final rawPos = activeItem['position'];
        final rawDur = activeItem['duration'];
        if (rawPos is num && rawPos.isFinite && rawPos >= 0) {
          posSec = rawPos.round();
        }
        if (rawDur is num && rawDur.isFinite && rawDur > 0) {
          durSec = rawDur.round();
        }
        final cols = activeItem['columns'];
        if (cols is List && cols.isNotEmpty && cols.first != null) {
          itemPath = cols.first.toString();
        }
      }

      return _BeefwebSnapshot(
        playbackState: playbackState,
        positionSeconds: posSec,
        durationSeconds: durSec,
        path: itemPath,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _postSeek(
    HttpClient client,
    String baseUrl,
    int positionSeconds,
  ) async {
    try {
      final uri = Uri.parse('$baseUrl/api/player');
      final req = await client
          .postUrl(uri)
          .timeout(const Duration(milliseconds: 800));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(<String, Object>{'position': positionSeconds}));
      final resp = await req.close().timeout(const Duration(milliseconds: 800));
      await resp.drain<void>().timeout(const Duration(milliseconds: 800));
    } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.foobar_beefweb_tracker', error: error);
    }
  }

  static bool _matchesTarget({
    required String activePath,
    required String targetUrlOrPath,
  }) {
    if (activePath.trim().isEmpty) return true;
    final normActive = _normalizeComparable(activePath);
    final normTarget = _normalizeComparable(targetUrlOrPath);
    if (normActive == normTarget) return true;

    if (normTarget.endsWith('.cue')) {
      final targetDir = _parentDir(normTarget);
      final activeDir = _parentDir(normActive);
      if (targetDir.isNotEmpty && targetDir == activeDir) {
        return true;
      }
    }
    return false;
  }

  static String _normalizeComparable(String input) {
    var s = input.trim();
    try {
      s = Uri.decodeFull(s);
    } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.foobar_beefweb_tracker', error: error);
    }
    return s.replaceAll('\\', '/').toLowerCase();
  }

  static String _parentDir(String normalized) {
    final idx = normalized.lastIndexOf('/');
    return idx > 0 ? normalized.substring(0, idx) : '';
  }
}

class _BeefwebSnapshot {
  const _BeefwebSnapshot({
    required this.playbackState,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.path,
  });

  final String playbackState;
  final int positionSeconds;
  final int durationSeconds;
  final String path;
}
