import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'metadata_servers.dart';
import 'metadata_http.dart';
import 'metadata.dart';
import 'image_store.dart';
import 'debug_log.dart';

enum DiagnosticStatus { connected, partial, failed }

enum DiagnosticIssue {
  none,
  credentials,
  authentication,
  timeout,
  tls,
  network,
  invalid,
  http,
  unknown,
}

class ConnectionReport {
  const ConnectionReport({
    required this.status,
    this.issue = DiagnosticIssue.none,
    required this.details,
  });
  final DiagnosticStatus status;
  final DiagnosticIssue issue;
  final String details;
}

class _DiagnosticFailure implements Exception {
  const _DiagnosticFailure(this.issue);
  final DiagnosticIssue issue;
}

class ConnectionDiagnostic {
  static Future<ConnectionReport> test(
    int index,
    List<String> addresses, {
    bool trust = false,
    http.Client? client,
  }) async {
    final watch = Stopwatch()..start();
    final c = MetadataHttp(inner: client, raw: true, trustCustom: trust);
    final events = <String>[];
    Future<dynamic> json(int provider, String path) async {
      var uri = MetadataServers.endpoint(
        provider,
        path,
        base: addresses[provider],
      );
      final headers = <String, String>{'Accept': 'application/json'};
      if (provider == 0) {
        final auth = Metadata.credentials;
        if (!auth.isConfigured) {
          throw const _DiagnosticFailure(DiagnosticIssue.credentials);
        }
        if (auth.mode == 'apiKey') {
          uri = uri.replace(
            queryParameters: {
              ...uri.queryParameters,
              'api_key': auth.value.trim(),
            },
          );
        }
        headers.addAll(auth.headers);
      }
      final response = await c.get(uri, headers: headers);
      events.add('host=${uri.host} HTTP ${response.statusCode}');
      if (response.statusCode == 401) {
        throw const _DiagnosticFailure(DiagnosticIssue.authentication);
      }
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      return jsonDecode(utf8.decode(response.bodyBytes));
    }

    String imageUrl(String raw, int provider) {
      final uri = Uri.parse(raw);
      if (provider == 1) {
        return MetadataServers.endpoint(
          1,
          'original$raw',
          base: addresses[1],
        ).toString();
      }
      final host = Uri.parse(addresses[3]).host;
      if (uri.host == host) return raw;
      if (!['lain.bgm.tv', 'lain.bangumi.lat'].contains(uri.host)) {
        throw const FormatException('无法识别的 Bangumi 图片来源');
      }
      return MetadataServers.endpoint(
        3,
        uri.path,
        base: addresses[3],
      ).replace(query: uri.hasQuery ? uri.query : null).toString();
    }

    Future<void> image(String url) async {
      final bytes = await ImageStore.download(url, client: c);
      events.add(
        'host=${Uri.parse(url).host} HTTP 200 image decoded ${bytes.length} bytes',
      );
    }

    try {
      for (final i in {index, if (index.isOdd) index - 1}) {
        MetadataServers.normalize(addresses[i], i);
      }
      if (index <= 1) {
        final body = await json(0, 'tv/100565?language=zh-CN');
        if (body is! Map ||
            body['id'] != 100565 ||
            (body['name'] ?? '').toString().isEmpty ||
            !(body['poster_path'] ?? '').toString().startsWith('/')) {
          throw const FormatException('作品 JSON 字段不完整');
        }
        if (index == 1) await image(imageUrl(body['poster_path'], 1));
      } else {
        final subject = await json(2, 'subjects/302189');
        if (subject is! Map ||
            subject['id'] != 302189 ||
            (subject['name'] ?? '').toString().isEmpty) {
          throw const FormatException('作品 JSON 无效');
        }
        if (index == 3) {
          await image(imageUrl(subject['images']['large'], 3));
        }
      }
      return ConnectionReport(
        status: DiagnosticStatus.connected,
        details: '${events.join('\n')}\n${watch.elapsedMilliseconds} ms',
      );
    } catch (e) {
      DebugLog.write(
        'ConnectionTest',
        'service=$index ${_error(e)}',
        level: 'WARN',
      );
      return ConnectionReport(
        status: DiagnosticStatus.failed,
        issue: _issue(e),
        details:
            '${_error(e)}\n${events.join('\n')}\n${watch.elapsedMilliseconds} ms',
      );
    } finally {
      c.close();
    }
  }

  static DiagnosticIssue _issue(Object e) => switch (e) {
    _DiagnosticFailure() => e.issue,
    TimeoutException() => DiagnosticIssue.timeout,
    HandshakeException() => DiagnosticIssue.tls,
    SocketException() => DiagnosticIssue.network,
    FormatException() => DiagnosticIssue.invalid,
    HttpException() => DiagnosticIssue.http,
    _ => DiagnosticIssue.unknown,
  };

  // Technical details contain no credentials or full request URLs.
  static String _error(Object e) => switch (e) {
    HttpException() =>
      RegExp(r'\bHTTP \d{3}\b').firstMatch(e.message)?.group(0) ??
          'HTTP request failed',
    SocketException() => 'DNS/TCP error (${e.osError?.errorCode ?? "unknown"})',
    _ => '${_issue(e).name} (${e.runtimeType})',
  };
}
