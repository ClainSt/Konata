import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'optional_feature_scope.dart';

enum OptionalFeature { characters, credits }

/// Only preferences live for the app lifetime. Services are created by a page
/// when enabled, and synchronously cancelled when that feature is disabled.
class OptionalFeatures extends ChangeNotifier {
  OptionalFeatures({this.legacyRoot});
  static final instance = OptionalFeatures();
  static const preferenceKey = 'optional_features_v1';
  static const allCharacterRoles = ['main', 'supporting', 'guest', 'other'];
  static const defaultCharacterRoles = {'main', 'supporting'};
  final Directory? legacyRoot;
  Future<void>? _loading;
  SharedPreferences? _preferences;
  final _enabled = <OptionalFeature>{};
  final _characterRoles = <String>{...defaultCharacterRoles};
  final _scopes = <OptionalFeatureScope, OptionalFeature>{};
  bool _disposed = false;
  bool _voicePhotos = false;
  bool _peopleVisible = true;
  int _bangumiPresentation = 1;
  bool _saving = false;
  bool get voicePhotos => _voicePhotos;
  bool get saving => _saving;
  bool get peopleVisible => _peopleVisible;
  int get bangumiPresentation => _bangumiPresentation;
  Set<String> get characterRoles => Set.unmodifiable(_characterRoles);
  bool enabled(OptionalFeature feature) => _enabled.contains(feature);
  bool available(OptionalFeature feature) =>
      enabled(feature) &&
      _peopleVisible &&
      (feature != OptionalFeature.characters || _bangumiPresentation != 0);

  OptionalFeature? peopleSource({required bool animation}) {
    if (!_peopleVisible) return null;
    if (animation && available(OptionalFeature.characters)) {
      return OptionalFeature.characters;
    }
    return available(OptionalFeature.credits) ? OptionalFeature.credits : null;
  }

