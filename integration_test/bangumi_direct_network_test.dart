import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ccplayer/core/metadata_http.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _limit = Duration(seconds: 8);

void _evidence(Map<String, Object?> fields) {
  // No private IP, proxy configuration, response body or credentials in logs.
  // ignore: avoid_print
  print('KONATA_DIRECT_NETWORK ${jsonEncode(fields)}');
}

Map<String, Object?> _failure(Object error) => {
  'error': error.runtimeType.toString(),
  if (error is SocketException) 'os_code': error.osError?.errorCode,
  if (error is HandshakeException) 'os_code': error.osError?.errorCode,
};

bool _nonPublic(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal) return true;
  final bytes = address.rawAddress;
  return address.type == InternetAddressType.IPv4
      ? bytes[0] == 10 ||
            (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32) ||
            (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19))
      : bytes[0] & 0xfe == 0xfc;
}

Future<void> _probeSocket(
  String host,
  InternetAddress address,
  int index,
) async {
  final common = {
    'host': host,
    'address_index': index,
    'family': address.type.name,
    'nonpublic_answer': _nonPublic(address),
  };
  final watch = Stopwatch()..start();
  Socket? socket;
  SecureSocket? tls;
  var phase = 'tcp';
  try {
    socket = await Socket.connect(address, 443, timeout: _limit);
    _evidence({
      ...common,
      'phase': phase,
      'ok': true,
      'ms': watch.elapsedMilliseconds,
    });
    phase = 'tls';
    watch.reset();
    tls = await SecureSocket.secure(socket, host: host).timeout(_limit);
    _evidence({
      ...common,
      'phase': phase,
      'ok': true,
      'ms': watch.elapsedMilliseconds,
    });
  } catch (error) {
    _evidence({
      ...common,
      'phase': phase,
      ..._failure(error),
      'ms': watch.elapsedMilliseconds,
    });
  } finally {
    tls?.destroy();
    socket?.destroy();
  }
}

Future<void> _probeHttp(Uri uri, {required bool subject}) async {
  final client = HttpClient()
    ..connectionTimeout = _limit
    ..findProxy = (_) => 'DIRECT';
  final watch = Stopwatch()..start();
  var phase = 'http_open';
  try {
    final request = await client.getUrl(uri).timeout(_limit);
    _evidence({
      'host': uri.host,
      'phase': phase,
      'ok': true,
      'ms': watch.elapsedMilliseconds,
    });
    phase = 'http_headers';
    watch.reset();
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, MetadataHttp.userAgent);
    request.headers.set(
      HttpHeaders.acceptHeader,
      uri.path == '/' ? 'text/html' : 'application/json',
    );
    final response = await request.close().timeout(_limit);
    _evidence({
      'host': uri.host,
      'phase': phase,
      'status': response.statusCode,
      'family': response.connectionInfo?.remoteAddress.type.name,
      'ms': watch.elapsedMilliseconds,
    });
    final authChallenge =
        !subject && uri.path != '/' && response.statusCode == 401;
    if (!(subject && response.statusCode == 200) && !authChallenge) return;
    phase = authChallenge ? 'http_auth_challenge' : 'http_subject';
    watch.reset();
    final body = BytesBuilder();
    await for (final chunk in response.timeout(_limit)) {
      body.add(chunk);
      if (body.length > 128 * 1024) {
        throw const FormatException('response limit');
      }
    }
    final data = jsonDecode(utf8.decode(body.takeBytes()));
    _evidence({
      'host': uri.host,
      'phase': phase,
      'valid':
          data is Map &&
          (authChallenge
              ? data['status_code'] == 7 && data['success'] == false
              : data['id'] == 302189 && data['type'] == 2),
      'ms': watch.elapsedMilliseconds,
    });
  } catch (error) {
    _evidence({
      'host': uri.host,
      'phase': phase,
      ..._failure(error),
      'ms': watch.elapsedMilliseconds,
    });
  } finally {
    client.close(force: true);
  }
}

