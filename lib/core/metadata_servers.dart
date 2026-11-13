import 'package:shared_preferences/shared_preferences.dart';

class MetadataServers {
  static const defaults = [
    'https://api.tmdb.org/3',
    'https://images.tmdb.org/t/p/',
    'https://api.bangumi.lat/v0',
    'https://lain.bangumi.lat',
  ];
  static const official = [
    'https://api.themoviedb.org/3',
    'https://image.tmdb.org/t/p/',
    'https://api.bgm.tv/v0',
    'https://lain.bgm.tv',
  ];
  static List<String> values = List.of(defaults);
  static bool fallback = true;
  static bool trustCustomTmdb = false;
  static const primaryAttemptLimit = Duration(seconds: 3);
  static final _routeCooldown = <String, DateTime>{};
  static final _imageHistory = <int, Set<String>>{1: {}, 3: {}};
  static String normalize(String raw, int index) {
    final u = Uri.tryParse(raw.trim());
    if (u == null ||
        !['https', 'http'].contains(u.scheme) ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment ||
        u.pathSegments.any((s) => s == '..' || s == '.')) {
      throw const FormatException('请输入不含认证信息、查询参数的 HTTP(S) 地址');
    }
    var segments = u.pathSegments.where((e) => e.isNotEmpty).toList();
    final suffix = index == 0
        ? '3'
        : index == 2
        ? 'v0'
        : null;
    if (suffix != null) {
      while (segments.isNotEmpty && segments.last == suffix) {
        segments.removeLast();
      }
      segments.add(suffix);
    }
    return u
        .replace(path: '/${segments.join('/')}${index == 1 ? '/' : ''}')
        .toString()
        .replaceFirst(RegExp(r'/$'), index == 1 ? '/' : '');
  }

  static Uri endpoint(int index, String resource, {String? base}) {
    final root = normalize(base ?? official[index], index);
    var path = resource.replaceFirst(RegExp(r'^/+'), '');
    if (index == 2) path = path.replaceFirst(RegExp(r'^v0/'), '');
    if (index == 0) path = path.replaceFirst(RegExp(r'^3/'), '');
    return Uri.parse('${root.replaceFirst(RegExp(r'/$'), '')}/$path');
  }

  static String tmdbImage(String path, [String size = 'w500']) =>
      endpoint(1, '$size$path').toString();

  static List<Uri> routes(int index, String resource, {String? query}) => {
    endpoint(index, resource).replace(query: query),
    if (fallback)
      endpoint(index, resource, base: values[index]).replace(query: query),
  }.toList();

  static Duration attemptTimeout(Duration budget, {required bool hasBackup}) =>
      hasBackup && budget > primaryAttemptLimit ? primaryAttemptLimit : budget;

  static List<Uri> tryOrder(List<Uri> routes) {
    if (routes.length < 2) return routes;
    final now = DateTime.now();
    bool cooling(Uri uri) => _routeCooldown[uri.origin]?.isAfter(now) ?? false;
    return [...routes.where((uri) => !cooling(uri)), ...routes.where(cooling)];
  }

  static void failedRoute(Uri uri) {
    final now = DateTime.now();
    _routeCooldown.removeWhere((_, until) => !until.isAfter(now));
    if (_routeCooldown.length < 16) {
      _routeCooldown[uri.origin] = now.add(const Duration(seconds: 45));
    }
  }

  static void reachedRoute(Uri uri) => _routeCooldown.remove(uri.origin);

  static (int, String)? imageResource(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !['http', 'https'].contains(uri.scheme)) return null;
    for (final index in [1, 3]) {
      final bases = {
        ..._imageHistory[index]!,
        defaults[index],
        official[index],
        values[index],
      }.toList()..sort((a, b) => b.length.compareTo(a.length));
      for (final base in bases) {
        final root = Uri.parse(base);
        final prefix = '${root.path.replaceFirst(RegExp(r'/$'), '')}/';
        if (uri.origin == root.origin && uri.path.startsWith(prefix)) {
          return (index, uri.path.substring(prefix.length));
        }
      }
    }
    return null;
  }

  static String mapImage(String raw) {
    final u = Uri.tryParse(raw);
    final resource = imageResource(raw);
    if (u == null || resource == null) return raw;
    return endpoint(
      resource.$1,
      resource.$2,
    ).replace(query: u.hasQuery ? u.query : null).toString();
  }

  static List<Uri> imageRoutes(String raw) {
    final uri = Uri.parse(raw);
    final resource = imageResource(raw);
    return resource == null
        ? [uri]
        : routes(
            resource.$1,
            resource.$2,
            query: uri.hasQuery ? uri.query : null,
          );
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _routeCooldown.clear();
    for (var i = 0; i < 4; i++) {
      try {
        values[i] = normalize(
          prefs.getString('metadata_server_$i') ?? defaults[i],
          i,
        );
      } catch (_) {
        values[i] = defaults[i];
      }
    }
    fallback = prefs.getBool('metadata_fallback') ?? true;
    trustCustomTmdb = prefs.getBool('metadata_trust_tmdb') ?? false;
    for (final index in [1, 3]) {
      _imageHistory[index]!.clear();
      for (final base
          in prefs.getStringList('metadata_image_history_$index') ??
              <String>[]) {
        try {
          _imageHistory[index]!.add(normalize(base, index));
        } catch (_) {}
      }
    }
  }

  static Future<void> save(
    List<String> addresses,
    bool autoFallback,
    bool trust,
  ) async {
    final normalized = [for (var i = 0; i < 4; i++) normalize(addresses[i], i)];
    final prefs = await SharedPreferences.getInstance();
    for (final index in [1, 3]) {
      _imageHistory[index]!.addAll([values[index], normalized[index]]);
      await prefs.setStringList(
        'metadata_image_history_$index',
        _imageHistory[index]!.toList(),
      );
    }
    for (var i = 0; i < 4; i++) {
      await prefs.setString('metadata_server_$i', normalized[i]);
    }
    await prefs.setBool('metadata_fallback', autoFallback);
    await prefs.setBool('metadata_trust_tmdb', trust);
    values = normalized;
    fallback = autoFallback;
    trustCustomTmdb = trust;
    _routeCooldown.clear();
  }
}
