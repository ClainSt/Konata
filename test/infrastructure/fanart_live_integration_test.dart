import 'dart:convert';
import 'dart:io';

import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/network/fanart_service.dart';
import 'package:konata/infrastructure/network/priority_http_scheduler.dart';
import 'package:konata/infrastructure/network/tmdb_http_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本地联调密钥解析结果（严禁在日志或断言中输出明文密钥）。
typedef _ResolvedDevFanartKey = ({String apiKey, String source});

/// 按顺序从环境变量与本地未追踪配置文件读取 Fanart.tv 联调密钥。
_ResolvedDevFanartKey? _resolveDevFanartApiKey() {
  final envKey = (Platform.environment['KONATA_FANART_DEV_API_KEY'] ?? '')
      .trim();
  if (envKey.isNotEmpty) {
    return (apiKey: envKey, source: '环境变量 KONATA_FANART_DEV_API_KEY');
  }

  final candidates = <File>[
    File('dart_defines.dev.json'),
    File('${Directory.current.path}${Platform.pathSeparator}dart_defines.dev.json'),
  ];
  for (final file in candidates) {
    if (!file.existsSync()) continue;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) {
        final raw = (decoded['FANART_API_KEY'] ?? '').toString().trim();
        if (raw.isNotEmpty) {
          return (apiKey: raw, source: '本地文件 dart_defines.dev.json');
        }
      }
    } catch (_) {
      // 配置文件损坏或非 JSON 时静默忽略，交由后续自动跳过机制处理。
    }
  }
  return null;
}

void main() {
  final resolved = _resolveDevFanartApiKey();

  group(
    'Fanart.tv 真实接口在线联调集成测试',
    () {
      late TmdbHttpClient httpClient;
      late FanartService fanartService;

      setUp(() {
        final cfg = TmdbNetworkConfig(
          fanartApiKeyOverride: resolved!.apiKey,
          proxyMode: ProxyMode.system,
        );
        httpClient = TmdbHttpClient(
          config: cfg,
          scheduler: PriorityHttpScheduler(maxRetries: 1),
        );
        fanartService = FanartService(httpClient: httpClient);
      });

      tearDown(() {
        httpClient.close();
      });

      test(
        '连通性探测、电影与剧集透明标题徽标真实拉取通路校验',
        () async {
          // 仅输出脱敏加载状态，严禁打印完整密钥明文。
          expect(resolved, isNotNull);
          expect(resolved!.apiKey.length, greaterThanOrEqualTo(16));

          final connectivity = await httpClient.testFanartApiConnectivity();
          expect(
            connectivity.reachable,
            isTrue,
            reason:
                '密钥来源: ${resolved.source}，连通性结果: ${connectivity.statusSummary}',
          );

          // 1. 电影接口联调（千与千寻，TMDB ID 129）
          final movieRes = await fanartService.fetchLogos(
            mediaType: TmdbMediaType.movie,
            tmdbId: 129,
          );
          expect(movieRes.authRejected, isFalse);
          expect(movieRes.logos, isNotEmpty);
          expect(
            movieRes.bestLogoUrl,
            startsWith('https://assets.fanart.tv/'),
          );

          // 2. 剧集接口联调（葬送的芙莉莲，TheTVDB ID 424536）
          final tvRes = await fanartService.fetchLogos(
            mediaType: TmdbMediaType.tv,
            tvdbId: 424536,
          );
          expect(tvRes.authRejected, isFalse);
          expect(tvRes.logos, isNotEmpty);
          expect(
            tvRes.bestLogoUrl,
            startsWith('https://assets.fanart.tv/'),
          );
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );

      test(
        '默认内置无状态中继（api.konata.acgcc.cn）零配置开箱即用连通与拉取校验',
        () async {
          final relayClient = TmdbHttpClient(
            config: const TmdbNetworkConfig(proxyMode: ProxyMode.system),
            scheduler: PriorityHttpScheduler(maxRetries: 1),
          );
          addTearDown(relayClient.close);

          final probe = await relayClient.testFanartApiConnectivity();
          expect(
            probe.reachable,
            isTrue,
            reason: '内置中继连通性结果: ${probe.statusSummary}',
          );

          final relayService = FanartService(httpClient: relayClient);
          expect(relayService.isUsingRelay, isTrue);

          final movieRes = await relayService.fetchArtworkBundle(
            mediaType: TmdbMediaType.movie,
            tmdbId: 129,
          );
          expect(movieRes.authRejected, isFalse);
          expect(movieRes.bestLogoUrl, startsWith('https://assets.fanart.tv/'));
          expect(movieRes.posters, isNotEmpty);
          expect(movieRes.backgrounds, isNotEmpty);
          expect(
            movieRes.backgrounds.every((b) => !b.url.contains('/moviethumb/')),
            isTrue,
          );

          final tvRes = await relayService.fetchArtworkBundle(
            mediaType: TmdbMediaType.tv,
            tvdbId: 424536,
          );
          expect(tvRes.authRejected, isFalse);
          expect(tvRes.logos, isNotEmpty);
          expect(tvRes.posters, isNotEmpty);
          expect(tvRes.backgrounds, isNotEmpty);
          expect(
            tvRes.backgrounds.every((b) => !b.url.contains('/tvthumb/')),
            isTrue,
          );
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    },
    skip: resolved == null
        ? '未配置本地 Fanart.tv 开发测试密钥（KONATA_FANART_DEV_API_KEY / dart_defines.dev.json），自动跳过联调测试'
        : false,
  );
}