Future<void> _probe(Uri uri, {bool subject = false}) async {
  final host = uri.host;
  final watch = Stopwatch()..start();
  try {
    final addresses = await InternetAddress.lookup(host).timeout(_limit);
    _evidence({
      'host': host,
      'phase': 'dns',
      'ms': watch.elapsedMilliseconds,
      'ipv4': addresses.where((a) => a.type == InternetAddressType.IPv4).length,
      'ipv6': addresses.where((a) => a.type == InternetAddressType.IPv6).length,
      'nonpublic': addresses.where(_nonPublic).length,
    });
    final candidates = [
      for (final type in [InternetAddressType.IPv4, InternetAddressType.IPv6])
        ...addresses.where((address) => address.type == type).take(2),
    ];
    await Future.wait([
      for (var i = 0; i < candidates.length; i++)
        _probeSocket(host, candidates[i], i),
    ]);
  } catch (error) {
    _evidence({
      'host': host,
      'phase': 'dns',
      ..._failure(error),
      'ms': watch.elapsedMilliseconds,
    });
  }
  await _probeHttp(uri, subject: subject);
}

class _RouteClient extends IOClient {
  _RouteClient()
    : super(
        HttpClient()
          ..connectionTimeout = _limit
          ..findProxy = ((_) => 'DIRECT'),
      );
  final hosts = <String>[];
  @override
  Future<IOStreamedResponse> send(http.BaseRequest request) {
    hosts.add(request.url.host);
    return super.send(request);
  }
}

Future<void> _verifyConfiguredFallback() async {
  final original = MetadataServers.values;
  final fallback = MetadataServers.fallback;
  MetadataServers.values = List.of(MetadataServers.defaults);
  MetadataServers.fallback = true;
  try {
    for (final (index, path) in [(2, 'subjects/302189'), (0, 'tv/100565')]) {
      final inner = _RouteClient();
      final client = MetadataHttp(
        fresh: true,
        headerTimeout: _limit,
        responseLimit: 128 * 1024,
        inner: inner,
      );
      final watch = Stopwatch()..start();
      try {
        final response = await client
            .get(MetadataServers.endpoint(index, path))
            .timeout(const Duration(seconds: 25));
        final data = jsonDecode(response.body);
        _evidence({
          'provider': index == 2 ? 'bangumi' : 'tmdb',
          'phase': 'configured_fallback',
          'hosts': inner.hosts,
          'status': response.statusCode,
          'valid':
              data is Map &&
              (index == 2
                  ? response.statusCode == 200 &&
                        data['id'] == 302189 &&
                        data['type'] == 2
                  : response.statusCode == 401 && data['status_code'] == 7),
          'ms': watch.elapsedMilliseconds,
        });
      } catch (error) {
        _evidence({
          'provider': index == 2 ? 'bangumi' : 'tmdb',
          'phase': 'configured_fallback',
          'hosts': inner.hosts,
          ..._failure(error),
          'ms': watch.elapsedMilliseconds,
        });
      } finally {
        client.close();
      }
    }
  } finally {
    MetadataServers.values = original;
    MetadataServers.fallback = fallback;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'public metadata direct connection layers',
    (_) async {
      final temp = await getTemporaryDirectory();
      if (Platform.isAndroid &&
          !temp.path.contains('com.anime.konata.validation')) {
        throw StateError('Use the isolated .validation application');
      }
      await Future.wait([
        for (final endpoints in [
          MetadataServers.official,
          MetadataServers.defaults,
        ]) ...[
          _probe(
            MetadataServers.endpoint(2, 'subjects/302189', base: endpoints[2]),
            subject: true,
          ),
          _probe(MetadataServers.endpoint(0, 'tv/100565', base: endpoints[0])),
        ],
        _probe(Uri.https('bangumi.tv', '/')),
      ]);
      await _verifyConfiguredFallback();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
