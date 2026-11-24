import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/lyric_candidate.dart';
import '../domain/ttml_lyric_converter.dart';
import 'lyric_http_transport.dart';
import 'netease_lyric_provider.dart';

/// AMLL TTML 开源逐字歌词库：按网易云歌曲标识直取单首 TTML，多镜像对冲竞速。
class AmllLyricProvider {
  /// 创建检索器。
  const AmllLyricProvider(
    this._transport, {
    this.mirrors = LyricLookupConfig.amllNcmLyricMirrors,
    this.hedgeDelay = LyricLookupConfig.amllHedgeDelay,
  });

  final LyricHttpTransport _transport;

  /// 镜像基址列表（按优先级排列）。
  final List<String> mirrors;

  /// 前一镜像未完成时启动下一镜像请求的等待时长。
  final Duration hedgeDelay;

  /// 拉取并转换与网易云歌曲对应的逐字歌词；库中不存在或全部镜像失败时返回 `null`。
  Future<LyricCandidate?> fetchByNeteaseHit(NeteaseSongHit hit) async {
    final body = await _fetchFirstSuccessful('${hit.id}.ttml');
    if (body == null) return null;
    final converted = TtmlLyricConverter.convert(body);
    if (converted.lrc.trim().isEmpty) return null;
    return LyricCandidate(
      source: LyricSource.amll,
      sourceId: hit.id,
      title: hit.title,
      artist: hit.artist,
      album: hit.album,
      durationSeconds: hit.durationSeconds,
      lrcContent: converted.lrc,
      hasTranslation: converted.hasTranslation,
      hasWordTiming: converted.hasWordTiming,
      hasRomaji: converted.hasRomaji,
    );
  }

  /// 依次（带对冲延迟）向各镜像发起请求，返回首个 200 响应正文；任一镜像明确 404 即判定库中不存在。
  Future<String?> _fetchFirstSuccessful(String fileName) {
    if (mirrors.isEmpty) return Future.value(null);
    final completer = Completer<String?>();
    var pending = 0;
    var launched = 0;
    final timers = <Timer>[];

    void finish(String? value) {
      if (completer.isCompleted) return;
      for (final t in timers) {
        t.cancel();
      }
      completer.complete(value);
    }

    void launch(int index) {
      if (completer.isCompleted || index >= mirrors.length) return;
      launched = index + 1;
      pending++;
      _transport
          .get(
            Uri.parse('${mirrors[index]}$fileName'),
            headers: const {'Accept': '*/*'},
            timeout: LyricLookupConfig.requestTimeout,
          )
          .then<void>(
            (http.Response resp) {
              pending--;
              if (resp.statusCode == 200) {
                finish(utf8.decode(resp.bodyBytes, allowMalformed: true));
              } else if (resp.statusCode == 404) {
                finish(null);
              } else {
                launch(launched);
                if (pending == 0 && launched >= mirrors.length) finish(null);
              }
            },
            onError: (Object _) {
              pending--;
              launch(launched);
              if (pending == 0 && launched >= mirrors.length) finish(null);
            },
          );
      if (index + 1 < mirrors.length) {
        timers.add(Timer(hedgeDelay, () => launch(launched)));
      }
    }

    launch(0);
    return completer.future;
  }
}
