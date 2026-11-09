import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bangumi_links.dart';
import 'image_store.dart';
import 'metadata.dart';
import 'metadata_http.dart';
import 'metadata_servers.dart';
import 'optional_features.dart';
import 'optional_feature_scope.dart';
import 'anime_detail_metadata.dart';
import 'artwork_cache.dart';
import 'debug_log.dart';

/// A visible section owns all active IO and decoded/encoded memory. Successful
/// cards and artwork persist on disk without keeping a feature service alive.
class OptionalPeopleSession {
  OptionalPeopleSession(this.settings, this.feature, {this.clientFactory}) {
    _scope = settings.openScope(feature);
    _scope.acquire(() => _images, (images) {
      images.clear();
      _imageBytes = 0;
    });
  }
  final OptionalFeatures settings;
  final OptionalFeature feature;
  final HttpClient Function()? clientFactory;
  late final OptionalFeatureScope _scope;
  final _images = <String, Uint8List>{};
  int _imageBytes = 0;
  int _responseBytes = 0;
  bool _hadFailures = false;
  final _unhealthyHosts = <String, DateTime>{};
  bool _loadingCards = false;
  String? _owner;
  static const maxImageBytes = 4 * 1024 * 1024;
  bool get disposed => _scope.disposed;
  int get cachedImageBytes => _imageBytes;
  int get activeClients => _scope.count<HttpClient>();
  int get activeTimers => _scope.count<Timer>();
  void Function(List<Map<String, dynamic>> cards)? onCardsReady;

  void _check() {
    _scope.checkActive();
    ImageStore.checkOwner(_owner);
  }

  void dispose() {
    onCardsReady = null;
    _scope.dispose();
  }

  // Use the same configured endpoints as core scraping, while keeping all IO
  // owned and cancelled by this optional feature's scope.
  Future<Uint8List> _readBytes(
    Uri source,
    int limit, {
    Map<String, String> headers = const {},
    Future<void>? cancelled,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final image = MetadataServers.imageResource(source.toString());
    final index = image?.$1 ?? MetadataHttp.provider(source);
    final resource = image?.$2 ?? source.path;
    final candidates = index == null
        ? [source]
        : <Uri>{
            for (final base in [
              MetadataServers.values[index],
              if (MetadataServers.fallback) ...[
                MetadataServers.defaults[index],
                MetadataServers.official[index],
              ],
            ])
              MetadataServers.endpoint(
                index,
                resource,
                base: base,
              ).replace(query: source.hasQuery ? source.query : null),
          }.toList();
    // Preserve configured priority among healthy routes. Failed routes remain
    // available as a last resort rather than turning the whole batch offline.
    final now = DateTime.now();
    final healthy = candidates
        .where((uri) => !(_unhealthyHosts[uri.host]?.isAfter(now) ?? false))
        .toList();
    final unhealthy = candidates
        .where((uri) => _unhealthyHosts[uri.host]?.isAfter(now) ?? false)
        .toList();
    candidates
      ..clear()
      ..addAll([...healthy, ...unhealthy]);
    var aborted = false;
    cancelled?.then((_) => aborted = true);
    final watch = Stopwatch()..start();
    for (var i = 0; i < candidates.length; i++) {
      _check();
      if (aborted) throw StateError('Image stopped');
      final uri = candidates[i];
      final hasAuth =
          headers.keys.any((k) => k.toLowerCase() == 'authorization') ||
          uri.queryParameters.containsKey('api_key');
      if (hasAuth &&
          (!uri.isScheme('https') ||
              !['api.themoviedb.org', 'api.tmdb.org'].contains(uri.host) &&
                  !MetadataServers.trustCustomTmdb)) {
        throw StateError(
          'Custom TMDB endpoint is not authorized for credentials',
        );
      }
      final remaining = timeout - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Optional request deadline');
      }
      try {
        final bytes = await _scope.readBytes(
          uri,
          limit,
          headers: headers,
          requestCancelled: cancelled,
          clientFactory: clientFactory,
          timeout: candidates.length - i > 1
              ? Duration(microseconds: remaining.inMicroseconds * 2 ~/ 3)
              : remaining,
        );
        _unhealthyHosts.remove(uri.host);
        return bytes;
      } on TimeoutException {
        _unhealthyHosts[uri.host] = DateTime.now().add(
          const Duration(seconds: 45),
        );
        if (i == candidates.length - 1) rethrow;
      } on IOException {
        _unhealthyHosts[uri.host] = DateTime.now().add(
          const Duration(seconds: 45),
        );
        if (i == candidates.length - 1) rethrow;
      }
    }
    throw const HttpException('Optional details unavailable');
  }

