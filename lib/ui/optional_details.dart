import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../core/optional_features.dart';
import '../core/optional_people.dart';
import '../core/optional_feature_scope.dart';
import '../l10n/strings.dart';
import 'people_cards.dart';

typedef PeopleSessionFactory =
    OptionalPeopleSession Function(
      OptionalFeatures settings,
      OptionalFeature feature,
    );

/// The disabled branch never constructs a service, image loader or section.
class OptionalDetails extends StatefulWidget {
  const OptionalDetails({
    super.key,
    required this.work,
    this.legacyCharacters = const [],
    this.legacyCredits = const {},
    this.settings,
    this.sessionFactory,
  });
  final Map<String, Object?> work;
  final List<Map> legacyCharacters;
  final Map<String, List<Map>> legacyCredits;
  final OptionalFeatures? settings;
  final PeopleSessionFactory? sessionFactory;
  @override
  State<OptionalDetails> createState() => _OptionalDetailsState();
}

class _OptionalDetailsState extends State<OptionalDetails> {
  late final settings = widget.settings ?? OptionalFeatures.instance;
  late final ready = settings.initialize();
  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: ready,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done ||
          snapshot.hasError) {
        return const SizedBox.shrink();
      }
      return ListenableBuilder(
        listenable: settings,
        builder: (context, _) => Column(
          children: [
            if (settings.peopleSource(
                  animation: widget.work['is_animation'] != 0,
                )
                case final feature?)
              _PeopleSection(
                key: ValueKey(feature),
                feature: feature,
                settings: settings,
                data: widget,
              ),
          ],
        ),
      );
    },
  );
}

class _PeopleSection extends StatefulWidget {
  const _PeopleSection({
    super.key,
    required this.feature,
    required this.settings,
    required this.data,
  });
  final OptionalFeature feature;
  final OptionalFeatures settings;
  final OptionalDetails data;
  @override
  State<_PeopleSection> createState() => _PeopleSectionState();
}

class _PeopleSectionState extends State<_PeopleSection> {
  OptionalPeopleSession? _session;
  List<Map<String, dynamic>>? _cards;
  bool _failed = false;
  String? _signature;

  String signature() => jsonEncode([
    widget.data.work,
    widget.data.legacyCharacters,
    widget.data.legacyCredits,
    Localizations.localeOf(context).toLanguageTag(),
  ]);
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshIfChanged();
  }

  @override
  void didUpdateWidget(_PeopleSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refreshIfChanged();
  }

  void _refreshIfChanged() {
    final next = signature();
    if (next == _signature) return;
    _signature = next;
    _start();
  }

  void _start() {
    _session?.dispose();
    _cards = null;
    _failed = false;
    if (!widget.settings.enabled(widget.feature)) return;
    final session = _session =
        widget.data.sessionFactory?.call(widget.settings, widget.feature) ??
        OptionalPeopleSession(widget.settings, widget.feature);
    session.onCardsReady = (cards) {
      if (!mounted || _session != session || session.disposed) return;
      setState(() => _cards = cards);
    };
    session
        .load(
          widget.data.work,
          Localizations.localeOf(context).toLanguageTag(),
          characters: widget.data.legacyCharacters,
          credits: widget.data.legacyCredits,
        )
        .then(
          (cards) {
            if (!mounted || _session != session || session.disposed) return;
            setState(() => _cards = cards);
          },
          onError: (Object _, StackTrace _) {
            if (mounted &&
                _session == session &&
                widget.settings.enabled(widget.feature)) {
              setState(() => _failed = _cards == null || session.disposed);
            }
          },
        );
  }

  @override
  void dispose() {
    final session = _session;
    _session = null;
    session?.dispose();
    _cards = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final characters = widget.feature == OptionalFeature.characters;
    return Padding(
      padding: const EdgeInsets.only(top: 32, bottom: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_failed) ...[
            Text(context.l10n.optionalFeatureFailed),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => setState(_start),
                child: Text(context.l10n.retry),
              ),
            ),
          ] else if (_cards == null)
            const LinearProgressIndicator()
          else if (_cards!.isEmpty)
            Text(context.l10n.optionalNoResults)
          else
            PeopleCards(
              cards: _cards!,
              showVoiceActors: characters && widget.settings.voicePhotos,
              imageBuilder: (url) => _PeopleImage(
                key: ValueKey('${identityHashCode(_session)}:$url'),
                session: _session!,
                url: url,
              ),
            ),
        ],
      ),
    );
  }
}

