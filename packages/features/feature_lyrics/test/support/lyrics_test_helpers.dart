import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:feature_lyrics/feature_lyrics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 模拟 HTTP 请求处理器签名。
typedef HttpResponseFactory = FutureOr<http.Response> Function(
  String method,
  Uri uri,
  Map<String, String> headers,
  Object? body,
);

/// 可编排延迟、状态码与异常的测试用歌词网络传输替身。
class FakeLyricHttpTransport implements LyricHttpTransport {
  /// 使用自定义响应回调构造传输替身。
  FakeLyricHttpTransport(this._handler);

  final HttpResponseFactory _handler;

  /// 记录收到的全部请求地址（便于断言查询参数与是否发生网络调用）。
  final List<Uri> requestedUris = <Uri>[];

  /// 记录收到的请求方法与地址。
  final List<({String method, Uri uri, Object? body})> requests =
      <({String method, Uri uri, Object? body})>[];

  @override
  Future<http.Response> get(
    Uri uri, {
    Map<String, String> headers = const {},
    required Duration timeout,
  }) async {
    requestedUris.add(uri);
    requests.add((method: 'GET', uri: uri, body: null));
    return Future.value(_handler('GET', uri, headers, null)).timeout(timeout);
  }

  @override
  Future<http.Response> post(
    Uri uri, {
    Map<String, String> headers = const {},
    Object? body,
    required Duration timeout,
  }) async {
    requestedUris.add(uri);
    requests.add((method: 'POST', uri: uri, body: body));
    return Future.value(_handler('POST', uri, headers, body)).timeout(timeout);
  }

  /// 构建指定 UTF-8 文本响应。
  static http.Response utf8Response(
    String body, {
    int statusCode = 200,
    Map<String, String> headers = const {'content-type': 'application/json; charset=utf-8'},
  }) {
    return http.Response.bytes(
      utf8.encode(body),
      statusCode,
      headers: headers,
    );
  }

  /// 构建指定 JSON 字典响应。
  static http.Response jsonResponse(
    Object payload, {
    int statusCode = 200,
  }) {
    return utf8Response(jsonEncode(payload), statusCode: statusCode);
  }
}

/// 实现跨包网络端口的测试替身（供注入 `FeatureLyricsDependencies` 或包装 `KonataHttpClientLyricTransport`）。
class FakeKonataHttpClient implements KonataHttpClientPort {
  /// 使用模拟响应处理器构造网络客户端替身。
  FakeKonataHttpClient([HttpResponseFactory? handler]) : _handler = handler;

  final HttpResponseFactory? _handler;
  KonataNetworkConfig _config = const KonataNetworkConfig();

  /// 记录发起过的全部网络请求地址。
  final List<Uri> requestedUris = <Uri>[];

  @override
  KonataNetworkConfig get config => _config;

  @override
  void updateConfig(KonataNetworkConfig next) {
    _config = next;
  }

  @override
  void close() {}

  @override
  Future<KonataHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  }) => sendWithFallback(
    method: 'GET',
    primaryUri: uri,
    headers: headers,
    priority: priority,
    dedupeKey: dedupeKey,
    bucketKey: bucketKey,
  );

  @override
  Future<KonataHttpResponse> getWithFallback(
    Uri primaryUri, {
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  }) => sendWithFallback(
    method: 'GET',
    primaryUri: primaryUri,
    backupUri: backupUri,
    headers: headers,
    priority: priority,
    dedupeKey: dedupeKey,
    bucketKey: bucketKey,
    retryOnRateLimit: retryOnRateLimit,
    timeoutOverride: timeoutOverride,
  );

  @override
  Future<KonataHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
  }) => sendWithFallback(
    method: 'POST',
    primaryUri: uri,
    headers: headers,
    body: body,
    priority: priority,
    dedupeKey: dedupeKey,
    bucketKey: bucketKey,
  );

  @override
  Future<KonataHttpResponse> postWithFallback(
    Uri primaryUri, {
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  }) => sendWithFallback(
    method: 'POST',
    primaryUri: primaryUri,
    backupUri: backupUri,
    headers: headers,
    body: body,
    priority: priority,
    dedupeKey: dedupeKey,
    bucketKey: bucketKey,
    retryOnRateLimit: retryOnRateLimit,
    timeoutOverride: timeoutOverride,
  );

  @override
  Future<KonataHttpResponse> sendWithFallback({
    required String method,
    required Uri primaryUri,
    Uri? backupUri,
    Map<String, String> headers = const <String, String>{},
    Object? body,
    RequestPriority priority = RequestPriority.background,
    String? dedupeKey,
    String? bucketKey,
    bool retryOnRateLimit = true,
    Duration? timeoutOverride,
  }) async {
    requestedUris.add(primaryUri);
    final handler = _handler;
    if (handler == null) {
      return KonataHttpResponse(
        statusCode: 404,
        headers: const <String, String>{},
        bodyBytes: Uint8List(0),
      );
    }
    final respFuture = Future.value(handler(method, primaryUri, headers, body));
    final resp = timeoutOverride == null
        ? await respFuture
        : await respFuture.timeout(timeoutOverride);
    return KonataHttpResponse(
      statusCode: resp.statusCode,
      headers: resp.headers,
      bodyBytes: resp.bodyBytes,
      reasonPhrase: resp.reasonPhrase,
    );
  }
}