  /// All optional services obtain their resource lifetime here, on actual use.
  OptionalFeatureScope openScope(OptionalFeature feature) {
    if (_disposed || !available(feature)) {
      throw StateError('Feature is disabled');
    }
    late final OptionalFeatureScope scope;
    scope = OptionalFeatureScope(() => _scopes.remove(scope));
    _scopes[scope] = feature;
    return scope;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final scope in _scopes.keys.toList()) {
      scope.dispose();
    }
    super.dispose();
  }

  Future<void> initialize() => _loading ??= _load().catchError((Object error) {
    _enabled.clear();
    _characterRoles
      ..clear()
      ..addAll(defaultCharacterRoles);
    _voicePhotos = false;
    throw error;
  });

  Future<void> _load() async {
    final prefs = _preferences = await SharedPreferences.getInstance();
    final stored = prefs.getString(preferenceKey);
    if (stored != null) {
      try {
        final data = jsonDecode(stored) as Map;
        for (final feature in OptionalFeature.values) {
          if (data[feature.name] == true) _enabled.add(feature);
        }
        _voicePhotos = data['voicePhotos'] == true;
        _peopleVisible = data['peopleVisible'] != false;
        final mode = data['bangumiPresentation'];
        _bangumiPresentation = mode is int && mode >= 0 && mode <= 2
            ? mode
            : (_voicePhotos ? 2 : 1);
        final rawRoles = data['characterRoles'];
        if (rawRoles is List) {
          _characterRoles
            ..clear()
            ..addAll(
              rawRoles.whereType<String>().where(allCharacterRoles.contains),
            );
        } else {
          _characterRoles
            ..clear()
            ..addAll(defaultCharacterRoles);
        }
      } catch (_) {
        // Fail closed; preserve unreadable preferences for recovery.
      }
      return;
    }
    // Read known official identities once, without evaluating code or touching
    // the old files. Unknown packages stay on disk but can no longer execute.
    try {
      final root =
          legacyRoot ??
          Directory(
            p.join((await getApplicationSupportDirectory()).path, 'plugins-v1'),
          );
      final registry = File(p.join(root.path, 'registry.json'));
      if (!await registry.exists()) {
        // New installations use Bangumi characters by default; saved opt-outs
        // and legacy installations retain their explicit choices.
        _enabled.add(OptionalFeature.characters);
      }
      if (await registry.exists() && await registry.length() <= 16384) {
        final entries = jsonDecode(await registry.readAsString());
        if (entries is List && entries.length <= 16) {
          for (final entry in entries.whereType<Map>()) {
            final digest = entry['sha256'];
            if (digest is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
              continue;
            }
            final file = File(p.join(root.path, '$digest.json'));
            if (!await file.exists() || await file.length() > 256 * 1024) {
              continue;
            }
            final bytes = await file.readAsBytes();
            if (sha256.convert(bytes).toString() != digest) continue;
            final pack = jsonDecode(utf8.decode(bytes));
            if (pack is! Map) continue;
            final feature = switch (pack['id']) {
              'org.konata.bangumi-characters' => OptionalFeature.characters,
              'org.konata.tmdb-credits' => OptionalFeature.credits,
              _ => null,
            };
            if (feature == null) continue;
            if (entry['enabled'] == true) _enabled.add(feature);
            if (feature == OptionalFeature.characters) {
              _voicePhotos = entry['alternateImages'] == true;
              _bangumiPresentation = _voicePhotos ? 2 : 1;
            }
          }
        }
      }
    } catch (_) {
      // A missing or corrupt legacy registry must not block core startup.
    }
    if (!await prefs.setString(
      preferenceKey,
      _encode(_enabled, _voicePhotos),
    )) {
      throw StateError('Could not save optional feature settings');
    }
  }

  String _encode(
    Set<OptionalFeature> enabled,
    bool photos, {
    bool? peopleVisible,
    int? presentation,
    Set<String>? roles,
  }) {
    final activeRoles = roles ?? _characterRoles;
    return jsonEncode({
      for (final feature in OptionalFeature.values)
        feature.name: enabled.contains(feature),
      'voicePhotos': photos,
      'peopleVisible': peopleVisible ?? _peopleVisible,
      'bangumiPresentation': presentation ?? _bangumiPresentation,
      'characterRoles': [
        for (final role in allCharacterRoles)
          if (activeRoles.contains(role)) role,
      ],
    });
  }

  Future<void> setEnabled(OptionalFeature feature, bool enabled) =>
      _save(feature: feature, enabled: enabled);
  Future<void> setVoicePhotos(bool value) => _save(photos: value);
  Future<void> setPeopleVisible(bool value) => _save(peopleVisible: value);
  Future<void> setCharacterRoles(Set<String> roles) =>
      _save(roles: roles.where(allCharacterRoles.contains).toSet());
  Future<void> setBangumiPresentation(int value) {
    if (value < 0 || value > 2) throw ArgumentError.value(value);
    return _save(presentation: value, photos: value == 0 ? null : value == 2);
  }

  int get characterPresentation =>
      !enabled(OptionalFeature.characters) ? 0 : _bangumiPresentation;
  Future<void> setCharacterPresentation(int value) {
    if (value < 0 || value > 2) throw ArgumentError.value(value);
    return _save(
      feature: OptionalFeature.characters,
      enabled: value != 0,
      photos: value == 0 ? _voicePhotos : value == 2,
      presentation: value == 0 ? null : value,
    );
  }

  Future<void> _save({
    OptionalFeature? feature,
    bool? enabled,
    bool? photos,
    bool? peopleVisible,
    int? presentation,
    Set<String>? roles,
  }) async {
    if (_preferences == null) await initialize();
    if (_saving) return;
    _saving = true;
    notifyListeners();
    try {
      final next = {..._enabled};
      if (feature != null) {
        enabled == true ? next.add(feature) : next.remove(feature);
      }
      final nextPhotos = photos ?? _voicePhotos;
      final nextVisible = peopleVisible ?? _peopleVisible;
      final nextPresentation =
          presentation ??
          (photos == null ? _bangumiPresentation : (photos ? 2 : 1));
      final nextRoles = roles == null ? {..._characterRoles} : {...roles};
      if (!await _preferences!.setString(
        preferenceKey,
        _encode(
          next,
          nextPhotos,
          peopleVisible: nextVisible,
          presentation: nextPresentation,
          roles: nextRoles,
        ),
      )) {
        throw StateError('Could not save optional feature settings');
      }
      _enabled
        ..clear()
        ..addAll(next);
      _voicePhotos = nextPhotos;
      _peopleVisible = nextVisible;
      _bangumiPresentation = nextPresentation;
      _characterRoles
        ..clear()
        ..addAll(nextRoles);
      for (final entry in _scopes.entries.toList()) {
        if (!available(entry.value)) entry.key.dispose();
      }
    } finally {
      _saving = false;
      notifyListeners();
    }
  }
}