  Future<Object?> _json(
    Uri uri, {
    Map<String, String> headers = const {},
    int limit = 256 * 1024,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    try {
      final bytes = await _readBytes(
        uri,
        limit,
        headers: headers,
        timeout: timeout,
      );
      _responseBytes += bytes.length;
      if (_responseBytes > 4 * 1024 * 1024) {
        dispose();
        throw const FormatException('Total response limit');
      }
      return jsonDecode(utf8.decode(bytes));
    } catch (_) {
      _check();
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> load(
    Map<String, Object?> work,
    String locale, {
    List<Map> characters = const [],
    Map<String, List<Map>> credits = const {},
  }) async {
    _check();
    _owner = work['id']?.toString();
    _check();
    final key = ArtworkCache.digest(
      jsonEncode([
        feature == OptionalFeature.characters ? 'people-v5' : 'people-v3',
        feature.name,
        BangumiLinks.ids(work),
        work['tmdb_id'],
        work['tmdb_type'],
        locale,
        originalLanguage(work),
        work['character_order'],
        characters,
        credits,
      ]),
    );
    Map? snapshot;
    if (_owner != null) {
      Object? stored;
      try {
        stored = await (await ImageStore.cache).readData(_owner!, key);
      } catch (_) {
        _check();
      }
      _check();
      if (feature == OptionalFeature.characters &&
          stored is Map &&
          stored['expiresAt'] is int &&
          stored['expiresAt'] > DateTime.now().millisecondsSinceEpoch &&
          stored['cards'] is List &&
          stored['rows'] is List) {
        final cards = (stored['cards'] as List)
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
        await _retainCards(cards);
        onCardsReady?.call(cards);
        if (stored['complete'] == true) return cards;
        snapshot = stored;
      }
      if (stored is List) {
        final cards = stored
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
        await _retainCards(cards);
        return cards;
      }
    }
    _responseBytes = 0;
    _hadFailures = false;
    _loadingCards = true;
    final timer = _scope.timer(const Duration(seconds: 30), dispose);
    try {
      final result = feature == OptionalFeature.characters
          ? await _characters(
              work,
              locale,
              characters,
              key: key,
              snapshot: snapshot,
            )
          : await _credits(work, locale, credits);
      _check();
      await _retainCards(result);
      if (feature != OptionalFeature.characters &&
          _owner != null &&
          !_hadFailures) {
        try {
          await (await ImageStore.cache).writeData(
            _owner!,
            key,
            result,
            checkActive: _check,
          );
        } catch (_) {
          _check();
          DebugLog.write(
            'OptionalPeople',
            'card cache write failed',
            level: 'WARN',
          );
        }
      }
      return result;
    } finally {
      _loadingCards = false;
      _scope.closeIdleClients();
      _scope.release(timer);
    }
  }

  Future<void> _retainCards(List<Map<String, dynamic>> cards) async {
    if (_owner == null) return;
    try {
      await ImageStore.retain(
        _owner!,
        cards
            .expand((card) => [card['image'], card['alternateImage']])
            .whereType<String>(),
      );
    } catch (_) {
      _check();
    }
    _check();
  }

  /// Each image widget cancels its own request on scroll-out or picture change.
  Future<Uint8List> image(String url, Future<void> cancelled) async {
    try {
      return await _image(url, cancelled);
    } finally {
      if (!_loadingCards) _scope.closeIdleClients();
    }
  }

  Future<Uint8List> _image(String url, Future<void> cancelled) async {
    _check();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.hasFragment ||
        url.length > 2048 ||
        !(feature == OptionalFeature.characters
            ? uri.host == 'lain.bgm.tv'
            : uri.host == 'image.tmdb.org')) {
      throw const FormatException('Invalid artwork URL');
    }
    final existing = _images.remove(url);
    if (existing != null) {
      _images[url] = existing;
      return existing;
    }
    var aborted = false;
    cancelled.then((_) => aborted = true);
    void check() {
      _check();
      if (aborted) throw StateError('Image stopped');
    }

    Uint8List? cached;
    try {
      cached = await ImageStore.readCached(url, checkActive: check);
    } catch (_) {
      check();
    }
    check();
    final bytes =
        cached ?? await _readBytes(uri, 2 * 1024 * 1024, cancelled: cancelled);
    _check();
    if (aborted) throw StateError('Image stopped');
    if (cached == null) await ImageStore.validate(bytes);
    _check();
    if (aborted) throw StateError('Image stopped');
    try {
      if (_owner != null) await ImageStore.retain(_owner!, [url]);
      if (cached == null) {
        await ImageStore.storeCached(url, bytes, checkActive: check);
      }
    } catch (_) {
      check();
      DebugLog.write(
        'OptionalPeople',
        'image cache write failed',
        level: 'WARN',
      );
    }
    check();
    _imageBytes -= _images.remove(url)?.length ?? 0;
    while (_imageBytes + bytes.length > maxImageBytes && _images.isNotEmpty) {
      _imageBytes -= _images.remove(_images.keys.first)!.length;
    }
    _images[url] = bytes;
    _imageBytes += bytes.length;
    return bytes;
  }

  Future<List<Map<String, dynamic>>> _characters(
    Map<String, Object?> work,
    String locale,
    List<Map> cached, {
    required String key,
    Map? snapshot,
  }) async {
    final ids = BangumiLinks.ids(work).take(8).toList();
    final groups = snapshot?['rowsComplete'] == true
        ? <Object?>[snapshot!['rows']]
        : await Future.wait(
            ids.map(
              (id) => _json(
                Uri.https('api.bgm.tv', '/v0/subjects/$id/characters'),
                limit: 2 * 1024 * 1024,
              ),
            ),
          );
    final usable = groups.whereType<List>().toList();
    final rowsComplete = usable.length == groups.length;
    if (usable.length != groups.length) _hadFailures = true;
    if (usable.isEmpty && ids.isNotEmpty && cached.isEmpty) {
      throw StateError('Characters unavailable');
    }
    final rows = <int, Map<String, dynamic>>{};
    int rank(Map row) => switch ('${row['relation']}') {
      '主角' || '1' => 0,
      '配角' || '2' => 1,
      '客串' || '3' => 2,
      _ => 3,
    };
    List<Map<String, dynamic>> actors(Map row) =>
        (row['actors'] as List? ?? row['actorDetails'] as List? ?? [])
            .whereType<Map>()
            .map((a) => Map<String, dynamic>.from(a))
            .toList();
    for (final group in usable.isEmpty ? [cached] : usable) {
      for (final row in group.whereType<Map>()) {
        final id = row['id'];
        if (id is! int) continue;
        final old = rows[id];
        if (old == null) {
          rows[id] = {
            ...Map<String, dynamic>.from(row),
            'actors': actors(row),
            '_index': rows.length,
          };
        } else {
          if (rank(row) < rank(old)) old['relation'] = row['relation'];
          final previous = old['actors'] as List<Map<String, dynamic>>;
          for (final actor in actors(row)) {
            if (!previous.any(
              (a) => actor['id'] != null
                  ? a['id'] == actor['id']
                  : a['name'] == actor['name'],
            )) {
              previous.add(actor);
            }
          }
        }
      }
    }
    for (final old in cached) {
      final id = old['id'];
      if (id is! int) continue;
      if (old['manual'] == true && !rows.containsKey(id)) {
        rows[id] = {
          ...Map<String, dynamic>.from(old),
          'actors': actors(old),
          '_index': rows.length,
        };
      }
      final row = rows[id];
      if (row == null) continue;
      if (_text(old['name_cn']).isNotEmpty) row['name_cn'] = old['name_cn'];
      if (old['manual'] == true) {
        for (final key in ['name', 'image', 'relation']) {
          if (old[key] != null) row[key] = old[key];
        }
      }
      for (final a in actors(old)) {
        for (final b in row['actors'] as List<Map<String, dynamic>>) {
          if (a['id'] == b['id'] && _text(a['name_cn']).isNotEmpty) {
            b['name_cn'] = a['name_cn'];
          }
        }
      }
    }
    List order = [];
    try {
      order = jsonDecode(work['character_order'] as String? ?? '[]') as List;
    } catch (_) {}
    final sorted = rows.values.toList()
      ..sort((a, b) {
        final x = order.indexOf(a['id']), y = order.indexOf(b['id']);
        if (x >= 0 || y >= 0) {
          return (x < 0 ? 999999 : x).compareTo(y < 0 ? 999999 : y);
        }
        final r = rank(a).compareTo(rank(b));
        if (r != 0) return r;
        final ao = num.tryParse('${a['order']}'),
            bo = num.tryParse('${b['order']}');
        return ao != null && bo != null && ao != bo
            ? ao.compareTo(bo)
            : (a['_index'] as int).compareTo(b['_index'] as int);
      });
    final selected = sorted.take(48).toList();
    var language = originalLanguage(work) ?? snapshot?['language'] as String?;
    var languageChecked =
        language != null || snapshot?['languageChecked'] == true;
    final chinese = locale.startsWith('zh');
    final names = <String, String>{
      if (snapshot?['names'] is Map)
        for (final entry in (snapshot!['names'] as Map).entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
    };
    String chineseName(Map row) {
      var value = _text(row['name_cn']);
      for (final item in (row['infobox'] as List? ?? []).whereType<Map>()) {
        if (value.isEmpty &&
            ['简体中文名', '中文名'].contains(item['key']) &&
            item['value'] is String) {
          value = _text(item['value']);
        }
      }
      return value;
    }

    String name(String kind, Map row) {
      if (!chinese) return _text(row['name'] ?? row['name_cn']);
      var cn = chineseName(row);
      if (cn.isEmpty) cn = names['$kind/${row['id']}'] ?? '';
      return cn.isEmpty ? _text(row['name']) : cn;
    }

    List<Map<String, dynamic>> cards() => selected.map((row) {
      final actor = selectActor(actors(row), language);
      final names = actor == null ? '' : name('persons', actor);
      return <String, dynamic>{
        'title': _text(
          name('characters', row).isEmpty ? row['id'] : name('characters', row),
          120,
        ),
        'subtitle': _text(names),
        'image': _bangumiImage(row),
        'alternateImage': actor == null ? '' : _bangumiImage(actor),
        'alternateSubtitle': _text(names),
      };
    }).toList();

    // Keep only presentation fields, not biographies or arbitrary API payloads.
    Map<String, Object?> compact(Map row, {bool withActors = false}) => {
      for (final field in [
        'id',
        'name',
        'name_cn',
        'image',
        'images',
        'relation',
        'order',
        'language',
        'language_code',
        'locale',
        'country',
      ])
        if (row[field] != null) field: row[field],
      if (row['short_summary'] != null || row['summary'] != null)
        'short_summary': row['short_summary'] ?? row['summary'],
      if (withActors) 'actors': actors(row).map((a) => compact(a)).toList(),
    };
    final savedRows = selected
        .map((r) => compact(r, withActors: true))
        .toList();
    final rowsFit = utf8.encode(jsonEncode(savedRows)).length <= 512 * 1024;
    Future<void> persist({bool complete = false}) async {
      if (_owner == null) return;
      _check();
      try {
        await (await ImageStore.cache).writeData(_owner!, key, {
          'expiresAt':
              snapshot?['expiresAt'] ??
              DateTime.now()
                  .add(const Duration(days: 7))
                  .millisecondsSinceEpoch,
          'cards': cards(),
          'rows': rowsFit ? savedRows : [],
          'rowsComplete': rowsComplete && rowsFit,
          'names': names,
          'language': language,
          'languageChecked': languageChecked,
          'complete': complete,
        }, checkActive: _check);
      } catch (_) {
        _check();
        DebugLog.write(
          'OptionalPeople',
          'partial card cache write failed',
          level: 'WARN',
        );
      }
    }

    // Let visible images start as soon as the character list is available.
    // Name/original-language enrichment must not gate the entire row.
    _check();
    onCardsReady?.call(cards());
    await persist();
    if (!languageChecked && ids.isNotEmpty) {
      final subject = await _json(
        Uri.https('api.bgm.tv', '/v0/subjects/${ids.first}'),
        timeout: const Duration(seconds: 3),
      );
      if (subject is Map) {
        language = originalLanguage({'origin_tags': subject['tags']});
        languageChecked = true;
      } else {
        _hadFailures = true;
      }
    }
    final lookups = <String>{};
    for (final row in selected) {
      for (final entry in [
        ('characters', row),
        if (selectActor(actors(row), language) case final actor?)
          ('persons', actor),
      ]) {
        if (chinese &&
            entry.$2['id'] is int &&
            _text(entry.$2['name_cn']).isEmpty &&
            !names.containsKey('${entry.$1}/${entry.$2['id']}') &&
            lookups.length < 120) {
          lookups.add('${entry.$1}/${entry.$2['id']}');
        }
      }
    }
    // Leave capacity in the shared six-request budget for visible artwork and
    // core scraping instead of occupying all slots with optional names.
    final keys = lookups.toList();
    final enrichment = Stopwatch()..start();
    for (var offset = 0; offset < keys.length; offset += 2) {
      if (enrichment.elapsed >= const Duration(seconds: 9)) {
        _hadFailures = true;
        break;
      }
      _check();
      await Future.wait(
        keys.skip(offset).take(2).map((key) async {
          final detail = await _json(
            Uri.https('api.bgm.tv', '/v0/$key'),
            timeout: const Duration(seconds: 3),
          );
          if (detail is Map) {
            // A successful response without a Chinese name is also complete;
            // do not refetch that person on every visit.
            names[key] = chineseName(detail);
          } else {
            _hadFailures = true;
          }
        }),
      );
      _check();
      onCardsReady?.call(cards());
      await persist();
    }
    await persist(complete: !_hadFailures);
    return cards();
  }

  /// Original language is a property of the work, never the UI language.
  static String? originalLanguage(Map<String, Object?> work) {
    final metadata = AnimeDetailMetadata.fromWork(work);
    final language = work['original_language'] ?? metadata['original_language'];
    if (language is String && language.isNotEmpty) {
      return language.split(RegExp('[-_]')).first.toLowerCase();
    }
    final countries = work['origin_country'] ?? metadata['origin_country'];
    if (countries is List && countries.isNotEmpty) {
      final result = _language(countries.first.toString());
      if (result != null) return result;
    }
    final bangumi = metadata['bangumi'] is Map
        ? metadata['bangumi'] as Map
        : metadata;
    for (final tag in (work['origin_tags'] as List? ?? [])) {
      final result = _language(tag is Map ? '${tag['name']}' : '$tag');
      if (result != null) return result;
    }
    for (final tag in (bangumi['tags'] as List? ?? [])) {
      final result = _language(tag is Map ? '${tag['name']}' : '$tag');
      if (result != null) return result;
    }
    return null;
  }

  static String? _language(String value) => switch (value
      .trim()
      .toLowerCase()) {
    'ja' || 'jp' || 'japanese' || '日本' || '日本語' || '日语' || '日語' || '日漫' => 'ja',
    'zh' ||
    'cn' ||
    'tw' ||
    'hk' ||
    'chinese' ||
    '中国' ||
    '中國' ||
    '中文' ||
    '汉语' ||
    '國語' ||
    '国语' ||
    '普通话' ||
    '国创' ||
    '国产' => 'zh',
    'en' || 'us' || 'gb' || 'english' || '英语' || '英語' || '美国' || '英国' => 'en',
    'ko' || 'kr' || 'korean' || '韩语' || '韓語' || '韩国' => 'ko',
    'fr' || 'french' || '法语' || '法国' => 'fr',
    'de' || 'german' || '德语' || '德国' => 'de',
    'es' || 'spanish' || '西班牙语' || '西班牙' => 'es',
    _ => null,
  };

  static Map<String, dynamic>? selectActor(
    List<Map<String, dynamic>> actors,
    String? language,
  ) {
    if (actors.isEmpty) return null;
    if (language == null) return actors.first;
    String? actorLanguage(Map actor) {
      for (final key in ['language', 'language_code', 'locale', 'country']) {
        final value = actor[key];
        if (value is String) {
          final result =
              _language(value) ?? _language(value.split(RegExp('[-_]')).first);
          if (result != null) return result;
        }
      }
      // Bangumi's subject-scoped actors do not expose a dubbing-language field.
      // Use explicit biography evidence only; names/scripts are not nationality.
      final summary = '${actor['short_summary'] ?? actor['summary'] ?? ''}';
      for (final entry in const {
        '日本': 'ja',
        '中国': 'zh',
        '中國': 'zh',
        '台湾': 'zh',
        '臺灣': 'zh',
        '香港': 'zh',
        '美国': 'en',
        '英国': 'en',
        '韩国': 'ko',
        '法国': 'fr',
        '德国': 'de',
        '西班牙': 'es',
      }.entries) {
        if (RegExp(
          '${entry.key}(?:的|籍)?(?:男性|女性|男|女)?(?:声优|聲優|配音|演员|演員)',
        ).hasMatch(summary)) {
          return entry.value;
        }
      }
      return null;
    }

    for (final actor in actors) {
      if (actorLanguage(actor) == language) return actor;
    }
    // Preserve source order among unknown-language actors. Never deliberately
    // select a known foreign dub just because it has a photo.
    return actors.where((actor) => actorLanguage(actor) == null).firstOrNull;
  }

  Future<List<Map<String, dynamic>>> _credits(
    Map<String, Object?> work,
    String locale,
    Map<String, List<Map>> cached,
  ) async {
    final auth = Metadata.credentials;
    final id = work['tmdb_id'], type = work['tmdb_type'];
    final zh = locale.startsWith('zh'),
        hant = RegExp('Hant|TW|HK').hasMatch(locale);
    Object? fresh;
    if (!auth.isConfigured) _hadFailures = true;
    if (id is int &&
        id > 0 &&
        ['movie', 'tv'].contains(type) &&
        auth.isConfigured) {
      fresh = await _json(
        auth.uri(
          '/$type/$id/${type == 'movie' ? 'credits' : 'aggregate_credits'}',
          {'language': zh ? (hant ? 'zh-TW' : 'zh-CN') : 'en-US'},
        ),
        headers: auth.headers,
        limit: 1024 * 1024,
      );
      if (fresh == null && cached.values.every((v) => v.isEmpty)) {
        throw StateError('Credits unavailable');
      }
      if (fresh == null) _hadFailures = true;
    }
    return creditsCards(fresh is Map ? fresh : const {}, cached, locale);
  }

  static List<Map<String, dynamic>> creditsCards(
    Map fresh,
    Map<String, List<Map>> cached,
    String locale,
  ) {
    final zh = locale.startsWith('zh'),
        hant = RegExp('Hant|TW|HK').hasMatch(locale);
    const jobs = {
      'Director': ['导演', '導演'],
      'Screenplay': ['编剧', '編劇'],
      'Writer': ['编剧', '編劇'],
      'Creator': ['主创', '主創'],
      'Producer': ['制片人', '製片人'],
      'Executive Producer': ['执行制片人', '執行製片人'],
      'Original Music Composer': ['音乐', '音樂'],
      'Director of Photography': ['摄影', '攝影'],
    };
    final cards = <Map<String, dynamic>>[];
    for (final kind in ['cast', 'crew']) {
      final useCache = fresh[kind] is! List;
      final people = useCache ? cached[kind] ?? [] : fresh[kind] as List;
      final rows = <String, Map<String, dynamic>>{};
      for (final person in people.whereType<Map>()) {
        final name = _text(person['name'], 120).trim();
        if (name.isEmpty) continue;
        final roles = <String>{};
        void add(Object? v) {
          if (v is String && v.trim().isNotEmpty) roles.add(v.trim());
        }

        if (useCache) {
          (person['roles'] as List? ?? []).forEach(add);
        } else if (kind == 'cast') {
          add(person['character']);
          for (final r in (person['roles'] as List? ?? []).whereType<Map>()) {
            add(r['character']);
          }
        } else {
          for (final r in [
            person,
            ...(person['jobs'] as List? ?? []).whereType<Map>(),
          ]) {
            final job = r['job'];
            if (jobs.containsKey(job)) add(zh ? jobs[job]![hant ? 1 : 0] : job);
          }
          if (roles.isEmpty) continue;
        }
        final key = '${person['id'] ?? name}';
        if (rows.containsKey(key)) {
          (rows[key]!['roles'] as Set<String>).addAll(roles);
          continue;
        }
        if (rows.length >= 24) continue;
        rows[key] = {
          'title': name,
          'roles': roles,
          'image': _tmdbImage(person[useCache ? 'image' : 'profile_path']),
        };
      }
      for (final row in rows.values) {
        cards.add({
          'title': row['title'],
          'subtitle': _text((row['roles'] as Set<String>).join(' / ')),
          'image': row['image'],
          'section': kind == 'cast'
              ? (zh ? (hant ? '演員' : '演员') : 'Cast')
              : (zh ? (hant ? '製作人員' : '制作人员') : 'Crew'),
        });
      }
    }
    return cards;
  }

  static String _text(Object? value, [int limit = 300]) {
    final s = value?.toString() ?? '';
    return s.length <= limit ? s : s.substring(0, limit);
  }

  static String _bangumiImage(Map row) {
    final images = row['images'] is Map ? row['images'] as Map : {};
    var url = _text(
      row['image'] ?? images['medium'] ?? images['small'] ?? images['grid'],
      2048,
    );
    if (url.startsWith('//')) url = 'https:$url';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.userInfo.isNotEmpty || uri.hasFragment) return '';
    // API mirrors also rewrite image hosts. Keep a canonical cache identity;
    // _readBytes still routes through the user's configured artwork endpoint.
    if (uri.scheme == 'http' &&
        uri.port == 80 &&
        ['lain.bgm.tv', 'lain.bangumi.lat'].contains(uri.host)) {
      url = uri.replace(scheme: 'https', port: 443).toString();
    }
    final resource = MetadataServers.imageResource(url);
    if (resource?.$1 != 3) return '';
    return MetadataServers.endpoint(
      3,
      resource!.$2,
      base: MetadataServers.official[3],
    ).replace(query: uri.hasQuery ? uri.query : null).toString();
  }

  static String _tmdbImage(Object? value) {
    final path = value is String ? value : '';
    if (RegExp(r'^/[A-Za-z0-9_.-]+$').hasMatch(path)) {
      return 'https://image.tmdb.org/t/p/w185$path';
    }
    final match = RegExp(
      r'^https://(?:image|images)\.tmdb\.org/t/p/[^/]+(/[A-Za-z0-9_.-]+)$',
    ).firstMatch(path);
    return match == null ? '' : 'https://image.tmdb.org/t/p/w185${match[1]}';
  }
}