/// 可控流式歌词候选源替身（用于精确模拟延迟到达、源异常与并发竞速）。
class FakeLyricCandidateSource implements LyricCandidateSource {
  /// 构造可控流式歌词候选源。
  FakeLyricCandidateSource({
    required this.label,
    required this.streamBuilder,
  });

  @override
  final String label;

  final Stream<LyricCandidate> Function(LyricSearchQuery query) streamBuilder;

  /// 记录调用次数。
  int callCount = 0;

  @override
  Stream<LyricCandidate> candidates(LyricSearchQuery query) {
    callCount++;
    return streamBuilder(query);
  }
}

/// 在全站统一视觉设计系统外壳中挂载组件（零直接导入 Material 或 Cupertino）。
Widget wrapLyricsTestApp({
  required Widget child,
  FeatureLyricsDependencies? dependencies,
  KonataToastController? toastController,
  bool dark = true,
  double bottomClearance = 16.0,
}) {
  final ownedToast = toastController == null ? KonataToastController() : null;
  final effectiveToast = toastController ?? ownedToast!;
  final theme = dark ? KonataTheme.darkTheme() : KonataTheme.lightTheme();
  Widget app = MaterialApp(
    theme: theme,
    home: KonataToastScope(
      controller: effectiveToast,
      child: KonataBottomClearanceScope(
        bottomClearance: bottomClearance,
        child: Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,
          body: SizedBox.expand(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(child: child),
                KonataToastViewport(controller: effectiveToast),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (dependencies != null) {
    app = ProviderScope(
      overrides: [
        featureLyricsDependenciesProvider.overrideWithValue(dependencies),
      ],
      child: app,
    );
  }
  return app;
}

/// 构造可用于单测的四行标准日文歌词。
const String kSampleJapaneseLrc = '''
[00:10.00]光の中へと手を伸ばして
[00:15.00]風の歌が今響いてる
[00:20.00]空の彼方まで駆け出そう
[00:25.00]君と描いた未来へ
''';

/// 构造四行带译文与罗马音的完整双语歌词。
const String kSampleBilingualLrc = '''
[00:10.00]光の中へと手を伸ばして
[00:10.00]向着光芒之中伸出双手
[00:10.00]roma:hikari no naka e to te wo nobashite
[00:15.00]風の歌が今響いてる
[00:15.00]风的歌声此刻正在回响
[00:15.00]roma:kaze no uta ga ima hibiiteru
[00:20.00]空の彼方まで駆け出そう
[00:20.00]向着天空彼端奋力奔跑吧
[00:20.00]roma:sora no kanata made kakedasou
[00:25.00]君と描いた未来へ
[00:25.00]前往与你共同描绘的未来
[00:25.00]roma:kimi to egaita mirai e
''';

/// 构造逐字与嵌套和声兼容的 TTML 歌词正文。
const String kSampleAmllTtml = '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <body>
    <div>
      <p begin="00:10.000" end="00:13.000">
        <span begin="00:10.000" end="00:11.000">光の中へ</span>
        <span begin="00:11.000" end="00:13.000">と手を伸ばして</span>
      </p>
      <p begin="00:15.000" end="00:18.000">
        <span begin="00:15.000" end="00:16.500">風の歌が</span>
        <span begin="00:16.500" end="00:18.000">今響いてる</span>
      </p>
      <p begin="00:20.000" end="00:23.000">
        <span begin="00:20.000" end="00:21.500">空の彼方</span>
        <span begin="00:21.500" end="00:23.000">まで駆け出そう</span>
      </p>
      <p begin="00:25.000" end="00:28.000">
        <span begin="00:25.000" end="00:26.500">君と描い</span>
        <span begin="00:26.500" end="00:28.000">た未来へ</span>
      </p>
    </div>
  </body>
</tt>
''';