// Only presentation frames survive navigation, never the page's IO session.
// Bound both encoded bytes and decoded frame count; feature shutdown owns eviction.
class _PeopleFrames {
  _PeopleFrames(OptionalPeopleSession session) {
    scope = session.settings.openScope(session.feature);
    scope.acquire(() => entries, (values) {
      for (final value in values.values) { unawaited(value.provider.evict()); }
      values.clear();
      bytes = 0;
    });
  }
  static final pools = Expando<Map<OptionalFeature, _PeopleFrames>>();
  static _PeopleFrames forSession(OptionalPeopleSession session) {
    final features = pools[session.settings] ??= {};
    final previous = features[session.feature];
    if (previous != null && !previous.scope.disposed) return previous;
    return features[session.feature] = _PeopleFrames(session);
  }
  late final OptionalFeatureScope scope;
  final entries = <(String, int), ({ImageProvider provider, int size})>{};
  int bytes = 0;
  ImageProvider? get(String url, int width) {
    scope.checkActive();
    final key = (url, width);
    final hit = entries.remove(key);
    if (hit != null) entries[key] = hit;
    return hit?.provider;
  }
  void evictOtherWidths(String url, int width) {
    for (final key in entries.keys.where((key) => key.$1 == url && key.$2 != width).toList()) {
      final old = entries.remove(key)!;
      bytes -= old.size;
      unawaited(old.provider.evict());
    }
  }
  void put(String url, int width, ImageProvider provider, int size) {
    scope.checkActive();
    const limit = 4 * 1024 * 1024;
    if (size > limit) return;
    final old = entries.remove((url, width));
    if (old != null) { bytes -= old.size; unawaited(old.provider.evict()); }
    while (entries.isNotEmpty && (entries.length >= 16 || bytes + size > limit)) {
      final removed = entries.remove(entries.keys.first)!;
      bytes -= removed.size;
      unawaited(removed.provider.evict());
    }
    entries[(url, width)] = (provider: provider, size: size);
    bytes += size;
  }
}

class _PeopleImage extends StatefulWidget {
  const _PeopleImage({super.key, required this.session, required this.url});
  final OptionalPeopleSession session;
  final String? url;
  @override
  State<_PeopleImage> createState() => _PeopleImageState();
}

class _PeopleImageState extends State<_PeopleImage> {
  final _cancelled = Completer<void>();
  ImageProvider? _provider;
  int _decodeWidth = 160;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final width = (80 * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(
      80,
      400,
    );
    if (_provider == null || width != _decodeWidth) {
      _decodeWidth = width;
      if (widget.url?.isNotEmpty == true) _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final frames = _PeopleFrames.forSession(widget.session);
      final url = widget.url!;
      final width = _decodeWidth;
      void evictAfterReplacement() {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation && !frames.scope.disposed) {
            frames.evictOtherWidths(url, width);
          }
        });
      }
      final hit = frames.get(url, width);
      if (hit != null) {
        _provider = hit;
        evictAfterReplacement();
        return;
      }
      final Uint8List bytes = await widget.session.image(
        widget.url!,
        _cancelled.future,
        displayWidth: ((_decodeWidth + 79) ~/ 80) * 80,
      );
      if (!mounted || widget.session.disposed || generation != _generation) {
        return;
      }
      final next = ResizeImage.resizeIfNeeded(
        _decodeWidth,
        null,
        MemoryImage(bytes),
      );
      frames.put(widget.url!, _decodeWidth, next, bytes.length);
      setState(() => _provider = next);
      evictAfterReplacement();
    } catch (_) {
      /* Artwork failure leaves a lightweight placeholder. */
    }
  }

  @override
  void dispose() {
    _cancelled.complete();
    // The bounded feature scope keeps recent frames until eviction or shutdown.
    _provider = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipOval(
    child: SizedBox(
      width: 80,
      height: 80,
      child: _provider == null
          ? const Icon(Icons.person_outline, size: 40)
          : Image(
              image: _provider!,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.person_outline, size: 40),
            ),
    ),
  );
}
