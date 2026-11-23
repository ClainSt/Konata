// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'konata_database.dart';

// ignore_for_file: type=lint
class $MediaSourcesTable extends MediaSources
    with TableInfo<$MediaSourcesTable, MediaSourceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaSourcesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<MediaSourceKind, String> kind =
      GeneratedColumn<String>(
        'kind',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<MediaSourceKind>($MediaSourcesTable.$converterkind);
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  @override
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
    'label',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _locationMeta = const VerificationMeta(
    'location',
  );
  @override
  late final GeneratedColumn<String> location = GeneratedColumn<String>(
    'location',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    label,
    location,
    username,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_sources';
  @override
  VerificationContext validateIntegrity(
    Insertable<MediaSourceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('label')) {
      context.handle(
        _labelMeta,
        label.isAcceptableOrUnknown(data['label']!, _labelMeta),
      );
    } else if (isInserting) {
      context.missing(_labelMeta);
    }
    if (data.containsKey('location')) {
      context.handle(
        _locationMeta,
        location.isAcceptableOrUnknown(data['location']!, _locationMeta),
      );
    } else if (isInserting) {
      context.missing(_locationMeta);
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MediaSourceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaSourceRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      kind: $MediaSourcesTable.$converterkind.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}kind'],
        )!,
      ),
      label: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}label'],
      )!,
      location: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}location'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      ),
    );
  }

  @override
  $MediaSourcesTable createAlias(String alias) {
    return $MediaSourcesTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<MediaSourceKind, String, String> $converterkind =
      const EnumNameConverter<MediaSourceKind>(MediaSourceKind.values);
}

class MediaSourceRow extends DataClass implements Insertable<MediaSourceRow> {
  /// 媒体源唯一主键。
  final String id;

  /// 协议类型。
  final MediaSourceKind kind;

  /// 显示名称。
  final String label;

  /// 本地根路径或远程地址。
  final String location;

  /// 可选用户名。
  final String? username;

  /// 创建时间戳。
  final DateTime? createdAt;
  const MediaSourceRow({
    required this.id,
    required this.kind,
    required this.label,
    required this.location,
    this.username,
    this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    {
      map['kind'] = Variable<String>(
        $MediaSourcesTable.$converterkind.toSql(kind),
      );
    }
    map['label'] = Variable<String>(label);
    map['location'] = Variable<String>(location);
    if (!nullToAbsent || username != null) {
      map['username'] = Variable<String>(username);
    }
    if (!nullToAbsent || createdAt != null) {
      map['created_at'] = Variable<DateTime>(createdAt);
    }
    return map;
  }

  MediaSourcesCompanion toCompanion(bool nullToAbsent) {
    return MediaSourcesCompanion(
      id: Value(id),
      kind: Value(kind),
      label: Value(label),
      location: Value(location),
      username: username == null && nullToAbsent
          ? const Value.absent()
          : Value(username),
      createdAt: createdAt == null && nullToAbsent
          ? const Value.absent()
          : Value(createdAt),
    );
  }

  factory MediaSourceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaSourceRow(
      id: serializer.fromJson<String>(json['id']),
      kind: $MediaSourcesTable.$converterkind.fromJson(
        serializer.fromJson<String>(json['kind']),
      ),
      label: serializer.fromJson<String>(json['label']),
      location: serializer.fromJson<String>(json['location']),
      username: serializer.fromJson<String?>(json['username']),
      createdAt: serializer.fromJson<DateTime?>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(
        $MediaSourcesTable.$converterkind.toJson(kind),
      ),
      'label': serializer.toJson<String>(label),
      'location': serializer.toJson<String>(location),
      'username': serializer.toJson<String?>(username),
      'createdAt': serializer.toJson<DateTime?>(createdAt),
    };
  }

  MediaSourceRow copyWith({
    String? id,
    MediaSourceKind? kind,
    String? label,
    String? location,
    Value<String?> username = const Value.absent(),
    Value<DateTime?> createdAt = const Value.absent(),
  }) => MediaSourceRow(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    label: label ?? this.label,
    location: location ?? this.location,
    username: username.present ? username.value : this.username,
    createdAt: createdAt.present ? createdAt.value : this.createdAt,
  );
  MediaSourceRow copyWithCompanion(MediaSourcesCompanion data) {
    return MediaSourceRow(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      label: data.label.present ? data.label.value : this.label,
      location: data.location.present ? data.location.value : this.location,
      username: data.username.present ? data.username.value : this.username,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaSourceRow(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('label: $label, ')
          ..write('location: $location, ')
          ..write('username: $username, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, kind, label, location, username, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaSourceRow &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.label == this.label &&
          other.location == this.location &&
          other.username == this.username &&
          other.createdAt == this.createdAt);
}

class MediaSourcesCompanion extends UpdateCompanion<MediaSourceRow> {
  final Value<String> id;
  final Value<MediaSourceKind> kind;
  final Value<String> label;
  final Value<String> location;
  final Value<String?> username;
  final Value<DateTime?> createdAt;
  final Value<int> rowid;
  const MediaSourcesCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.label = const Value.absent(),
    this.location = const Value.absent(),
    this.username = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MediaSourcesCompanion.insert({
    required String id,
    required MediaSourceKind kind,
    required String label,
    required String location,
    this.username = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       kind = Value(kind),
       label = Value(label),
       location = Value(location);
  static Insertable<MediaSourceRow> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<String>? label,
    Expression<String>? location,
    Expression<String>? username,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (label != null) 'label': label,
      if (location != null) 'location': location,
      if (username != null) 'username': username,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MediaSourcesCompanion copyWith({
    Value<String>? id,
    Value<MediaSourceKind>? kind,
    Value<String>? label,
    Value<String>? location,
    Value<String?>? username,
    Value<DateTime?>? createdAt,
    Value<int>? rowid,
  }) {
    return MediaSourcesCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      label: label ?? this.label,
      location: location ?? this.location,
      username: username ?? this.username,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(
        $MediaSourcesTable.$converterkind.toSql(kind.value),
      );
    }
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (location.present) {
      map['location'] = Variable<String>(location.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MediaSourcesCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('label: $label, ')
          ..write('location: $location, ')
          ..write('username: $username, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $WorksTable extends Works with TableInfo<$WorksTable, WorkRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $WorksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tmdbIdMeta = const VerificationMeta('tmdbId');
  @override
  late final GeneratedColumn<int> tmdbId = GeneratedColumn<int>(
    'tmdb_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bangumiIdMeta = const VerificationMeta(
    'bangumiId',
  );
  @override
  late final GeneratedColumn<int> bangumiId = GeneratedColumn<int>(
    'bangumi_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tvdbIdMeta = const VerificationMeta('tvdbId');
  @override
  late final GeneratedColumn<int> tvdbId = GeneratedColumn<int>(
    'tvdb_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<TmdbMediaType?, String>
  tmdbMediaType = GeneratedColumn<String>(
    'tmdb_media_type',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  ).withConverter<TmdbMediaType?>($WorksTable.$convertertmdbMediaTypen);
  static const VerificationMeta _matchedSeasonMeta = const VerificationMeta(
    'matchedSeason',
  );
  @override
  late final GeneratedColumn<int> matchedSeason = GeneratedColumn<int>(
    'matched_season',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _originalTitleMeta = const VerificationMeta(
    'originalTitle',
  );
  @override
  late final GeneratedColumn<String> originalTitle = GeneratedColumn<String>(
    'original_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _yearMeta = const VerificationMeta('year');
  @override
  late final GeneratedColumn<int> year = GeneratedColumn<int>(
    'year',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _overviewMeta = const VerificationMeta(
    'overview',
  );
  @override
  late final GeneratedColumn<String> overview = GeneratedColumn<String>(
    'overview',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _posterPathMeta = const VerificationMeta(
    'posterPath',
  );
  @override
  late final GeneratedColumn<String> posterPath = GeneratedColumn<String>(
    'poster_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _posterFallbackMeta = const VerificationMeta(
    'posterFallback',
  );
  @override
  late final GeneratedColumn<String> posterFallback = GeneratedColumn<String>(
    'poster_fallback',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bangumiPosterPathMeta = const VerificationMeta(
    'bangumiPosterPath',
  );
  @override
  late final GeneratedColumn<String> bangumiPosterPath =
      GeneratedColumn<String>(
        'bangumi_poster_path',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _backdropPathMeta = const VerificationMeta(
    'backdropPath',
  );
  @override
  late final GeneratedColumn<String> backdropPath = GeneratedColumn<String>(
    'backdrop_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _logoPathMeta = const VerificationMeta(
    'logoPath',
  );
  @override
  late final GeneratedColumn<String> logoPath = GeneratedColumn<String>(
    'logo_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _voteAverageMeta = const VerificationMeta(
    'voteAverage',
  );
  @override
  late final GeneratedColumn<double> voteAverage = GeneratedColumn<double>(
    'vote_average',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bangumiScoreMeta = const VerificationMeta(
    'bangumiScore',
  );
  @override
  late final GeneratedColumn<double> bangumiScore = GeneratedColumn<double>(
    'bangumi_score',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _folderTmdbHintMeta = const VerificationMeta(
    'folderTmdbHint',
  );
  @override
  late final GeneratedColumn<int> folderTmdbHint = GeneratedColumn<int>(
    'folder_tmdb_hint',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isManualLockedMeta = const VerificationMeta(
    'isManualLocked',
  );
  @override
  late final GeneratedColumn<bool> isManualLocked = GeneratedColumn<bool>(
    'is_manual_locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_manual_locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _metadataLockedMeta = const VerificationMeta(
    'metadataLocked',
  );
  @override
  late final GeneratedColumn<bool> metadataLocked = GeneratedColumn<bool>(
    'metadata_locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("metadata_locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _posterLockedMeta = const VerificationMeta(
    'posterLocked',
  );
  @override
  late final GeneratedColumn<bool> posterLocked = GeneratedColumn<bool>(
    'poster_locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("poster_locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _backdropLockedMeta = const VerificationMeta(
    'backdropLocked',
  );
  @override
  late final GeneratedColumn<bool> backdropLocked = GeneratedColumn<bool>(
    'backdrop_locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("backdrop_locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _logoLockedMeta = const VerificationMeta(
    'logoLocked',
  );
  @override
  late final GeneratedColumn<bool> logoLocked = GeneratedColumn<bool>(
    'logo_locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("logo_locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _logoNegativeUntilMeta = const VerificationMeta(
    'logoNegativeUntil',
  );
  @override
  late final GeneratedColumn<DateTime> logoNegativeUntil =
      GeneratedColumn<DateTime>(
        'logo_negative_until',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _logoNegativeMaskMeta = const VerificationMeta(
    'logoNegativeMask',
  );
  @override
  late final GeneratedColumn<int> logoNegativeMask = GeneratedColumn<int>(
    'logo_negative_mask',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isHiddenMeta = const VerificationMeta(
    'isHidden',
  );
  @override
  late final GeneratedColumn<bool> isHidden = GeneratedColumn<bool>(
    'is_hidden',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_hidden" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _keepHiddenMeta = const VerificationMeta(
    'keepHidden',
  );
  @override
  late final GeneratedColumn<bool> keepHidden = GeneratedColumn<bool>(
    'keep_hidden',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("keep_hidden" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  late final GeneratedColumnWithTypeConverter<ScrapeStatus, String>
  scrapeStatus = GeneratedColumn<String>(
    'scrape_status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  ).withConverter<ScrapeStatus>($WorksTable.$converterscrapeStatus);
  static const VerificationMeta _reviewReasonMeta = const VerificationMeta(
    'reviewReason',
  );
  @override
  late final GeneratedColumn<String> reviewReason = GeneratedColumn<String>(
    'review_reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _seriesIdMeta = const VerificationMeta(
    'seriesId',
  );
  @override
  late final GeneratedColumn<String> seriesId = GeneratedColumn<String>(
    'series_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _seriesOrderMeta = const VerificationMeta(
    'seriesOrder',
  );
  @override
  late final GeneratedColumn<int> seriesOrder = GeneratedColumn<int>(
    'series_order',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _seriesLabelMeta = const VerificationMeta(
    'seriesLabel',
  );
  @override
  late final GeneratedColumn<String> seriesLabel = GeneratedColumn<String>(
    'series_label',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _seriesLockedMeta = const VerificationMeta(
    'seriesLocked',
  );
  @override
  late final GeneratedColumn<bool> seriesLocked = GeneratedColumn<bool>(
    'series_locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("series_locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _updatedAtMsMeta = const VerificationMeta(
    'updatedAtMs',
  );
  @override
  late final GeneratedColumn<int> updatedAtMs = GeneratedColumn<int>(
    'updated_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    tmdbId,
    bangumiId,
    tvdbId,
    tmdbMediaType,
    matchedSeason,
    title,
    originalTitle,
    year,
    overview,
    posterPath,
    posterFallback,
    bangumiPosterPath,
    backdropPath,
    logoPath,
    voteAverage,
    bangumiScore,
    folderTmdbHint,
    isManualLocked,
    metadataLocked,
    posterLocked,
    backdropLocked,
    logoLocked,
    logoNegativeUntil,
    logoNegativeMask,
    isHidden,
    keepHidden,
    scrapeStatus,
    reviewReason,
    seriesId,
    seriesOrder,
    seriesLabel,
    seriesLocked,
    updatedAtMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'works';
  @override
  VerificationContext validateIntegrity(
    Insertable<WorkRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('tmdb_id')) {
      context.handle(
        _tmdbIdMeta,
        tmdbId.isAcceptableOrUnknown(data['tmdb_id']!, _tmdbIdMeta),
      );
    }
    if (data.containsKey('bangumi_id')) {
      context.handle(
        _bangumiIdMeta,
        bangumiId.isAcceptableOrUnknown(data['bangumi_id']!, _bangumiIdMeta),
      );
    }
    if (data.containsKey('tvdb_id')) {
      context.handle(
        _tvdbIdMeta,
        tvdbId.isAcceptableOrUnknown(data['tvdb_id']!, _tvdbIdMeta),
      );
    }
    if (data.containsKey('matched_season')) {
      context.handle(
        _matchedSeasonMeta,
        matchedSeason.isAcceptableOrUnknown(
          data['matched_season']!,
          _matchedSeasonMeta,
        ),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('original_title')) {
      context.handle(
        _originalTitleMeta,
        originalTitle.isAcceptableOrUnknown(
          data['original_title']!,
          _originalTitleMeta,
        ),
      );
    }
    if (data.containsKey('year')) {
      context.handle(
        _yearMeta,
        year.isAcceptableOrUnknown(data['year']!, _yearMeta),
      );
    }
    if (data.containsKey('overview')) {
      context.handle(
        _overviewMeta,
        overview.isAcceptableOrUnknown(data['overview']!, _overviewMeta),
      );
    }
    if (data.containsKey('poster_path')) {
      context.handle(
        _posterPathMeta,
        posterPath.isAcceptableOrUnknown(data['poster_path']!, _posterPathMeta),
      );
    }
    if (data.containsKey('poster_fallback')) {
      context.handle(
        _posterFallbackMeta,
        posterFallback.isAcceptableOrUnknown(
          data['poster_fallback']!,
          _posterFallbackMeta,
        ),
      );
    }
    if (data.containsKey('bangumi_poster_path')) {
      context.handle(
        _bangumiPosterPathMeta,
        bangumiPosterPath.isAcceptableOrUnknown(
          data['bangumi_poster_path']!,
          _bangumiPosterPathMeta,
        ),
      );
    }
    if (data.containsKey('backdrop_path')) {
      context.handle(
        _backdropPathMeta,
        backdropPath.isAcceptableOrUnknown(
          data['backdrop_path']!,
          _backdropPathMeta,
        ),
      );
    }
    if (data.containsKey('logo_path')) {
      context.handle(
        _logoPathMeta,
        logoPath.isAcceptableOrUnknown(data['logo_path']!, _logoPathMeta),
      );
    }
    if (data.containsKey('vote_average')) {
      context.handle(
        _voteAverageMeta,
        voteAverage.isAcceptableOrUnknown(
          data['vote_average']!,
          _voteAverageMeta,
        ),
      );
    }
    if (data.containsKey('bangumi_score')) {
      context.handle(
        _bangumiScoreMeta,
        bangumiScore.isAcceptableOrUnknown(
          data['bangumi_score']!,
          _bangumiScoreMeta,
        ),
      );
    }
    if (data.containsKey('folder_tmdb_hint')) {
      context.handle(
        _folderTmdbHintMeta,
        folderTmdbHint.isAcceptableOrUnknown(
          data['folder_tmdb_hint']!,
          _folderTmdbHintMeta,
        ),
      );
    }
    if (data.containsKey('is_manual_locked')) {
      context.handle(
        _isManualLockedMeta,
        isManualLocked.isAcceptableOrUnknown(
          data['is_manual_locked']!,
          _isManualLockedMeta,
        ),
      );
    }
    if (data.containsKey('metadata_locked')) {
      context.handle(
        _metadataLockedMeta,
        metadataLocked.isAcceptableOrUnknown(
          data['metadata_locked']!,
          _metadataLockedMeta,
        ),
      );
    }
    if (data.containsKey('poster_locked')) {
      context.handle(
        _posterLockedMeta,
        posterLocked.isAcceptableOrUnknown(
          data['poster_locked']!,
          _posterLockedMeta,
        ),
      );
    }
    if (data.containsKey('backdrop_locked')) {
      context.handle(
        _backdropLockedMeta,
        backdropLocked.isAcceptableOrUnknown(
          data['backdrop_locked']!,
          _backdropLockedMeta,
        ),
      );
    }
    if (data.containsKey('logo_locked')) {
      context.handle(
        _logoLockedMeta,
        logoLocked.isAcceptableOrUnknown(data['logo_locked']!, _logoLockedMeta),
      );
    }
    if (data.containsKey('logo_negative_until')) {
      context.handle(
        _logoNegativeUntilMeta,
        logoNegativeUntil.isAcceptableOrUnknown(
          data['logo_negative_until']!,
          _logoNegativeUntilMeta,
        ),
      );
    }
    if (data.containsKey('logo_negative_mask')) {
      context.handle(
        _logoNegativeMaskMeta,
        logoNegativeMask.isAcceptableOrUnknown(
          data['logo_negative_mask']!,
          _logoNegativeMaskMeta,
        ),
      );
    }
    if (data.containsKey('is_hidden')) {
      context.handle(
        _isHiddenMeta,
        isHidden.isAcceptableOrUnknown(data['is_hidden']!, _isHiddenMeta),
      );
    }
    if (data.containsKey('keep_hidden')) {
      context.handle(
        _keepHiddenMeta,
        keepHidden.isAcceptableOrUnknown(data['keep_hidden']!, _keepHiddenMeta),
      );
    }
    if (data.containsKey('review_reason')) {
      context.handle(
        _reviewReasonMeta,
        reviewReason.isAcceptableOrUnknown(
          data['review_reason']!,
          _reviewReasonMeta,
        ),
      );
    }
    if (data.containsKey('series_id')) {
      context.handle(
        _seriesIdMeta,
        seriesId.isAcceptableOrUnknown(data['series_id']!, _seriesIdMeta),
      );
    }
    if (data.containsKey('series_order')) {
      context.handle(
        _seriesOrderMeta,
        seriesOrder.isAcceptableOrUnknown(
          data['series_order']!,
          _seriesOrderMeta,
        ),
      );
    }
    if (data.containsKey('series_label')) {
      context.handle(
        _seriesLabelMeta,
        seriesLabel.isAcceptableOrUnknown(
          data['series_label']!,
          _seriesLabelMeta,
        ),
      );
    }
    if (data.containsKey('series_locked')) {
      context.handle(
        _seriesLockedMeta,
        seriesLocked.isAcceptableOrUnknown(
          data['series_locked']!,
          _seriesLockedMeta,
        ),
      );
    }
    if (data.containsKey('updated_at_ms')) {
      context.handle(
        _updatedAtMsMeta,
        updatedAtMs.isAcceptableOrUnknown(
          data['updated_at_ms']!,
          _updatedAtMsMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  WorkRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return WorkRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      tmdbId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tmdb_id'],
      ),
      bangumiId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bangumi_id'],
      ),
      tvdbId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tvdb_id'],
      ),
      tmdbMediaType: $WorksTable.$convertertmdbMediaTypen.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}tmdb_media_type'],
        ),
      ),
      matchedSeason: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}matched_season'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      originalTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}original_title'],
      ),
      year: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}year'],
      ),
      overview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}overview'],
      ),
      posterPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}poster_path'],
      ),
      posterFallback: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}poster_fallback'],
      ),
      bangumiPosterPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bangumi_poster_path'],
      ),
      backdropPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}backdrop_path'],
      ),
      logoPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}logo_path'],
      ),
      voteAverage: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}vote_average'],
      ),
      bangumiScore: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}bangumi_score'],
      ),
      folderTmdbHint: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}folder_tmdb_hint'],
      ),
      isManualLocked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_manual_locked'],
      )!,
      metadataLocked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}metadata_locked'],
      )!,
      posterLocked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}poster_locked'],
      )!,
      backdropLocked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}backdrop_locked'],
      )!,
      logoLocked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}logo_locked'],
      )!,
      logoNegativeUntil: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}logo_negative_until'],
      ),
      logoNegativeMask: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}logo_negative_mask'],
      )!,
      isHidden: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_hidden'],
      )!,
      keepHidden: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}keep_hidden'],
      )!,
      scrapeStatus: $WorksTable.$converterscrapeStatus.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}scrape_status'],
        )!,
      ),
      reviewReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}review_reason'],
      ),
      seriesId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}series_id'],
      ),
      seriesOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}series_order'],
      ),
      seriesLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}series_label'],
      ),
      seriesLocked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}series_locked'],
      )!,
      updatedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_ms'],
      )!,
    );
  }

  @override
  $WorksTable createAlias(String alias) {
    return $WorksTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<TmdbMediaType, String, String>
  $convertertmdbMediaType = const EnumNameConverter<TmdbMediaType>(
    TmdbMediaType.values,
  );
  static JsonTypeConverter2<TmdbMediaType?, String?, String?>
  $convertertmdbMediaTypen = JsonTypeConverter2.asNullable(
    $convertertmdbMediaType,
  );
  static JsonTypeConverter2<ScrapeStatus, String, String>
  $converterscrapeStatus = const EnumNameConverter<ScrapeStatus>(
    ScrapeStatus.values,
  );
}

class WorkRow extends DataClass implements Insertable<WorkRow> {
  /// 作品唯一主键（UUID）。
  final String id;

  /// TMDB 绑定 ID。
  final int? tmdbId;

  /// Bangumi 辅助条目 ID。
  final int? bangumiId;

  /// TheTVDB 关联剧集 ID（用于直接对接 Fanart.tv 剧集接口）。
  final int? tvdbId;

  /// TMDB 条目类型（`tv` / `movie`）。
  final TmdbMediaType? tmdbMediaType;

  /// 季级匹配绑定季号（例如 `Wake Up, Girls! 新章` 绑定第 2 季）。
  final int? matchedSeason;

  /// 展示标题。
  final String title;

  /// 原始语言标题。
  final String? originalTitle;

  /// 发行年份。
  final int? year;

  /// 作品简介。
  final String? overview;

  /// 海报路径。
  final String? posterPath;

  /// 剧集级海报回退路径。
  final String? posterFallback;

  /// 关联的 Bangumi 官方封面 URL（用于详情页封面切换与回落展示）。
  final String? bangumiPosterPath;

  /// 背景图路径。
  final String? backdropPath;

  /// 官方透明 PNG 标题 Logo 路径。
  final String? logoPath;

  /// TMDB 评分（0.0 ~ 10.0）。
  final double? voteAverage;

  /// 关联 Bangumi 条目评分（0.0 ~ 10.0）。
  final double? bangumiScore;

  /// 从文件夹名提取的显式 TMDB ID 提示。
  final int? folderTmdbHint;

  /// 是否已人工锁定（防止自动刮削更换绑定条目）。
  final bool isManualLocked;

  /// 基础元数据（标题/原名/年份/简介/匹配季）是否已人工锁定。
  final bool metadataLocked;

  /// 封面海报是否已人工锁定。
  final bool posterLocked;

  /// 横版背景原画是否已人工锁定。
  final bool backdropLocked;

  /// 透明标题徽标是否已人工锁定。
  final bool logoLocked;

  /// 透明标题徽标负缓存冷却截止时间。
  final DateTime? logoNegativeUntil;

  /// 透明标题徽标负缓存探测数据源位掩码。
  final int logoNegativeMask;

  /// 是否在主媒体库隐藏。
  final bool isHidden;

  /// 重扫时是否继续保持隐藏。
  final bool keepHidden;

  /// 刮削状态。
  final ScrapeStatus scrapeStatus;

  /// 作品级待复核/未匹配原因码。
  final String? reviewReason;

  /// 所属系列 ID。
  final String? seriesId;

  /// 在所属系列中的排序序号。
  final int? seriesOrder;

  /// 在所属系列中的展示标签。
  final String? seriesLabel;

  /// 系列编组与标签是否已人工锁定。
  final bool seriesLocked;

  /// 最近一次元数据或人工锁定变更的 UTC 毫秒时间戳（供多设备增量同步判定新旧）。
  final int updatedAtMs;
  const WorkRow({
    required this.id,
    this.tmdbId,
    this.bangumiId,
    this.tvdbId,
    this.tmdbMediaType,
    this.matchedSeason,
    required this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.posterPath,
    this.posterFallback,
    this.bangumiPosterPath,
    this.backdropPath,
    this.logoPath,
    this.voteAverage,
    this.bangumiScore,
    this.folderTmdbHint,
    required this.isManualLocked,
    required this.metadataLocked,
    required this.posterLocked,
    required this.backdropLocked,
    required this.logoLocked,
    this.logoNegativeUntil,
    required this.logoNegativeMask,
    required this.isHidden,
    required this.keepHidden,
    required this.scrapeStatus,
    this.reviewReason,
    this.seriesId,
    this.seriesOrder,
    this.seriesLabel,
    required this.seriesLocked,
    required this.updatedAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || tmdbId != null) {
      map['tmdb_id'] = Variable<int>(tmdbId);
    }
    if (!nullToAbsent || bangumiId != null) {
      map['bangumi_id'] = Variable<int>(bangumiId);
    }
    if (!nullToAbsent || tvdbId != null) {
      map['tvdb_id'] = Variable<int>(tvdbId);
    }
    if (!nullToAbsent || tmdbMediaType != null) {
      map['tmdb_media_type'] = Variable<String>(
        $WorksTable.$convertertmdbMediaTypen.toSql(tmdbMediaType),
      );
    }
    if (!nullToAbsent || matchedSeason != null) {
      map['matched_season'] = Variable<int>(matchedSeason);
    }
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || originalTitle != null) {
      map['original_title'] = Variable<String>(originalTitle);
    }
    if (!nullToAbsent || year != null) {
      map['year'] = Variable<int>(year);
    }
    if (!nullToAbsent || overview != null) {
      map['overview'] = Variable<String>(overview);
    }
    if (!nullToAbsent || posterPath != null) {
      map['poster_path'] = Variable<String>(posterPath);
    }
    if (!nullToAbsent || posterFallback != null) {
      map['poster_fallback'] = Variable<String>(posterFallback);
    }
    if (!nullToAbsent || bangumiPosterPath != null) {
      map['bangumi_poster_path'] = Variable<String>(bangumiPosterPath);
    }
    if (!nullToAbsent || backdropPath != null) {
      map['backdrop_path'] = Variable<String>(backdropPath);
    }
    if (!nullToAbsent || logoPath != null) {
      map['logo_path'] = Variable<String>(logoPath);
    }
    if (!nullToAbsent || voteAverage != null) {
      map['vote_average'] = Variable<double>(voteAverage);
    }
    if (!nullToAbsent || bangumiScore != null) {
      map['bangumi_score'] = Variable<double>(bangumiScore);
    }
    if (!nullToAbsent || folderTmdbHint != null) {
      map['folder_tmdb_hint'] = Variable<int>(folderTmdbHint);
    }
    map['is_manual_locked'] = Variable<bool>(isManualLocked);
    map['metadata_locked'] = Variable<bool>(metadataLocked);
    map['poster_locked'] = Variable<bool>(posterLocked);
    map['backdrop_locked'] = Variable<bool>(backdropLocked);
    map['logo_locked'] = Variable<bool>(logoLocked);
    if (!nullToAbsent || logoNegativeUntil != null) {
      map['logo_negative_until'] = Variable<DateTime>(logoNegativeUntil);
    }
    map['logo_negative_mask'] = Variable<int>(logoNegativeMask);
    map['is_hidden'] = Variable<bool>(isHidden);
    map['keep_hidden'] = Variable<bool>(keepHidden);
    {
      map['scrape_status'] = Variable<String>(
        $WorksTable.$converterscrapeStatus.toSql(scrapeStatus),
      );
    }
    if (!nullToAbsent || reviewReason != null) {
      map['review_reason'] = Variable<String>(reviewReason);
    }
    if (!nullToAbsent || seriesId != null) {
      map['series_id'] = Variable<String>(seriesId);
    }
    if (!nullToAbsent || seriesOrder != null) {
      map['series_order'] = Variable<int>(seriesOrder);
    }
    if (!nullToAbsent || seriesLabel != null) {
      map['series_label'] = Variable<String>(seriesLabel);
    }
    map['series_locked'] = Variable<bool>(seriesLocked);
    map['updated_at_ms'] = Variable<int>(updatedAtMs);
    return map;
  }

  WorksCompanion toCompanion(bool nullToAbsent) {
    return WorksCompanion(
      id: Value(id),
      tmdbId: tmdbId == null && nullToAbsent
          ? const Value.absent()
          : Value(tmdbId),
      bangumiId: bangumiId == null && nullToAbsent
          ? const Value.absent()
          : Value(bangumiId),
      tvdbId: tvdbId == null && nullToAbsent
          ? const Value.absent()
          : Value(tvdbId),
      tmdbMediaType: tmdbMediaType == null && nullToAbsent
          ? const Value.absent()
          : Value(tmdbMediaType),
      matchedSeason: matchedSeason == null && nullToAbsent
          ? const Value.absent()
          : Value(matchedSeason),
      title: Value(title),
      originalTitle: originalTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(originalTitle),
      year: year == null && nullToAbsent ? const Value.absent() : Value(year),
      overview: overview == null && nullToAbsent
          ? const Value.absent()
          : Value(overview),
      posterPath: posterPath == null && nullToAbsent
          ? const Value.absent()
          : Value(posterPath),
      posterFallback: posterFallback == null && nullToAbsent
          ? const Value.absent()
          : Value(posterFallback),
      bangumiPosterPath: bangumiPosterPath == null && nullToAbsent
          ? const Value.absent()
          : Value(bangumiPosterPath),
      backdropPath: backdropPath == null && nullToAbsent
          ? const Value.absent()
          : Value(backdropPath),
      logoPath: logoPath == null && nullToAbsent
          ? const Value.absent()
          : Value(logoPath),
      voteAverage: voteAverage == null && nullToAbsent
          ? const Value.absent()
          : Value(voteAverage),
      bangumiScore: bangumiScore == null && nullToAbsent
          ? const Value.absent()
          : Value(bangumiScore),
      folderTmdbHint: folderTmdbHint == null && nullToAbsent
          ? const Value.absent()
          : Value(folderTmdbHint),
      isManualLocked: Value(isManualLocked),
      metadataLocked: Value(metadataLocked),
      posterLocked: Value(posterLocked),
      backdropLocked: Value(backdropLocked),
      logoLocked: Value(logoLocked),
      logoNegativeUntil: logoNegativeUntil == null && nullToAbsent
          ? const Value.absent()
          : Value(logoNegativeUntil),
      logoNegativeMask: Value(logoNegativeMask),
      isHidden: Value(isHidden),
      keepHidden: Value(keepHidden),
      scrapeStatus: Value(scrapeStatus),
      reviewReason: reviewReason == null && nullToAbsent
          ? const Value.absent()
          : Value(reviewReason),
      seriesId: seriesId == null && nullToAbsent
          ? const Value.absent()
          : Value(seriesId),
      seriesOrder: seriesOrder == null && nullToAbsent
          ? const Value.absent()
          : Value(seriesOrder),
      seriesLabel: seriesLabel == null && nullToAbsent
          ? const Value.absent()
          : Value(seriesLabel),
      seriesLocked: Value(seriesLocked),
      updatedAtMs: Value(updatedAtMs),
    );
  }

  factory WorkRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return WorkRow(
      id: serializer.fromJson<String>(json['id']),
      tmdbId: serializer.fromJson<int?>(json['tmdbId']),
      bangumiId: serializer.fromJson<int?>(json['bangumiId']),
      tvdbId: serializer.fromJson<int?>(json['tvdbId']),
      tmdbMediaType: $WorksTable.$convertertmdbMediaTypen.fromJson(
        serializer.fromJson<String?>(json['tmdbMediaType']),
      ),
      matchedSeason: serializer.fromJson<int?>(json['matchedSeason']),
      title: serializer.fromJson<String>(json['title']),
      originalTitle: serializer.fromJson<String?>(json['originalTitle']),
      year: serializer.fromJson<int?>(json['year']),
      overview: serializer.fromJson<String?>(json['overview']),
      posterPath: serializer.fromJson<String?>(json['posterPath']),
      posterFallback: serializer.fromJson<String?>(json['posterFallback']),
      bangumiPosterPath: serializer.fromJson<String?>(
        json['bangumiPosterPath'],
      ),
      backdropPath: serializer.fromJson<String?>(json['backdropPath']),
      logoPath: serializer.fromJson<String?>(json['logoPath']),
      voteAverage: serializer.fromJson<double?>(json['voteAverage']),
      bangumiScore: serializer.fromJson<double?>(json['bangumiScore']),
      folderTmdbHint: serializer.fromJson<int?>(json['folderTmdbHint']),
      isManualLocked: serializer.fromJson<bool>(json['isManualLocked']),
      metadataLocked: serializer.fromJson<bool>(json['metadataLocked']),
      posterLocked: serializer.fromJson<bool>(json['posterLocked']),
      backdropLocked: serializer.fromJson<bool>(json['backdropLocked']),
      logoLocked: serializer.fromJson<bool>(json['logoLocked']),
      logoNegativeUntil: serializer.fromJson<DateTime?>(
        json['logoNegativeUntil'],
      ),
      logoNegativeMask: serializer.fromJson<int>(json['logoNegativeMask']),
      isHidden: serializer.fromJson<bool>(json['isHidden']),
      keepHidden: serializer.fromJson<bool>(json['keepHidden']),
      scrapeStatus: $WorksTable.$converterscrapeStatus.fromJson(
        serializer.fromJson<String>(json['scrapeStatus']),
      ),
      reviewReason: serializer.fromJson<String?>(json['reviewReason']),
      seriesId: serializer.fromJson<String?>(json['seriesId']),
      seriesOrder: serializer.fromJson<int?>(json['seriesOrder']),
      seriesLabel: serializer.fromJson<String?>(json['seriesLabel']),
      seriesLocked: serializer.fromJson<bool>(json['seriesLocked']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'tmdbId': serializer.toJson<int?>(tmdbId),
      'bangumiId': serializer.toJson<int?>(bangumiId),
      'tvdbId': serializer.toJson<int?>(tvdbId),
      'tmdbMediaType': serializer.toJson<String?>(
        $WorksTable.$convertertmdbMediaTypen.toJson(tmdbMediaType),
      ),
      'matchedSeason': serializer.toJson<int?>(matchedSeason),
      'title': serializer.toJson<String>(title),
      'originalTitle': serializer.toJson<String?>(originalTitle),
      'year': serializer.toJson<int?>(year),
      'overview': serializer.toJson<String?>(overview),
      'posterPath': serializer.toJson<String?>(posterPath),
      'posterFallback': serializer.toJson<String?>(posterFallback),
      'bangumiPosterPath': serializer.toJson<String?>(bangumiPosterPath),
      'backdropPath': serializer.toJson<String?>(backdropPath),
      'logoPath': serializer.toJson<String?>(logoPath),
      'voteAverage': serializer.toJson<double?>(voteAverage),
      'bangumiScore': serializer.toJson<double?>(bangumiScore),
      'folderTmdbHint': serializer.toJson<int?>(folderTmdbHint),
      'isManualLocked': serializer.toJson<bool>(isManualLocked),
      'metadataLocked': serializer.toJson<bool>(metadataLocked),
      'posterLocked': serializer.toJson<bool>(posterLocked),
      'backdropLocked': serializer.toJson<bool>(backdropLocked),
      'logoLocked': serializer.toJson<bool>(logoLocked),
      'logoNegativeUntil': serializer.toJson<DateTime?>(logoNegativeUntil),
      'logoNegativeMask': serializer.toJson<int>(logoNegativeMask),
      'isHidden': serializer.toJson<bool>(isHidden),
      'keepHidden': serializer.toJson<bool>(keepHidden),
      'scrapeStatus': serializer.toJson<String>(
        $WorksTable.$converterscrapeStatus.toJson(scrapeStatus),
      ),
      'reviewReason': serializer.toJson<String?>(reviewReason),
      'seriesId': serializer.toJson<String?>(seriesId),
      'seriesOrder': serializer.toJson<int?>(seriesOrder),
      'seriesLabel': serializer.toJson<String?>(seriesLabel),
      'seriesLocked': serializer.toJson<bool>(seriesLocked),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
    };
  }

  WorkRow copyWith({
    String? id,
    Value<int?> tmdbId = const Value.absent(),
    Value<int?> bangumiId = const Value.absent(),
    Value<int?> tvdbId = const Value.absent(),
    Value<TmdbMediaType?> tmdbMediaType = const Value.absent(),
    Value<int?> matchedSeason = const Value.absent(),
    String? title,
    Value<String?> originalTitle = const Value.absent(),
    Value<int?> year = const Value.absent(),
    Value<String?> overview = const Value.absent(),
    Value<String?> posterPath = const Value.absent(),
    Value<String?> posterFallback = const Value.absent(),
    Value<String?> bangumiPosterPath = const Value.absent(),
    Value<String?> backdropPath = const Value.absent(),
    Value<String?> logoPath = const Value.absent(),
    Value<double?> voteAverage = const Value.absent(),
    Value<double?> bangumiScore = const Value.absent(),
    Value<int?> folderTmdbHint = const Value.absent(),
    bool? isManualLocked,
    bool? metadataLocked,
    bool? posterLocked,
    bool? backdropLocked,
    bool? logoLocked,
    Value<DateTime?> logoNegativeUntil = const Value.absent(),
    int? logoNegativeMask,
    bool? isHidden,
    bool? keepHidden,
    ScrapeStatus? scrapeStatus,
    Value<String?> reviewReason = const Value.absent(),
    Value<String?> seriesId = const Value.absent(),
    Value<int?> seriesOrder = const Value.absent(),
    Value<String?> seriesLabel = const Value.absent(),
    bool? seriesLocked,
    int? updatedAtMs,
  }) => WorkRow(
    id: id ?? this.id,
    tmdbId: tmdbId.present ? tmdbId.value : this.tmdbId,
    bangumiId: bangumiId.present ? bangumiId.value : this.bangumiId,
    tvdbId: tvdbId.present ? tvdbId.value : this.tvdbId,
    tmdbMediaType: tmdbMediaType.present
        ? tmdbMediaType.value
        : this.tmdbMediaType,
    matchedSeason: matchedSeason.present
        ? matchedSeason.value
        : this.matchedSeason,
    title: title ?? this.title,
    originalTitle: originalTitle.present
        ? originalTitle.value
        : this.originalTitle,
    year: year.present ? year.value : this.year,
    overview: overview.present ? overview.value : this.overview,
    posterPath: posterPath.present ? posterPath.value : this.posterPath,
    posterFallback: posterFallback.present
        ? posterFallback.value
        : this.posterFallback,
    bangumiPosterPath: bangumiPosterPath.present
        ? bangumiPosterPath.value
        : this.bangumiPosterPath,
    backdropPath: backdropPath.present ? backdropPath.value : this.backdropPath,
    logoPath: logoPath.present ? logoPath.value : this.logoPath,
    voteAverage: voteAverage.present ? voteAverage.value : this.voteAverage,
    bangumiScore: bangumiScore.present ? bangumiScore.value : this.bangumiScore,
    folderTmdbHint: folderTmdbHint.present
        ? folderTmdbHint.value
        : this.folderTmdbHint,
    isManualLocked: isManualLocked ?? this.isManualLocked,
    metadataLocked: metadataLocked ?? this.metadataLocked,
    posterLocked: posterLocked ?? this.posterLocked,
    backdropLocked: backdropLocked ?? this.backdropLocked,
    logoLocked: logoLocked ?? this.logoLocked,
    logoNegativeUntil: logoNegativeUntil.present
        ? logoNegativeUntil.value
        : this.logoNegativeUntil,
    logoNegativeMask: logoNegativeMask ?? this.logoNegativeMask,
    isHidden: isHidden ?? this.isHidden,
    keepHidden: keepHidden ?? this.keepHidden,
    scrapeStatus: scrapeStatus ?? this.scrapeStatus,
    reviewReason: reviewReason.present ? reviewReason.value : this.reviewReason,
    seriesId: seriesId.present ? seriesId.value : this.seriesId,
    seriesOrder: seriesOrder.present ? seriesOrder.value : this.seriesOrder,
    seriesLabel: seriesLabel.present ? seriesLabel.value : this.seriesLabel,
    seriesLocked: seriesLocked ?? this.seriesLocked,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );
  WorkRow copyWithCompanion(WorksCompanion data) {
    return WorkRow(
      id: data.id.present ? data.id.value : this.id,
      tmdbId: data.tmdbId.present ? data.tmdbId.value : this.tmdbId,
      bangumiId: data.bangumiId.present ? data.bangumiId.value : this.bangumiId,
      tvdbId: data.tvdbId.present ? data.tvdbId.value : this.tvdbId,
      tmdbMediaType: data.tmdbMediaType.present
          ? data.tmdbMediaType.value
          : this.tmdbMediaType,
      matchedSeason: data.matchedSeason.present
          ? data.matchedSeason.value
          : this.matchedSeason,
      title: data.title.present ? data.title.value : this.title,
      originalTitle: data.originalTitle.present
          ? data.originalTitle.value
          : this.originalTitle,
      year: data.year.present ? data.year.value : this.year,
      overview: data.overview.present ? data.overview.value : this.overview,
      posterPath: data.posterPath.present
          ? data.posterPath.value
          : this.posterPath,
      posterFallback: data.posterFallback.present
          ? data.posterFallback.value
          : this.posterFallback,
      bangumiPosterPath: data.bangumiPosterPath.present
          ? data.bangumiPosterPath.value
          : this.bangumiPosterPath,
      backdropPath: data.backdropPath.present
          ? data.backdropPath.value
          : this.backdropPath,
      logoPath: data.logoPath.present ? data.logoPath.value : this.logoPath,
      voteAverage: data.voteAverage.present
          ? data.voteAverage.value
          : this.voteAverage,
      bangumiScore: data.bangumiScore.present
          ? data.bangumiScore.value
          : this.bangumiScore,
      folderTmdbHint: data.folderTmdbHint.present
          ? data.folderTmdbHint.value
          : this.folderTmdbHint,
      isManualLocked: data.isManualLocked.present
          ? data.isManualLocked.value
          : this.isManualLocked,
      metadataLocked: data.metadataLocked.present
          ? data.metadataLocked.value
          : this.metadataLocked,
      posterLocked: data.posterLocked.present
          ? data.posterLocked.value
          : this.posterLocked,
      backdropLocked: data.backdropLocked.present
          ? data.backdropLocked.value
          : this.backdropLocked,
      logoLocked: data.logoLocked.present
          ? data.logoLocked.value
          : this.logoLocked,
      logoNegativeUntil: data.logoNegativeUntil.present
          ? data.logoNegativeUntil.value
          : this.logoNegativeUntil,
      logoNegativeMask: data.logoNegativeMask.present
          ? data.logoNegativeMask.value
          : this.logoNegativeMask,
      isHidden: data.isHidden.present ? data.isHidden.value : this.isHidden,
      keepHidden: data.keepHidden.present
          ? data.keepHidden.value
          : this.keepHidden,
      scrapeStatus: data.scrapeStatus.present
          ? data.scrapeStatus.value
          : this.scrapeStatus,
      reviewReason: data.reviewReason.present
          ? data.reviewReason.value
          : this.reviewReason,
      seriesId: data.seriesId.present ? data.seriesId.value : this.seriesId,
      seriesOrder: data.seriesOrder.present
          ? data.seriesOrder.value
          : this.seriesOrder,
      seriesLabel: data.seriesLabel.present
          ? data.seriesLabel.value
          : this.seriesLabel,
      seriesLocked: data.seriesLocked.present
          ? data.seriesLocked.value
          : this.seriesLocked,
      updatedAtMs: data.updatedAtMs.present
          ? data.updatedAtMs.value
          : this.updatedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('WorkRow(')
          ..write('id: $id, ')
          ..write('tmdbId: $tmdbId, ')
          ..write('bangumiId: $bangumiId, ')
          ..write('tvdbId: $tvdbId, ')
          ..write('tmdbMediaType: $tmdbMediaType, ')
          ..write('matchedSeason: $matchedSeason, ')
          ..write('title: $title, ')
          ..write('originalTitle: $originalTitle, ')
          ..write('year: $year, ')
          ..write('overview: $overview, ')
          ..write('posterPath: $posterPath, ')
          ..write('posterFallback: $posterFallback, ')
          ..write('bangumiPosterPath: $bangumiPosterPath, ')
          ..write('backdropPath: $backdropPath, ')
          ..write('logoPath: $logoPath, ')
          ..write('voteAverage: $voteAverage, ')
          ..write('bangumiScore: $bangumiScore, ')
          ..write('folderTmdbHint: $folderTmdbHint, ')
          ..write('isManualLocked: $isManualLocked, ')
          ..write('metadataLocked: $metadataLocked, ')
          ..write('posterLocked: $posterLocked, ')
          ..write('backdropLocked: $backdropLocked, ')
          ..write('logoLocked: $logoLocked, ')
          ..write('logoNegativeUntil: $logoNegativeUntil, ')
          ..write('logoNegativeMask: $logoNegativeMask, ')
          ..write('isHidden: $isHidden, ')
          ..write('keepHidden: $keepHidden, ')
          ..write('scrapeStatus: $scrapeStatus, ')
          ..write('reviewReason: $reviewReason, ')
          ..write('seriesId: $seriesId, ')
          ..write('seriesOrder: $seriesOrder, ')
          ..write('seriesLabel: $seriesLabel, ')
          ..write('seriesLocked: $seriesLocked, ')
          ..write('updatedAtMs: $updatedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    tmdbId,
    bangumiId,
    tvdbId,
    tmdbMediaType,
    matchedSeason,
    title,
    originalTitle,
    year,
    overview,
    posterPath,
    posterFallback,
    bangumiPosterPath,
    backdropPath,
    logoPath,
    voteAverage,
    bangumiScore,
    folderTmdbHint,
    isManualLocked,
    metadataLocked,
    posterLocked,
    backdropLocked,
    logoLocked,
    logoNegativeUntil,
    logoNegativeMask,
    isHidden,
    keepHidden,
    scrapeStatus,
    reviewReason,
    seriesId,
    seriesOrder,
    seriesLabel,
    seriesLocked,
    updatedAtMs,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WorkRow &&
          other.id == this.id &&
          other.tmdbId == this.tmdbId &&
          other.bangumiId == this.bangumiId &&
          other.tvdbId == this.tvdbId &&
          other.tmdbMediaType == this.tmdbMediaType &&
          other.matchedSeason == this.matchedSeason &&
          other.title == this.title &&
          other.originalTitle == this.originalTitle &&
          other.year == this.year &&
          other.overview == this.overview &&
          other.posterPath == this.posterPath &&
          other.posterFallback == this.posterFallback &&
          other.bangumiPosterPath == this.bangumiPosterPath &&
          other.backdropPath == this.backdropPath &&
          other.logoPath == this.logoPath &&
          other.voteAverage == this.voteAverage &&
          other.bangumiScore == this.bangumiScore &&
          other.folderTmdbHint == this.folderTmdbHint &&
          other.isManualLocked == this.isManualLocked &&
          other.metadataLocked == this.metadataLocked &&
          other.posterLocked == this.posterLocked &&
          other.backdropLocked == this.backdropLocked &&
          other.logoLocked == this.logoLocked &&
          other.logoNegativeUntil == this.logoNegativeUntil &&
          other.logoNegativeMask == this.logoNegativeMask &&
          other.isHidden == this.isHidden &&
          other.keepHidden == this.keepHidden &&
          other.scrapeStatus == this.scrapeStatus &&
          other.reviewReason == this.reviewReason &&
          other.seriesId == this.seriesId &&
          other.seriesOrder == this.seriesOrder &&
          other.seriesLabel == this.seriesLabel &&
          other.seriesLocked == this.seriesLocked &&
          other.updatedAtMs == this.updatedAtMs);
}

class WorksCompanion extends UpdateCompanion<WorkRow> {
  final Value<String> id;
  final Value<int?> tmdbId;
  final Value<int?> bangumiId;
  final Value<int?> tvdbId;
  final Value<TmdbMediaType?> tmdbMediaType;
  final Value<int?> matchedSeason;
  final Value<String> title;
  final Value<String?> originalTitle;
  final Value<int?> year;
  final Value<String?> overview;
  final Value<String?> posterPath;
  final Value<String?> posterFallback;
  final Value<String?> bangumiPosterPath;
  final Value<String?> backdropPath;
  final Value<String?> logoPath;
  final Value<double?> voteAverage;
  final Value<double?> bangumiScore;
  final Value<int?> folderTmdbHint;
  final Value<bool> isManualLocked;
  final Value<bool> metadataLocked;
  final Value<bool> posterLocked;
  final Value<bool> backdropLocked;
  final Value<bool> logoLocked;
  final Value<DateTime?> logoNegativeUntil;
  final Value<int> logoNegativeMask;
  final Value<bool> isHidden;
  final Value<bool> keepHidden;
  final Value<ScrapeStatus> scrapeStatus;
  final Value<String?> reviewReason;
  final Value<String?> seriesId;
  final Value<int?> seriesOrder;
  final Value<String?> seriesLabel;
  final Value<bool> seriesLocked;
  final Value<int> updatedAtMs;
  final Value<int> rowid;
  const WorksCompanion({
    this.id = const Value.absent(),
    this.tmdbId = const Value.absent(),
    this.bangumiId = const Value.absent(),
    this.tvdbId = const Value.absent(),
    this.tmdbMediaType = const Value.absent(),
    this.matchedSeason = const Value.absent(),
    this.title = const Value.absent(),
    this.originalTitle = const Value.absent(),
    this.year = const Value.absent(),
    this.overview = const Value.absent(),
    this.posterPath = const Value.absent(),
    this.posterFallback = const Value.absent(),
    this.bangumiPosterPath = const Value.absent(),
    this.backdropPath = const Value.absent(),
    this.logoPath = const Value.absent(),
    this.voteAverage = const Value.absent(),
    this.bangumiScore = const Value.absent(),
    this.folderTmdbHint = const Value.absent(),
    this.isManualLocked = const Value.absent(),
    this.metadataLocked = const Value.absent(),
    this.posterLocked = const Value.absent(),
    this.backdropLocked = const Value.absent(),
    this.logoLocked = const Value.absent(),
    this.logoNegativeUntil = const Value.absent(),
    this.logoNegativeMask = const Value.absent(),
    this.isHidden = const Value.absent(),
    this.keepHidden = const Value.absent(),
    this.scrapeStatus = const Value.absent(),
    this.reviewReason = const Value.absent(),
    this.seriesId = const Value.absent(),
    this.seriesOrder = const Value.absent(),
    this.seriesLabel = const Value.absent(),
    this.seriesLocked = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  WorksCompanion.insert({
    required String id,
    this.tmdbId = const Value.absent(),
    this.bangumiId = const Value.absent(),
    this.tvdbId = const Value.absent(),
    this.tmdbMediaType = const Value.absent(),
    this.matchedSeason = const Value.absent(),
    required String title,
    this.originalTitle = const Value.absent(),
    this.year = const Value.absent(),
    this.overview = const Value.absent(),
    this.posterPath = const Value.absent(),
    this.posterFallback = const Value.absent(),
    this.bangumiPosterPath = const Value.absent(),
    this.backdropPath = const Value.absent(),
    this.logoPath = const Value.absent(),
    this.voteAverage = const Value.absent(),
    this.bangumiScore = const Value.absent(),
    this.folderTmdbHint = const Value.absent(),
    this.isManualLocked = const Value.absent(),
    this.metadataLocked = const Value.absent(),
    this.posterLocked = const Value.absent(),
    this.backdropLocked = const Value.absent(),
    this.logoLocked = const Value.absent(),
    this.logoNegativeUntil = const Value.absent(),
    this.logoNegativeMask = const Value.absent(),
    this.isHidden = const Value.absent(),
    this.keepHidden = const Value.absent(),
    required ScrapeStatus scrapeStatus,
    this.reviewReason = const Value.absent(),
    this.seriesId = const Value.absent(),
    this.seriesOrder = const Value.absent(),
    this.seriesLabel = const Value.absent(),
    this.seriesLocked = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       scrapeStatus = Value(scrapeStatus);
  static Insertable<WorkRow> custom({
    Expression<String>? id,
    Expression<int>? tmdbId,
    Expression<int>? bangumiId,
    Expression<int>? tvdbId,
    Expression<String>? tmdbMediaType,
    Expression<int>? matchedSeason,
    Expression<String>? title,
    Expression<String>? originalTitle,
    Expression<int>? year,
    Expression<String>? overview,
    Expression<String>? posterPath,
    Expression<String>? posterFallback,
    Expression<String>? bangumiPosterPath,
    Expression<String>? backdropPath,
    Expression<String>? logoPath,
    Expression<double>? voteAverage,
    Expression<double>? bangumiScore,
    Expression<int>? folderTmdbHint,
    Expression<bool>? isManualLocked,
    Expression<bool>? metadataLocked,
    Expression<bool>? posterLocked,
    Expression<bool>? backdropLocked,
    Expression<bool>? logoLocked,
    Expression<DateTime>? logoNegativeUntil,
    Expression<int>? logoNegativeMask,
    Expression<bool>? isHidden,
    Expression<bool>? keepHidden,
    Expression<String>? scrapeStatus,
    Expression<String>? reviewReason,
    Expression<String>? seriesId,
    Expression<int>? seriesOrder,
    Expression<String>? seriesLabel,
    Expression<bool>? seriesLocked,
    Expression<int>? updatedAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (tmdbId != null) 'tmdb_id': tmdbId,
      if (bangumiId != null) 'bangumi_id': bangumiId,
      if (tvdbId != null) 'tvdb_id': tvdbId,
      if (tmdbMediaType != null) 'tmdb_media_type': tmdbMediaType,
      if (matchedSeason != null) 'matched_season': matchedSeason,
      if (title != null) 'title': title,
      if (originalTitle != null) 'original_title': originalTitle,
      if (year != null) 'year': year,
      if (overview != null) 'overview': overview,
      if (posterPath != null) 'poster_path': posterPath,
      if (posterFallback != null) 'poster_fallback': posterFallback,
      if (bangumiPosterPath != null) 'bangumi_poster_path': bangumiPosterPath,
      if (backdropPath != null) 'backdrop_path': backdropPath,
      if (logoPath != null) 'logo_path': logoPath,
      if (voteAverage != null) 'vote_average': voteAverage,
      if (bangumiScore != null) 'bangumi_score': bangumiScore,
      if (folderTmdbHint != null) 'folder_tmdb_hint': folderTmdbHint,
      if (isManualLocked != null) 'is_manual_locked': isManualLocked,
      if (metadataLocked != null) 'metadata_locked': metadataLocked,
      if (posterLocked != null) 'poster_locked': posterLocked,
      if (backdropLocked != null) 'backdrop_locked': backdropLocked,
      if (logoLocked != null) 'logo_locked': logoLocked,
      if (logoNegativeUntil != null) 'logo_negative_until': logoNegativeUntil,
      if (logoNegativeMask != null) 'logo_negative_mask': logoNegativeMask,
      if (isHidden != null) 'is_hidden': isHidden,
      if (keepHidden != null) 'keep_hidden': keepHidden,
      if (scrapeStatus != null) 'scrape_status': scrapeStatus,
      if (reviewReason != null) 'review_reason': reviewReason,
      if (seriesId != null) 'series_id': seriesId,
      if (seriesOrder != null) 'series_order': seriesOrder,
      if (seriesLabel != null) 'series_label': seriesLabel,
      if (seriesLocked != null) 'series_locked': seriesLocked,
      if (updatedAtMs != null) 'updated_at_ms': updatedAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  WorksCompanion copyWith({
    Value<String>? id,
    Value<int?>? tmdbId,
    Value<int?>? bangumiId,
    Value<int?>? tvdbId,
    Value<TmdbMediaType?>? tmdbMediaType,
    Value<int?>? matchedSeason,
    Value<String>? title,
    Value<String?>? originalTitle,
    Value<int?>? year,
    Value<String?>? overview,
    Value<String?>? posterPath,
    Value<String?>? posterFallback,
    Value<String?>? bangumiPosterPath,
    Value<String?>? backdropPath,
    Value<String?>? logoPath,
    Value<double?>? voteAverage,
    Value<double?>? bangumiScore,
    Value<int?>? folderTmdbHint,
    Value<bool>? isManualLocked,
    Value<bool>? metadataLocked,
    Value<bool>? posterLocked,
    Value<bool>? backdropLocked,
    Value<bool>? logoLocked,
    Value<DateTime?>? logoNegativeUntil,
    Value<int>? logoNegativeMask,
    Value<bool>? isHidden,
    Value<bool>? keepHidden,
    Value<ScrapeStatus>? scrapeStatus,
    Value<String?>? reviewReason,
    Value<String?>? seriesId,
    Value<int?>? seriesOrder,
    Value<String?>? seriesLabel,
    Value<bool>? seriesLocked,
    Value<int>? updatedAtMs,
    Value<int>? rowid,
  }) {
    return WorksCompanion(
      id: id ?? this.id,
      tmdbId: tmdbId ?? this.tmdbId,
      bangumiId: bangumiId ?? this.bangumiId,
      tvdbId: tvdbId ?? this.tvdbId,
      tmdbMediaType: tmdbMediaType ?? this.tmdbMediaType,
      matchedSeason: matchedSeason ?? this.matchedSeason,
      title: title ?? this.title,
      originalTitle: originalTitle ?? this.originalTitle,
      year: year ?? this.year,
      overview: overview ?? this.overview,
      posterPath: posterPath ?? this.posterPath,
      posterFallback: posterFallback ?? this.posterFallback,
      bangumiPosterPath: bangumiPosterPath ?? this.bangumiPosterPath,
      backdropPath: backdropPath ?? this.backdropPath,
      logoPath: logoPath ?? this.logoPath,
      voteAverage: voteAverage ?? this.voteAverage,
      bangumiScore: bangumiScore ?? this.bangumiScore,
      folderTmdbHint: folderTmdbHint ?? this.folderTmdbHint,
      isManualLocked: isManualLocked ?? this.isManualLocked,
      metadataLocked: metadataLocked ?? this.metadataLocked,
      posterLocked: posterLocked ?? this.posterLocked,
      backdropLocked: backdropLocked ?? this.backdropLocked,
      logoLocked: logoLocked ?? this.logoLocked,
      logoNegativeUntil: logoNegativeUntil ?? this.logoNegativeUntil,
      logoNegativeMask: logoNegativeMask ?? this.logoNegativeMask,
      isHidden: isHidden ?? this.isHidden,
      keepHidden: keepHidden ?? this.keepHidden,
      scrapeStatus: scrapeStatus ?? this.scrapeStatus,
      reviewReason: reviewReason ?? this.reviewReason,
      seriesId: seriesId ?? this.seriesId,
      seriesOrder: seriesOrder ?? this.seriesOrder,
      seriesLabel: seriesLabel ?? this.seriesLabel,
      seriesLocked: seriesLocked ?? this.seriesLocked,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (tmdbId.present) {
      map['tmdb_id'] = Variable<int>(tmdbId.value);
    }
    if (bangumiId.present) {
      map['bangumi_id'] = Variable<int>(bangumiId.value);
    }
    if (tvdbId.present) {
      map['tvdb_id'] = Variable<int>(tvdbId.value);
    }
    if (tmdbMediaType.present) {
      map['tmdb_media_type'] = Variable<String>(
        $WorksTable.$convertertmdbMediaTypen.toSql(tmdbMediaType.value),
      );
    }
    if (matchedSeason.present) {
      map['matched_season'] = Variable<int>(matchedSeason.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (originalTitle.present) {
      map['original_title'] = Variable<String>(originalTitle.value);
    }
    if (year.present) {
      map['year'] = Variable<int>(year.value);
    }
    if (overview.present) {
      map['overview'] = Variable<String>(overview.value);
    }
    if (posterPath.present) {
      map['poster_path'] = Variable<String>(posterPath.value);
    }
    if (posterFallback.present) {
      map['poster_fallback'] = Variable<String>(posterFallback.value);
    }
    if (bangumiPosterPath.present) {
      map['bangumi_poster_path'] = Variable<String>(bangumiPosterPath.value);
    }
    if (backdropPath.present) {
      map['backdrop_path'] = Variable<String>(backdropPath.value);
    }
    if (logoPath.present) {
      map['logo_path'] = Variable<String>(logoPath.value);
    }
    if (voteAverage.present) {
      map['vote_average'] = Variable<double>(voteAverage.value);
    }
    if (bangumiScore.present) {
      map['bangumi_score'] = Variable<double>(bangumiScore.value);
    }
    if (folderTmdbHint.present) {
      map['folder_tmdb_hint'] = Variable<int>(folderTmdbHint.value);
    }
    if (isManualLocked.present) {
      map['is_manual_locked'] = Variable<bool>(isManualLocked.value);
    }
    if (metadataLocked.present) {
      map['metadata_locked'] = Variable<bool>(metadataLocked.value);
    }
    if (posterLocked.present) {
      map['poster_locked'] = Variable<bool>(posterLocked.value);
    }
    if (backdropLocked.present) {
      map['backdrop_locked'] = Variable<bool>(backdropLocked.value);
    }
    if (logoLocked.present) {
      map['logo_locked'] = Variable<bool>(logoLocked.value);
    }
    if (logoNegativeUntil.present) {
      map['logo_negative_until'] = Variable<DateTime>(logoNegativeUntil.value);
    }
    if (logoNegativeMask.present) {
      map['logo_negative_mask'] = Variable<int>(logoNegativeMask.value);
    }
    if (isHidden.present) {
      map['is_hidden'] = Variable<bool>(isHidden.value);
    }
    if (keepHidden.present) {
      map['keep_hidden'] = Variable<bool>(keepHidden.value);
    }
    if (scrapeStatus.present) {
      map['scrape_status'] = Variable<String>(
        $WorksTable.$converterscrapeStatus.toSql(scrapeStatus.value),
      );
    }
    if (reviewReason.present) {
      map['review_reason'] = Variable<String>(reviewReason.value);
    }
    if (seriesId.present) {
      map['series_id'] = Variable<String>(seriesId.value);
    }
    if (seriesOrder.present) {
      map['series_order'] = Variable<int>(seriesOrder.value);
    }
    if (seriesLabel.present) {
      map['series_label'] = Variable<String>(seriesLabel.value);
    }
    if (seriesLocked.present) {
      map['series_locked'] = Variable<bool>(seriesLocked.value);
    }
    if (updatedAtMs.present) {
      map['updated_at_ms'] = Variable<int>(updatedAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WorksCompanion(')
          ..write('id: $id, ')
          ..write('tmdbId: $tmdbId, ')
          ..write('bangumiId: $bangumiId, ')
          ..write('tvdbId: $tvdbId, ')
          ..write('tmdbMediaType: $tmdbMediaType, ')
          ..write('matchedSeason: $matchedSeason, ')
          ..write('title: $title, ')
          ..write('originalTitle: $originalTitle, ')
          ..write('year: $year, ')
          ..write('overview: $overview, ')
          ..write('posterPath: $posterPath, ')
          ..write('posterFallback: $posterFallback, ')
          ..write('bangumiPosterPath: $bangumiPosterPath, ')
          ..write('backdropPath: $backdropPath, ')
          ..write('logoPath: $logoPath, ')
          ..write('voteAverage: $voteAverage, ')
          ..write('bangumiScore: $bangumiScore, ')
          ..write('folderTmdbHint: $folderTmdbHint, ')
          ..write('isManualLocked: $isManualLocked, ')
          ..write('metadataLocked: $metadataLocked, ')
          ..write('posterLocked: $posterLocked, ')
          ..write('backdropLocked: $backdropLocked, ')
          ..write('logoLocked: $logoLocked, ')
          ..write('logoNegativeUntil: $logoNegativeUntil, ')
          ..write('logoNegativeMask: $logoNegativeMask, ')
          ..write('isHidden: $isHidden, ')
          ..write('keepHidden: $keepHidden, ')
          ..write('scrapeStatus: $scrapeStatus, ')
          ..write('reviewReason: $reviewReason, ')
          ..write('seriesId: $seriesId, ')
          ..write('seriesOrder: $seriesOrder, ')
          ..write('seriesLabel: $seriesLabel, ')
          ..write('seriesLocked: $seriesLocked, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $EpisodesTable extends Episodes
    with TableInfo<$EpisodesTable, EpisodeRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EpisodesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _workIdMeta = const VerificationMeta('workId');
  @override
  late final GeneratedColumn<String> workId = GeneratedColumn<String>(
    'work_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES works (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _seasonNumberMeta = const VerificationMeta(
    'seasonNumber',
  );
  @override
  late final GeneratedColumn<int> seasonNumber = GeneratedColumn<int>(
    'season_number',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _episodeNumberMeta = const VerificationMeta(
    'episodeNumber',
  );
  @override
  late final GeneratedColumn<int> episodeNumber = GeneratedColumn<int>(
    'episode_number',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _episodeNumberEndMeta = const VerificationMeta(
    'episodeNumberEnd',
  );
  @override
  late final GeneratedColumn<int> episodeNumberEnd = GeneratedColumn<int>(
    'episode_number_end',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<EpisodeCategory, String>
  category = GeneratedColumn<String>(
    'category',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  ).withConverter<EpisodeCategory>($EpisodesTable.$convertercategory);
  @override
  late final GeneratedColumnWithTypeConverter<ExtraKind?, String> extraType =
      GeneratedColumn<String>(
        'extra_type',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      ).withConverter<ExtraKind?>($EpisodesTable.$converterextraTypen);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _overviewMeta = const VerificationMeta(
    'overview',
  );
  @override
  late final GeneratedColumn<String> overview = GeneratedColumn<String>(
    'overview',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stillPathMeta = const VerificationMeta(
    'stillPath',
  );
  @override
  late final GeneratedColumn<String> stillPath = GeneratedColumn<String>(
    'still_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    workId,
    seasonNumber,
    episodeNumber,
    episodeNumberEnd,
    category,
    extraType,
    title,
    overview,
    stillPath,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'episodes';
  @override
  VerificationContext validateIntegrity(
    Insertable<EpisodeRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('work_id')) {
      context.handle(
        _workIdMeta,
        workId.isAcceptableOrUnknown(data['work_id']!, _workIdMeta),
      );
    } else if (isInserting) {
      context.missing(_workIdMeta);
    }
    if (data.containsKey('season_number')) {
      context.handle(
        _seasonNumberMeta,
        seasonNumber.isAcceptableOrUnknown(
          data['season_number']!,
          _seasonNumberMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_seasonNumberMeta);
    }
    if (data.containsKey('episode_number')) {
      context.handle(
        _episodeNumberMeta,
        episodeNumber.isAcceptableOrUnknown(
          data['episode_number']!,
          _episodeNumberMeta,
        ),
      );
    }
    if (data.containsKey('episode_number_end')) {
      context.handle(
        _episodeNumberEndMeta,
        episodeNumberEnd.isAcceptableOrUnknown(
          data['episode_number_end']!,
          _episodeNumberEndMeta,
        ),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('overview')) {
      context.handle(
        _overviewMeta,
        overview.isAcceptableOrUnknown(data['overview']!, _overviewMeta),
      );
    }
    if (data.containsKey('still_path')) {
      context.handle(
        _stillPathMeta,
        stillPath.isAcceptableOrUnknown(data['still_path']!, _stillPathMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  EpisodeRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EpisodeRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      workId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}work_id'],
      )!,
      seasonNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}season_number'],
      )!,
      episodeNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}episode_number'],
      ),
      episodeNumberEnd: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}episode_number_end'],
      ),
      category: $EpisodesTable.$convertercategory.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}category'],
        )!,
      ),
      extraType: $EpisodesTable.$converterextraTypen.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}extra_type'],
        ),
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      ),
      overview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}overview'],
      ),
      stillPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}still_path'],
      ),
    );
  }

  @override
  $EpisodesTable createAlias(String alias) {
    return $EpisodesTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<EpisodeCategory, String, String>
  $convertercategory = const EnumNameConverter<EpisodeCategory>(
    EpisodeCategory.values,
  );
  static JsonTypeConverter2<ExtraKind, String, String> $converterextraType =
      const EnumNameConverter<ExtraKind>(ExtraKind.values);
  static JsonTypeConverter2<ExtraKind?, String?, String?> $converterextraTypen =
      JsonTypeConverter2.asNullable($converterextraType);
}

class EpisodeRow extends DataClass implements Insertable<EpisodeRow> {
  /// 剧集主键。
  final String id;

  /// 所属作品 ID。
  final String workId;

  /// 季号（特典通常为 0）。
  final int seasonNumber;

  /// 集号或特典序号（未识别集号时保持 null，不强行兜底为 1）。
  final int? episodeNumber;

  /// 多集合并文件的区间结束集号（null 表示单集；仅正片使用）。
  final int? episodeNumberEnd;

  /// 分类（正片 / 特典）。
  final EpisodeCategory category;

  /// 特典细分类型。
  final ExtraKind? extraType;

  /// 单集标题。
  final String? title;

  /// 单集简介。
  final String? overview;

  /// 单集剧照路径。
  final String? stillPath;
  const EpisodeRow({
    required this.id,
    required this.workId,
    required this.seasonNumber,
    this.episodeNumber,
    this.episodeNumberEnd,
    required this.category,
    this.extraType,
    this.title,
    this.overview,
    this.stillPath,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['work_id'] = Variable<String>(workId);
    map['season_number'] = Variable<int>(seasonNumber);
    if (!nullToAbsent || episodeNumber != null) {
      map['episode_number'] = Variable<int>(episodeNumber);
    }
    if (!nullToAbsent || episodeNumberEnd != null) {
      map['episode_number_end'] = Variable<int>(episodeNumberEnd);
    }
    {
      map['category'] = Variable<String>(
        $EpisodesTable.$convertercategory.toSql(category),
      );
    }
    if (!nullToAbsent || extraType != null) {
      map['extra_type'] = Variable<String>(
        $EpisodesTable.$converterextraTypen.toSql(extraType),
      );
    }
    if (!nullToAbsent || title != null) {
      map['title'] = Variable<String>(title);
    }
    if (!nullToAbsent || overview != null) {
      map['overview'] = Variable<String>(overview);
    }
    if (!nullToAbsent || stillPath != null) {
      map['still_path'] = Variable<String>(stillPath);
    }
    return map;
  }

  EpisodesCompanion toCompanion(bool nullToAbsent) {
    return EpisodesCompanion(
      id: Value(id),
      workId: Value(workId),
      seasonNumber: Value(seasonNumber),
      episodeNumber: episodeNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(episodeNumber),
      episodeNumberEnd: episodeNumberEnd == null && nullToAbsent
          ? const Value.absent()
          : Value(episodeNumberEnd),
      category: Value(category),
      extraType: extraType == null && nullToAbsent
          ? const Value.absent()
          : Value(extraType),
      title: title == null && nullToAbsent
          ? const Value.absent()
          : Value(title),
      overview: overview == null && nullToAbsent
          ? const Value.absent()
          : Value(overview),
      stillPath: stillPath == null && nullToAbsent
          ? const Value.absent()
          : Value(stillPath),
    );
  }

  factory EpisodeRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EpisodeRow(
      id: serializer.fromJson<String>(json['id']),
      workId: serializer.fromJson<String>(json['workId']),
      seasonNumber: serializer.fromJson<int>(json['seasonNumber']),
      episodeNumber: serializer.fromJson<int?>(json['episodeNumber']),
      episodeNumberEnd: serializer.fromJson<int?>(json['episodeNumberEnd']),
      category: $EpisodesTable.$convertercategory.fromJson(
        serializer.fromJson<String>(json['category']),
      ),
      extraType: $EpisodesTable.$converterextraTypen.fromJson(
        serializer.fromJson<String?>(json['extraType']),
      ),
      title: serializer.fromJson<String?>(json['title']),
      overview: serializer.fromJson<String?>(json['overview']),
      stillPath: serializer.fromJson<String?>(json['stillPath']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'workId': serializer.toJson<String>(workId),
      'seasonNumber': serializer.toJson<int>(seasonNumber),
      'episodeNumber': serializer.toJson<int?>(episodeNumber),
      'episodeNumberEnd': serializer.toJson<int?>(episodeNumberEnd),
      'category': serializer.toJson<String>(
        $EpisodesTable.$convertercategory.toJson(category),
      ),
      'extraType': serializer.toJson<String?>(
        $EpisodesTable.$converterextraTypen.toJson(extraType),
      ),
      'title': serializer.toJson<String?>(title),
      'overview': serializer.toJson<String?>(overview),
      'stillPath': serializer.toJson<String?>(stillPath),
    };
  }

  EpisodeRow copyWith({
    String? id,
    String? workId,
    int? seasonNumber,
    Value<int?> episodeNumber = const Value.absent(),
    Value<int?> episodeNumberEnd = const Value.absent(),
    EpisodeCategory? category,
    Value<ExtraKind?> extraType = const Value.absent(),
    Value<String?> title = const Value.absent(),
    Value<String?> overview = const Value.absent(),
    Value<String?> stillPath = const Value.absent(),
  }) => EpisodeRow(
    id: id ?? this.id,
    workId: workId ?? this.workId,
    seasonNumber: seasonNumber ?? this.seasonNumber,
    episodeNumber: episodeNumber.present
        ? episodeNumber.value
        : this.episodeNumber,
    episodeNumberEnd: episodeNumberEnd.present
        ? episodeNumberEnd.value
        : this.episodeNumberEnd,
    category: category ?? this.category,
    extraType: extraType.present ? extraType.value : this.extraType,
    title: title.present ? title.value : this.title,
    overview: overview.present ? overview.value : this.overview,
    stillPath: stillPath.present ? stillPath.value : this.stillPath,
  );
  EpisodeRow copyWithCompanion(EpisodesCompanion data) {
    return EpisodeRow(
      id: data.id.present ? data.id.value : this.id,
      workId: data.workId.present ? data.workId.value : this.workId,
      seasonNumber: data.seasonNumber.present
          ? data.seasonNumber.value
          : this.seasonNumber,
      episodeNumber: data.episodeNumber.present
          ? data.episodeNumber.value
          : this.episodeNumber,
      episodeNumberEnd: data.episodeNumberEnd.present
          ? data.episodeNumberEnd.value
          : this.episodeNumberEnd,
      category: data.category.present ? data.category.value : this.category,
      extraType: data.extraType.present ? data.extraType.value : this.extraType,
      title: data.title.present ? data.title.value : this.title,
      overview: data.overview.present ? data.overview.value : this.overview,
      stillPath: data.stillPath.present ? data.stillPath.value : this.stillPath,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EpisodeRow(')
          ..write('id: $id, ')
          ..write('workId: $workId, ')
          ..write('seasonNumber: $seasonNumber, ')
          ..write('episodeNumber: $episodeNumber, ')
          ..write('episodeNumberEnd: $episodeNumberEnd, ')
          ..write('category: $category, ')
          ..write('extraType: $extraType, ')
          ..write('title: $title, ')
          ..write('overview: $overview, ')
          ..write('stillPath: $stillPath')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    workId,
    seasonNumber,
    episodeNumber,
    episodeNumberEnd,
    category,
    extraType,
    title,
    overview,
    stillPath,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EpisodeRow &&
          other.id == this.id &&
          other.workId == this.workId &&
          other.seasonNumber == this.seasonNumber &&
          other.episodeNumber == this.episodeNumber &&
          other.episodeNumberEnd == this.episodeNumberEnd &&
          other.category == this.category &&
          other.extraType == this.extraType &&
          other.title == this.title &&
          other.overview == this.overview &&
          other.stillPath == this.stillPath);
}

class EpisodesCompanion extends UpdateCompanion<EpisodeRow> {
  final Value<String> id;
  final Value<String> workId;
  final Value<int> seasonNumber;
  final Value<int?> episodeNumber;
  final Value<int?> episodeNumberEnd;
  final Value<EpisodeCategory> category;
  final Value<ExtraKind?> extraType;
  final Value<String?> title;
  final Value<String?> overview;
  final Value<String?> stillPath;
  final Value<int> rowid;
  const EpisodesCompanion({
    this.id = const Value.absent(),
    this.workId = const Value.absent(),
    this.seasonNumber = const Value.absent(),
    this.episodeNumber = const Value.absent(),
    this.episodeNumberEnd = const Value.absent(),
    this.category = const Value.absent(),
    this.extraType = const Value.absent(),
    this.title = const Value.absent(),
    this.overview = const Value.absent(),
    this.stillPath = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EpisodesCompanion.insert({
    required String id,
    required String workId,
    required int seasonNumber,
    this.episodeNumber = const Value.absent(),
    this.episodeNumberEnd = const Value.absent(),
    required EpisodeCategory category,
    this.extraType = const Value.absent(),
    this.title = const Value.absent(),
    this.overview = const Value.absent(),
    this.stillPath = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       workId = Value(workId),
       seasonNumber = Value(seasonNumber),
       category = Value(category);
  static Insertable<EpisodeRow> custom({
    Expression<String>? id,
    Expression<String>? workId,
    Expression<int>? seasonNumber,
    Expression<int>? episodeNumber,
    Expression<int>? episodeNumberEnd,
    Expression<String>? category,
    Expression<String>? extraType,
    Expression<String>? title,
    Expression<String>? overview,
    Expression<String>? stillPath,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (workId != null) 'work_id': workId,
      if (seasonNumber != null) 'season_number': seasonNumber,
      if (episodeNumber != null) 'episode_number': episodeNumber,
      if (episodeNumberEnd != null) 'episode_number_end': episodeNumberEnd,
      if (category != null) 'category': category,
      if (extraType != null) 'extra_type': extraType,
      if (title != null) 'title': title,
      if (overview != null) 'overview': overview,
      if (stillPath != null) 'still_path': stillPath,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EpisodesCompanion copyWith({
    Value<String>? id,
    Value<String>? workId,
    Value<int>? seasonNumber,
    Value<int?>? episodeNumber,
    Value<int?>? episodeNumberEnd,
    Value<EpisodeCategory>? category,
    Value<ExtraKind?>? extraType,
    Value<String?>? title,
    Value<String?>? overview,
    Value<String?>? stillPath,
    Value<int>? rowid,
  }) {
    return EpisodesCompanion(
      id: id ?? this.id,
      workId: workId ?? this.workId,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      episodeNumberEnd: episodeNumberEnd ?? this.episodeNumberEnd,
      category: category ?? this.category,
      extraType: extraType ?? this.extraType,
      title: title ?? this.title,
      overview: overview ?? this.overview,
      stillPath: stillPath ?? this.stillPath,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (workId.present) {
      map['work_id'] = Variable<String>(workId.value);
    }
    if (seasonNumber.present) {
      map['season_number'] = Variable<int>(seasonNumber.value);
    }
    if (episodeNumber.present) {
      map['episode_number'] = Variable<int>(episodeNumber.value);
    }
    if (episodeNumberEnd.present) {
      map['episode_number_end'] = Variable<int>(episodeNumberEnd.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(
        $EpisodesTable.$convertercategory.toSql(category.value),
      );
    }
    if (extraType.present) {
      map['extra_type'] = Variable<String>(
        $EpisodesTable.$converterextraTypen.toSql(extraType.value),
      );
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (overview.present) {
      map['overview'] = Variable<String>(overview.value);
    }
    if (stillPath.present) {
      map['still_path'] = Variable<String>(stillPath.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EpisodesCompanion(')
          ..write('id: $id, ')
          ..write('workId: $workId, ')
          ..write('seasonNumber: $seasonNumber, ')
          ..write('episodeNumber: $episodeNumber, ')
          ..write('episodeNumberEnd: $episodeNumberEnd, ')
          ..write('category: $category, ')
          ..write('extraType: $extraType, ')
          ..write('title: $title, ')
          ..write('overview: $overview, ')
          ..write('stillPath: $stillPath, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MediaVariantsTable extends MediaVariants
    with TableInfo<$MediaVariantsTable, MediaVariantRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaVariantsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _workIdMeta = const VerificationMeta('workId');
  @override
  late final GeneratedColumn<String> workId = GeneratedColumn<String>(
    'work_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES works (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _episodeIdMeta = const VerificationMeta(
    'episodeId',
  );
  @override
  late final GeneratedColumn<String> episodeId = GeneratedColumn<String>(
    'episode_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES episodes (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES media_sources (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _relativePathMeta = const VerificationMeta(
    'relativePath',
  );
  @override
  late final GeneratedColumn<String> relativePath = GeneratedColumn<String>(
    'relative_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fileSizeMeta = const VerificationMeta(
    'fileSize',
  );
  @override
  late final GeneratedColumn<int> fileSize = GeneratedColumn<int>(
    'file_size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<AssetKind, String> assetKind =
      GeneratedColumn<String>(
        'asset_kind',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<AssetKind>($MediaVariantsTable.$converterassetKind);
  static const VerificationMeta _releaseGroupMeta = const VerificationMeta(
    'releaseGroup',
  );
  @override
  late final GeneratedColumn<String> releaseGroup = GeneratedColumn<String>(
    'release_group',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _subtitleGroupMeta = const VerificationMeta(
    'subtitleGroup',
  );
  @override
  late final GeneratedColumn<String> subtitleGroup = GeneratedColumn<String>(
    'subtitle_group',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _videoCodecMeta = const VerificationMeta(
    'videoCodec',
  );
  @override
  late final GeneratedColumn<String> videoCodec = GeneratedColumn<String>(
    'video_codec',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bitDepthMeta = const VerificationMeta(
    'bitDepth',
  );
  @override
  late final GeneratedColumn<String> bitDepth = GeneratedColumn<String>(
    'bit_depth',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _resolutionMeta = const VerificationMeta(
    'resolution',
  );
  @override
  late final GeneratedColumn<String> resolution = GeneratedColumn<String>(
    'resolution',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _audioCodecMeta = const VerificationMeta(
    'audioCodec',
  );
  @override
  late final GeneratedColumn<String> audioCodec = GeneratedColumn<String>(
    'audio_codec',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _externalSubtitlesJsonMeta =
      const VerificationMeta('externalSubtitlesJson');
  @override
  late final GeneratedColumn<String> externalSubtitlesJson =
      GeneratedColumn<String>(
        'external_subtitles_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('[]'),
      );
  static const VerificationMeta _mappingLockedMeta = const VerificationMeta(
    'mappingLocked',
  );
  @override
  late final GeneratedColumn<bool> mappingLocked = GeneratedColumn<bool>(
    'mapping_locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("mapping_locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _workLockedMeta = const VerificationMeta(
    'workLocked',
  );
  @override
  late final GeneratedColumn<bool> workLocked = GeneratedColumn<bool>(
    'work_locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("work_locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  late final GeneratedColumnWithTypeConverter<SupplementaryAssetScope, String>
  assetScope =
      GeneratedColumn<String>(
        'asset_scope',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: Constant(SupplementaryAssetScope.workExclusive.name),
      ).withConverter<SupplementaryAssetScope>(
        $MediaVariantsTable.$converterassetScope,
      );
  static const VerificationMeta _scopeLockedMeta = const VerificationMeta(
    'scopeLocked',
  );
  @override
  late final GeneratedColumn<bool> scopeLocked = GeneratedColumn<bool>(
    'scope_locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("scope_locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    workId,
    episodeId,
    sourceId,
    relativePath,
    fileName,
    fileSize,
    assetKind,
    releaseGroup,
    subtitleGroup,
    videoCodec,
    bitDepth,
    resolution,
    audioCodec,
    externalSubtitlesJson,
    mappingLocked,
    workLocked,
    assetScope,
    scopeLocked,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_variants';
  @override
  VerificationContext validateIntegrity(
    Insertable<MediaVariantRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('work_id')) {
      context.handle(
        _workIdMeta,
        workId.isAcceptableOrUnknown(data['work_id']!, _workIdMeta),
      );
    } else if (isInserting) {
      context.missing(_workIdMeta);
    }
    if (data.containsKey('episode_id')) {
      context.handle(
        _episodeIdMeta,
        episodeId.isAcceptableOrUnknown(data['episode_id']!, _episodeIdMeta),
      );
    }
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('relative_path')) {
      context.handle(
        _relativePathMeta,
        relativePath.isAcceptableOrUnknown(
          data['relative_path']!,
          _relativePathMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_relativePathMeta);
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    } else if (isInserting) {
      context.missing(_fileNameMeta);
    }
    if (data.containsKey('file_size')) {
      context.handle(
        _fileSizeMeta,
        fileSize.isAcceptableOrUnknown(data['file_size']!, _fileSizeMeta),
      );
    } else if (isInserting) {
      context.missing(_fileSizeMeta);
    }
    if (data.containsKey('release_group')) {
      context.handle(
        _releaseGroupMeta,
        releaseGroup.isAcceptableOrUnknown(
          data['release_group']!,
          _releaseGroupMeta,
        ),
      );
    }
    if (data.containsKey('subtitle_group')) {
      context.handle(
        _subtitleGroupMeta,
        subtitleGroup.isAcceptableOrUnknown(
          data['subtitle_group']!,
          _subtitleGroupMeta,
        ),
      );
    }
    if (data.containsKey('video_codec')) {
      context.handle(
        _videoCodecMeta,
        videoCodec.isAcceptableOrUnknown(data['video_codec']!, _videoCodecMeta),
      );
    }
    if (data.containsKey('bit_depth')) {
      context.handle(
        _bitDepthMeta,
        bitDepth.isAcceptableOrUnknown(data['bit_depth']!, _bitDepthMeta),
      );
    }
    if (data.containsKey('resolution')) {
      context.handle(
        _resolutionMeta,
        resolution.isAcceptableOrUnknown(data['resolution']!, _resolutionMeta),
      );
    }
    if (data.containsKey('audio_codec')) {
      context.handle(
        _audioCodecMeta,
        audioCodec.isAcceptableOrUnknown(data['audio_codec']!, _audioCodecMeta),
      );
    }
    if (data.containsKey('external_subtitles_json')) {
      context.handle(
        _externalSubtitlesJsonMeta,
        externalSubtitlesJson.isAcceptableOrUnknown(
          data['external_subtitles_json']!,
          _externalSubtitlesJsonMeta,
        ),
      );
    }
    if (data.containsKey('mapping_locked')) {
      context.handle(
        _mappingLockedMeta,
        mappingLocked.isAcceptableOrUnknown(
          data['mapping_locked']!,
          _mappingLockedMeta,
        ),
      );
    }
    if (data.containsKey('work_locked')) {
      context.handle(
        _workLockedMeta,
        workLocked.isAcceptableOrUnknown(data['work_locked']!, _workLockedMeta),
      );
    }
    if (data.containsKey('scope_locked')) {
      context.handle(
        _scopeLockedMeta,
        scopeLocked.isAcceptableOrUnknown(
          data['scope_locked']!,
          _scopeLockedMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MediaVariantRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaVariantRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      workId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}work_id'],
      )!,
      episodeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}episode_id'],
      ),
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      )!,
      relativePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}relative_path'],
      )!,
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      )!,
      fileSize: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}file_size'],
      )!,
      assetKind: $MediaVariantsTable.$converterassetKind.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}asset_kind'],
        )!,
      ),
      releaseGroup: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}release_group'],
      ),
      subtitleGroup: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}subtitle_group'],
      ),
      videoCodec: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}video_codec'],
      ),
      bitDepth: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bit_depth'],
      ),
      resolution: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resolution'],
      ),
      audioCodec: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}audio_codec'],
      ),
      externalSubtitlesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}external_subtitles_json'],
      )!,
      mappingLocked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}mapping_locked'],
      )!,
      workLocked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}work_locked'],
      )!,
      assetScope: $MediaVariantsTable.$converterassetScope.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}asset_scope'],
        )!,
      ),
      scopeLocked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}scope_locked'],
      )!,
    );
  }

  @override
  $MediaVariantsTable createAlias(String alias) {
    return $MediaVariantsTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<AssetKind, String, String> $converterassetKind =
      const EnumNameConverter<AssetKind>(AssetKind.values);
  static JsonTypeConverter2<SupplementaryAssetScope, String, String>
  $converterassetScope = const EnumNameConverter<SupplementaryAssetScope>(
    SupplementaryAssetScope.values,
  );
}

class MediaVariantRow extends DataClass implements Insertable<MediaVariantRow> {
  /// 物理版本主键。
  final String id;

  /// 所属作品 ID。
  final String workId;

  /// 关联的逻辑剧集 ID（可空）。
  final String? episodeId;

  /// 所属媒体源 ID。
  final String sourceId;

  /// 相对媒体源路径。
  final String relativePath;

  /// 文件名。
  final String fileName;

  /// 文件大小（字节）。
  final int fileSize;

  /// 资产分类（视频 / CD 专辑 / 扫图画廊）。
  final AssetKind assetKind;

  /// 压制组。
  final String? releaseGroup;

  /// 字幕组。
  final String? subtitleGroup;

  /// 视频编码。
  final String? videoCodec;

  /// 色深。
  final String? bitDepth;

  /// 分辨率。
  final String? resolution;

  /// 音频编码。
  final String? audioCodec;

  /// 外挂字幕相对路径列表 JSON。
  final String externalSubtitlesJson;

  /// 该文件映射槽位是否已人工锁定。
  final bool mappingLocked;

  /// 该物理文件的作品归属是否已人工锁定。
  final bool workLocked;

  /// 作为附属资源在系列内的可见作用域。
  final SupplementaryAssetScope assetScope;

  /// 该文件的系列作用域是否已人工锁定。
  final bool scopeLocked;
  const MediaVariantRow({
    required this.id,
    required this.workId,
    this.episodeId,
    required this.sourceId,
    required this.relativePath,
    required this.fileName,
    required this.fileSize,
    required this.assetKind,
    this.releaseGroup,
    this.subtitleGroup,
    this.videoCodec,
    this.bitDepth,
    this.resolution,
    this.audioCodec,
    required this.externalSubtitlesJson,
    required this.mappingLocked,
    required this.workLocked,
    required this.assetScope,
    required this.scopeLocked,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['work_id'] = Variable<String>(workId);
    if (!nullToAbsent || episodeId != null) {
      map['episode_id'] = Variable<String>(episodeId);
    }
    map['source_id'] = Variable<String>(sourceId);
    map['relative_path'] = Variable<String>(relativePath);
    map['file_name'] = Variable<String>(fileName);
    map['file_size'] = Variable<int>(fileSize);
    {
      map['asset_kind'] = Variable<String>(
        $MediaVariantsTable.$converterassetKind.toSql(assetKind),
      );
    }
    if (!nullToAbsent || releaseGroup != null) {
      map['release_group'] = Variable<String>(releaseGroup);
    }
    if (!nullToAbsent || subtitleGroup != null) {
      map['subtitle_group'] = Variable<String>(subtitleGroup);
    }
    if (!nullToAbsent || videoCodec != null) {
      map['video_codec'] = Variable<String>(videoCodec);
    }
    if (!nullToAbsent || bitDepth != null) {
      map['bit_depth'] = Variable<String>(bitDepth);
    }
    if (!nullToAbsent || resolution != null) {
      map['resolution'] = Variable<String>(resolution);
    }
    if (!nullToAbsent || audioCodec != null) {
      map['audio_codec'] = Variable<String>(audioCodec);
    }
    map['external_subtitles_json'] = Variable<String>(externalSubtitlesJson);
    map['mapping_locked'] = Variable<bool>(mappingLocked);
    map['work_locked'] = Variable<bool>(workLocked);
    {
      map['asset_scope'] = Variable<String>(
        $MediaVariantsTable.$converterassetScope.toSql(assetScope),
      );
    }
    map['scope_locked'] = Variable<bool>(scopeLocked);
    return map;
  }

  MediaVariantsCompanion toCompanion(bool nullToAbsent) {
    return MediaVariantsCompanion(
      id: Value(id),
      workId: Value(workId),
      episodeId: episodeId == null && nullToAbsent
          ? const Value.absent()
          : Value(episodeId),
      sourceId: Value(sourceId),
      relativePath: Value(relativePath),
      fileName: Value(fileName),
      fileSize: Value(fileSize),
      assetKind: Value(assetKind),
      releaseGroup: releaseGroup == null && nullToAbsent
          ? const Value.absent()
          : Value(releaseGroup),
      subtitleGroup: subtitleGroup == null && nullToAbsent
          ? const Value.absent()
          : Value(subtitleGroup),
      videoCodec: videoCodec == null && nullToAbsent
          ? const Value.absent()
          : Value(videoCodec),
      bitDepth: bitDepth == null && nullToAbsent
          ? const Value.absent()
          : Value(bitDepth),
      resolution: resolution == null && nullToAbsent
          ? const Value.absent()
          : Value(resolution),
      audioCodec: audioCodec == null && nullToAbsent
          ? const Value.absent()
          : Value(audioCodec),
      externalSubtitlesJson: Value(externalSubtitlesJson),
      mappingLocked: Value(mappingLocked),
      workLocked: Value(workLocked),
      assetScope: Value(assetScope),
      scopeLocked: Value(scopeLocked),
    );
  }

  factory MediaVariantRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaVariantRow(
      id: serializer.fromJson<String>(json['id']),
      workId: serializer.fromJson<String>(json['workId']),
      episodeId: serializer.fromJson<String?>(json['episodeId']),
      sourceId: serializer.fromJson<String>(json['sourceId']),
      relativePath: serializer.fromJson<String>(json['relativePath']),
      fileName: serializer.fromJson<String>(json['fileName']),
      fileSize: serializer.fromJson<int>(json['fileSize']),
      assetKind: $MediaVariantsTable.$converterassetKind.fromJson(
        serializer.fromJson<String>(json['assetKind']),
      ),
      releaseGroup: serializer.fromJson<String?>(json['releaseGroup']),
      subtitleGroup: serializer.fromJson<String?>(json['subtitleGroup']),
      videoCodec: serializer.fromJson<String?>(json['videoCodec']),
      bitDepth: serializer.fromJson<String?>(json['bitDepth']),
      resolution: serializer.fromJson<String?>(json['resolution']),
      audioCodec: serializer.fromJson<String?>(json['audioCodec']),
      externalSubtitlesJson: serializer.fromJson<String>(
        json['externalSubtitlesJson'],
      ),
      mappingLocked: serializer.fromJson<bool>(json['mappingLocked']),
      workLocked: serializer.fromJson<bool>(json['workLocked']),
      assetScope: $MediaVariantsTable.$converterassetScope.fromJson(
        serializer.fromJson<String>(json['assetScope']),
      ),
      scopeLocked: serializer.fromJson<bool>(json['scopeLocked']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'workId': serializer.toJson<String>(workId),
      'episodeId': serializer.toJson<String?>(episodeId),
      'sourceId': serializer.toJson<String>(sourceId),
      'relativePath': serializer.toJson<String>(relativePath),
      'fileName': serializer.toJson<String>(fileName),
      'fileSize': serializer.toJson<int>(fileSize),
      'assetKind': serializer.toJson<String>(
        $MediaVariantsTable.$converterassetKind.toJson(assetKind),
      ),
      'releaseGroup': serializer.toJson<String?>(releaseGroup),
      'subtitleGroup': serializer.toJson<String?>(subtitleGroup),
      'videoCodec': serializer.toJson<String?>(videoCodec),
      'bitDepth': serializer.toJson<String?>(bitDepth),
      'resolution': serializer.toJson<String?>(resolution),
      'audioCodec': serializer.toJson<String?>(audioCodec),
      'externalSubtitlesJson': serializer.toJson<String>(externalSubtitlesJson),
      'mappingLocked': serializer.toJson<bool>(mappingLocked),
      'workLocked': serializer.toJson<bool>(workLocked),
      'assetScope': serializer.toJson<String>(
        $MediaVariantsTable.$converterassetScope.toJson(assetScope),
      ),
      'scopeLocked': serializer.toJson<bool>(scopeLocked),
    };
  }

  MediaVariantRow copyWith({
    String? id,
    String? workId,
    Value<String?> episodeId = const Value.absent(),
    String? sourceId,
    String? relativePath,
    String? fileName,
    int? fileSize,
    AssetKind? assetKind,
    Value<String?> releaseGroup = const Value.absent(),
    Value<String?> subtitleGroup = const Value.absent(),
    Value<String?> videoCodec = const Value.absent(),
    Value<String?> bitDepth = const Value.absent(),
    Value<String?> resolution = const Value.absent(),
    Value<String?> audioCodec = const Value.absent(),
    String? externalSubtitlesJson,
    bool? mappingLocked,
    bool? workLocked,
    SupplementaryAssetScope? assetScope,
    bool? scopeLocked,
  }) => MediaVariantRow(
    id: id ?? this.id,
    workId: workId ?? this.workId,
    episodeId: episodeId.present ? episodeId.value : this.episodeId,
    sourceId: sourceId ?? this.sourceId,
    relativePath: relativePath ?? this.relativePath,
    fileName: fileName ?? this.fileName,
    fileSize: fileSize ?? this.fileSize,
    assetKind: assetKind ?? this.assetKind,
    releaseGroup: releaseGroup.present ? releaseGroup.value : this.releaseGroup,
    subtitleGroup: subtitleGroup.present
        ? subtitleGroup.value
        : this.subtitleGroup,
    videoCodec: videoCodec.present ? videoCodec.value : this.videoCodec,
    bitDepth: bitDepth.present ? bitDepth.value : this.bitDepth,
    resolution: resolution.present ? resolution.value : this.resolution,
    audioCodec: audioCodec.present ? audioCodec.value : this.audioCodec,
    externalSubtitlesJson: externalSubtitlesJson ?? this.externalSubtitlesJson,
    mappingLocked: mappingLocked ?? this.mappingLocked,
    workLocked: workLocked ?? this.workLocked,
    assetScope: assetScope ?? this.assetScope,
    scopeLocked: scopeLocked ?? this.scopeLocked,
  );
  MediaVariantRow copyWithCompanion(MediaVariantsCompanion data) {
    return MediaVariantRow(
      id: data.id.present ? data.id.value : this.id,
      workId: data.workId.present ? data.workId.value : this.workId,
      episodeId: data.episodeId.present ? data.episodeId.value : this.episodeId,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      relativePath: data.relativePath.present
          ? data.relativePath.value
          : this.relativePath,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      fileSize: data.fileSize.present ? data.fileSize.value : this.fileSize,
      assetKind: data.assetKind.present ? data.assetKind.value : this.assetKind,
      releaseGroup: data.releaseGroup.present
          ? data.releaseGroup.value
          : this.releaseGroup,
      subtitleGroup: data.subtitleGroup.present
          ? data.subtitleGroup.value
          : this.subtitleGroup,
      videoCodec: data.videoCodec.present
          ? data.videoCodec.value
          : this.videoCodec,
      bitDepth: data.bitDepth.present ? data.bitDepth.value : this.bitDepth,
      resolution: data.resolution.present
          ? data.resolution.value
          : this.resolution,
      audioCodec: data.audioCodec.present
          ? data.audioCodec.value
          : this.audioCodec,
      externalSubtitlesJson: data.externalSubtitlesJson.present
          ? data.externalSubtitlesJson.value
          : this.externalSubtitlesJson,
      mappingLocked: data.mappingLocked.present
          ? data.mappingLocked.value
          : this.mappingLocked,
      workLocked: data.workLocked.present
          ? data.workLocked.value
          : this.workLocked,
      assetScope: data.assetScope.present
          ? data.assetScope.value
          : this.assetScope,
      scopeLocked: data.scopeLocked.present
          ? data.scopeLocked.value
          : this.scopeLocked,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaVariantRow(')
          ..write('id: $id, ')
          ..write('workId: $workId, ')
          ..write('episodeId: $episodeId, ')
          ..write('sourceId: $sourceId, ')
          ..write('relativePath: $relativePath, ')
          ..write('fileName: $fileName, ')
          ..write('fileSize: $fileSize, ')
          ..write('assetKind: $assetKind, ')
          ..write('releaseGroup: $releaseGroup, ')
          ..write('subtitleGroup: $subtitleGroup, ')
          ..write('videoCodec: $videoCodec, ')
          ..write('bitDepth: $bitDepth, ')
          ..write('resolution: $resolution, ')
          ..write('audioCodec: $audioCodec, ')
          ..write('externalSubtitlesJson: $externalSubtitlesJson, ')
          ..write('mappingLocked: $mappingLocked, ')
          ..write('workLocked: $workLocked, ')
          ..write('assetScope: $assetScope, ')
          ..write('scopeLocked: $scopeLocked')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    workId,
    episodeId,
    sourceId,
    relativePath,
    fileName,
    fileSize,
    assetKind,
    releaseGroup,
    subtitleGroup,
    videoCodec,
    bitDepth,
    resolution,
    audioCodec,
    externalSubtitlesJson,
    mappingLocked,
    workLocked,
    assetScope,
    scopeLocked,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaVariantRow &&
          other.id == this.id &&
          other.workId == this.workId &&
          other.episodeId == this.episodeId &&
          other.sourceId == this.sourceId &&
          other.relativePath == this.relativePath &&
          other.fileName == this.fileName &&
          other.fileSize == this.fileSize &&
          other.assetKind == this.assetKind &&
          other.releaseGroup == this.releaseGroup &&
          other.subtitleGroup == this.subtitleGroup &&
          other.videoCodec == this.videoCodec &&
          other.bitDepth == this.bitDepth &&
          other.resolution == this.resolution &&
          other.audioCodec == this.audioCodec &&
          other.externalSubtitlesJson == this.externalSubtitlesJson &&
          other.mappingLocked == this.mappingLocked &&
          other.workLocked == this.workLocked &&
          other.assetScope == this.assetScope &&
          other.scopeLocked == this.scopeLocked);
}

class MediaVariantsCompanion extends UpdateCompanion<MediaVariantRow> {
  final Value<String> id;
  final Value<String> workId;
  final Value<String?> episodeId;
  final Value<String> sourceId;
  final Value<String> relativePath;
  final Value<String> fileName;
  final Value<int> fileSize;
  final Value<AssetKind> assetKind;
  final Value<String?> releaseGroup;
  final Value<String?> subtitleGroup;
  final Value<String?> videoCodec;
  final Value<String?> bitDepth;
  final Value<String?> resolution;
  final Value<String?> audioCodec;
  final Value<String> externalSubtitlesJson;
  final Value<bool> mappingLocked;
  final Value<bool> workLocked;
  final Value<SupplementaryAssetScope> assetScope;
  final Value<bool> scopeLocked;
  final Value<int> rowid;
  const MediaVariantsCompanion({
    this.id = const Value.absent(),
    this.workId = const Value.absent(),
    this.episodeId = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.relativePath = const Value.absent(),
    this.fileName = const Value.absent(),
    this.fileSize = const Value.absent(),
    this.assetKind = const Value.absent(),
    this.releaseGroup = const Value.absent(),
    this.subtitleGroup = const Value.absent(),
    this.videoCodec = const Value.absent(),
    this.bitDepth = const Value.absent(),
    this.resolution = const Value.absent(),
    this.audioCodec = const Value.absent(),
    this.externalSubtitlesJson = const Value.absent(),
    this.mappingLocked = const Value.absent(),
    this.workLocked = const Value.absent(),
    this.assetScope = const Value.absent(),
    this.scopeLocked = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MediaVariantsCompanion.insert({
    required String id,
    required String workId,
    this.episodeId = const Value.absent(),
    required String sourceId,
    required String relativePath,
    required String fileName,
    required int fileSize,
    required AssetKind assetKind,
    this.releaseGroup = const Value.absent(),
    this.subtitleGroup = const Value.absent(),
    this.videoCodec = const Value.absent(),
    this.bitDepth = const Value.absent(),
    this.resolution = const Value.absent(),
    this.audioCodec = const Value.absent(),
    this.externalSubtitlesJson = const Value.absent(),
    this.mappingLocked = const Value.absent(),
    this.workLocked = const Value.absent(),
    this.assetScope = const Value.absent(),
    this.scopeLocked = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       workId = Value(workId),
       sourceId = Value(sourceId),
       relativePath = Value(relativePath),
       fileName = Value(fileName),
       fileSize = Value(fileSize),
       assetKind = Value(assetKind);
  static Insertable<MediaVariantRow> custom({
    Expression<String>? id,
    Expression<String>? workId,
    Expression<String>? episodeId,
    Expression<String>? sourceId,
    Expression<String>? relativePath,
    Expression<String>? fileName,
    Expression<int>? fileSize,
    Expression<String>? assetKind,
    Expression<String>? releaseGroup,
    Expression<String>? subtitleGroup,
    Expression<String>? videoCodec,
    Expression<String>? bitDepth,
    Expression<String>? resolution,
    Expression<String>? audioCodec,
    Expression<String>? externalSubtitlesJson,
    Expression<bool>? mappingLocked,
    Expression<bool>? workLocked,
    Expression<String>? assetScope,
    Expression<bool>? scopeLocked,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (workId != null) 'work_id': workId,
      if (episodeId != null) 'episode_id': episodeId,
      if (sourceId != null) 'source_id': sourceId,
      if (relativePath != null) 'relative_path': relativePath,
      if (fileName != null) 'file_name': fileName,
      if (fileSize != null) 'file_size': fileSize,
      if (assetKind != null) 'asset_kind': assetKind,
      if (releaseGroup != null) 'release_group': releaseGroup,
      if (subtitleGroup != null) 'subtitle_group': subtitleGroup,
      if (videoCodec != null) 'video_codec': videoCodec,
      if (bitDepth != null) 'bit_depth': bitDepth,
      if (resolution != null) 'resolution': resolution,
      if (audioCodec != null) 'audio_codec': audioCodec,
      if (externalSubtitlesJson != null)
        'external_subtitles_json': externalSubtitlesJson,
      if (mappingLocked != null) 'mapping_locked': mappingLocked,
      if (workLocked != null) 'work_locked': workLocked,
      if (assetScope != null) 'asset_scope': assetScope,
      if (scopeLocked != null) 'scope_locked': scopeLocked,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MediaVariantsCompanion copyWith({
    Value<String>? id,
    Value<String>? workId,
    Value<String?>? episodeId,
    Value<String>? sourceId,
    Value<String>? relativePath,
    Value<String>? fileName,
    Value<int>? fileSize,
    Value<AssetKind>? assetKind,
    Value<String?>? releaseGroup,
    Value<String?>? subtitleGroup,
    Value<String?>? videoCodec,
    Value<String?>? bitDepth,
    Value<String?>? resolution,
    Value<String?>? audioCodec,
    Value<String>? externalSubtitlesJson,
    Value<bool>? mappingLocked,
    Value<bool>? workLocked,
    Value<SupplementaryAssetScope>? assetScope,
    Value<bool>? scopeLocked,
    Value<int>? rowid,
  }) {
    return MediaVariantsCompanion(
      id: id ?? this.id,
      workId: workId ?? this.workId,
      episodeId: episodeId ?? this.episodeId,
      sourceId: sourceId ?? this.sourceId,
      relativePath: relativePath ?? this.relativePath,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      assetKind: assetKind ?? this.assetKind,
      releaseGroup: releaseGroup ?? this.releaseGroup,
      subtitleGroup: subtitleGroup ?? this.subtitleGroup,
      videoCodec: videoCodec ?? this.videoCodec,
      bitDepth: bitDepth ?? this.bitDepth,
      resolution: resolution ?? this.resolution,
      audioCodec: audioCodec ?? this.audioCodec,
      externalSubtitlesJson:
          externalSubtitlesJson ?? this.externalSubtitlesJson,
      mappingLocked: mappingLocked ?? this.mappingLocked,
      workLocked: workLocked ?? this.workLocked,
      assetScope: assetScope ?? this.assetScope,
      scopeLocked: scopeLocked ?? this.scopeLocked,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (workId.present) {
      map['work_id'] = Variable<String>(workId.value);
    }
    if (episodeId.present) {
      map['episode_id'] = Variable<String>(episodeId.value);
    }
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (relativePath.present) {
      map['relative_path'] = Variable<String>(relativePath.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (fileSize.present) {
      map['file_size'] = Variable<int>(fileSize.value);
    }
    if (assetKind.present) {
      map['asset_kind'] = Variable<String>(
        $MediaVariantsTable.$converterassetKind.toSql(assetKind.value),
      );
    }
    if (releaseGroup.present) {
      map['release_group'] = Variable<String>(releaseGroup.value);
    }
    if (subtitleGroup.present) {
      map['subtitle_group'] = Variable<String>(subtitleGroup.value);
    }
    if (videoCodec.present) {
      map['video_codec'] = Variable<String>(videoCodec.value);
    }
    if (bitDepth.present) {
      map['bit_depth'] = Variable<String>(bitDepth.value);
    }
    if (resolution.present) {
      map['resolution'] = Variable<String>(resolution.value);
    }
    if (audioCodec.present) {
      map['audio_codec'] = Variable<String>(audioCodec.value);
    }
    if (externalSubtitlesJson.present) {
      map['external_subtitles_json'] = Variable<String>(
        externalSubtitlesJson.value,
      );
    }
    if (mappingLocked.present) {
      map['mapping_locked'] = Variable<bool>(mappingLocked.value);
    }
    if (workLocked.present) {
      map['work_locked'] = Variable<bool>(workLocked.value);
    }
    if (assetScope.present) {
      map['asset_scope'] = Variable<String>(
        $MediaVariantsTable.$converterassetScope.toSql(assetScope.value),
      );
    }
    if (scopeLocked.present) {
      map['scope_locked'] = Variable<bool>(scopeLocked.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MediaVariantsCompanion(')
          ..write('id: $id, ')
          ..write('workId: $workId, ')
          ..write('episodeId: $episodeId, ')
          ..write('sourceId: $sourceId, ')
          ..write('relativePath: $relativePath, ')
          ..write('fileName: $fileName, ')
          ..write('fileSize: $fileSize, ')
          ..write('assetKind: $assetKind, ')
          ..write('releaseGroup: $releaseGroup, ')
          ..write('subtitleGroup: $subtitleGroup, ')
          ..write('videoCodec: $videoCodec, ')
          ..write('bitDepth: $bitDepth, ')
          ..write('resolution: $resolution, ')
          ..write('audioCodec: $audioCodec, ')
          ..write('externalSubtitlesJson: $externalSubtitlesJson, ')
          ..write('mappingLocked: $mappingLocked, ')
          ..write('workLocked: $workLocked, ')
          ..write('assetScope: $assetScope, ')
          ..write('scopeLocked: $scopeLocked, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ScrapeCandidatesTable extends ScrapeCandidates
    with TableInfo<$ScrapeCandidatesTable, ScrapeCandidateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ScrapeCandidatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _workIdMeta = const VerificationMeta('workId');
  @override
  late final GeneratedColumn<String> workId = GeneratedColumn<String>(
    'work_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES works (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _rankMeta = const VerificationMeta('rank');
  @override
  late final GeneratedColumn<int> rank = GeneratedColumn<int>(
    'rank',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tmdbIdMeta = const VerificationMeta('tmdbId');
  @override
  late final GeneratedColumn<int> tmdbId = GeneratedColumn<int>(
    'tmdb_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<TmdbMediaType, String> mediaType =
      GeneratedColumn<String>(
        'media_type',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<TmdbMediaType>(
        $ScrapeCandidatesTable.$convertermediaType,
      );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _originalTitleMeta = const VerificationMeta(
    'originalTitle',
  );
  @override
  late final GeneratedColumn<String> originalTitle = GeneratedColumn<String>(
    'original_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _yearMeta = const VerificationMeta('year');
  @override
  late final GeneratedColumn<int> year = GeneratedColumn<int>(
    'year',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _posterPathMeta = const VerificationMeta(
    'posterPath',
  );
  @override
  late final GeneratedColumn<String> posterPath = GeneratedColumn<String>(
    'poster_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _scoreMeta = const VerificationMeta('score');
  @override
  late final GeneratedColumn<double> score = GeneratedColumn<double>(
    'score',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reasonsJsonMeta = const VerificationMeta(
    'reasonsJson',
  );
  @override
  late final GeneratedColumn<String> reasonsJson = GeneratedColumn<String>(
    'reasons_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _episodeCountMeta = const VerificationMeta(
    'episodeCount',
  );
  @override
  late final GeneratedColumn<int> episodeCount = GeneratedColumn<int>(
    'episode_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    workId,
    rank,
    tmdbId,
    mediaType,
    title,
    originalTitle,
    year,
    posterPath,
    score,
    reasonsJson,
    episodeCount,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'scrape_candidates';
  @override
  VerificationContext validateIntegrity(
    Insertable<ScrapeCandidateRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('work_id')) {
      context.handle(
        _workIdMeta,
        workId.isAcceptableOrUnknown(data['work_id']!, _workIdMeta),
      );
    } else if (isInserting) {
      context.missing(_workIdMeta);
    }
    if (data.containsKey('rank')) {
      context.handle(
        _rankMeta,
        rank.isAcceptableOrUnknown(data['rank']!, _rankMeta),
      );
    } else if (isInserting) {
      context.missing(_rankMeta);
    }
    if (data.containsKey('tmdb_id')) {
      context.handle(
        _tmdbIdMeta,
        tmdbId.isAcceptableOrUnknown(data['tmdb_id']!, _tmdbIdMeta),
      );
    } else if (isInserting) {
      context.missing(_tmdbIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('original_title')) {
      context.handle(
        _originalTitleMeta,
        originalTitle.isAcceptableOrUnknown(
          data['original_title']!,
          _originalTitleMeta,
        ),
      );
    }
    if (data.containsKey('year')) {
      context.handle(
        _yearMeta,
        year.isAcceptableOrUnknown(data['year']!, _yearMeta),
      );
    }
    if (data.containsKey('poster_path')) {
      context.handle(
        _posterPathMeta,
        posterPath.isAcceptableOrUnknown(data['poster_path']!, _posterPathMeta),
      );
    }
    if (data.containsKey('score')) {
      context.handle(
        _scoreMeta,
        score.isAcceptableOrUnknown(data['score']!, _scoreMeta),
      );
    } else if (isInserting) {
      context.missing(_scoreMeta);
    }
    if (data.containsKey('reasons_json')) {
      context.handle(
        _reasonsJsonMeta,
        reasonsJson.isAcceptableOrUnknown(
          data['reasons_json']!,
          _reasonsJsonMeta,
        ),
      );
    }
    if (data.containsKey('episode_count')) {
      context.handle(
        _episodeCountMeta,
        episodeCount.isAcceptableOrUnknown(
          data['episode_count']!,
          _episodeCountMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {workId, rank};
  @override
  ScrapeCandidateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ScrapeCandidateRow(
      workId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}work_id'],
      )!,
      rank: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}rank'],
      )!,
      tmdbId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tmdb_id'],
      )!,
      mediaType: $ScrapeCandidatesTable.$convertermediaType.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}media_type'],
        )!,
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      originalTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}original_title'],
      ),
      year: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}year'],
      ),
      posterPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}poster_path'],
      ),
      score: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}score'],
      )!,
      reasonsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reasons_json'],
      )!,
      episodeCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}episode_count'],
      ),
    );
  }

  @override
  $ScrapeCandidatesTable createAlias(String alias) {
    return $ScrapeCandidatesTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<TmdbMediaType, String, String> $convertermediaType =
      const EnumNameConverter<TmdbMediaType>(TmdbMediaType.values);
}

class ScrapeCandidateRow extends DataClass
    implements Insertable<ScrapeCandidateRow> {
  /// 所属作品 ID。
  final String workId;

  /// 候选排名（1..5）。
  final int rank;

  /// 候选 TMDB ID。
  final int tmdbId;

  /// 候选媒体类型。
  final TmdbMediaType mediaType;

  /// 候选标题。
  final String title;

  /// 候选原始标题。
  final String? originalTitle;

  /// 候选发行年份。
  final int? year;

  /// 海报路径。
  final String? posterPath;

  /// 匹配得分。
  final double score;

  /// 原因码列表 JSON。
  final String reasonsJson;

  /// 候选总集数。
  final int? episodeCount;
  const ScrapeCandidateRow({
    required this.workId,
    required this.rank,
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    this.originalTitle,
    this.year,
    this.posterPath,
    required this.score,
    required this.reasonsJson,
    this.episodeCount,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['work_id'] = Variable<String>(workId);
    map['rank'] = Variable<int>(rank);
    map['tmdb_id'] = Variable<int>(tmdbId);
    {
      map['media_type'] = Variable<String>(
        $ScrapeCandidatesTable.$convertermediaType.toSql(mediaType),
      );
    }
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || originalTitle != null) {
      map['original_title'] = Variable<String>(originalTitle);
    }
    if (!nullToAbsent || year != null) {
      map['year'] = Variable<int>(year);
    }
    if (!nullToAbsent || posterPath != null) {
      map['poster_path'] = Variable<String>(posterPath);
    }
    map['score'] = Variable<double>(score);
    map['reasons_json'] = Variable<String>(reasonsJson);
    if (!nullToAbsent || episodeCount != null) {
      map['episode_count'] = Variable<int>(episodeCount);
    }
    return map;
  }

  ScrapeCandidatesCompanion toCompanion(bool nullToAbsent) {
    return ScrapeCandidatesCompanion(
      workId: Value(workId),
      rank: Value(rank),
      tmdbId: Value(tmdbId),
      mediaType: Value(mediaType),
      title: Value(title),
      originalTitle: originalTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(originalTitle),
      year: year == null && nullToAbsent ? const Value.absent() : Value(year),
      posterPath: posterPath == null && nullToAbsent
          ? const Value.absent()
          : Value(posterPath),
      score: Value(score),
      reasonsJson: Value(reasonsJson),
      episodeCount: episodeCount == null && nullToAbsent
          ? const Value.absent()
          : Value(episodeCount),
    );
  }

  factory ScrapeCandidateRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ScrapeCandidateRow(
      workId: serializer.fromJson<String>(json['workId']),
      rank: serializer.fromJson<int>(json['rank']),
      tmdbId: serializer.fromJson<int>(json['tmdbId']),
      mediaType: $ScrapeCandidatesTable.$convertermediaType.fromJson(
        serializer.fromJson<String>(json['mediaType']),
      ),
      title: serializer.fromJson<String>(json['title']),
      originalTitle: serializer.fromJson<String?>(json['originalTitle']),
      year: serializer.fromJson<int?>(json['year']),
      posterPath: serializer.fromJson<String?>(json['posterPath']),
      score: serializer.fromJson<double>(json['score']),
      reasonsJson: serializer.fromJson<String>(json['reasonsJson']),
      episodeCount: serializer.fromJson<int?>(json['episodeCount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'workId': serializer.toJson<String>(workId),
      'rank': serializer.toJson<int>(rank),
      'tmdbId': serializer.toJson<int>(tmdbId),
      'mediaType': serializer.toJson<String>(
        $ScrapeCandidatesTable.$convertermediaType.toJson(mediaType),
      ),
      'title': serializer.toJson<String>(title),
      'originalTitle': serializer.toJson<String?>(originalTitle),
      'year': serializer.toJson<int?>(year),
      'posterPath': serializer.toJson<String?>(posterPath),
      'score': serializer.toJson<double>(score),
      'reasonsJson': serializer.toJson<String>(reasonsJson),
      'episodeCount': serializer.toJson<int?>(episodeCount),
    };
  }

  ScrapeCandidateRow copyWith({
    String? workId,
    int? rank,
    int? tmdbId,
    TmdbMediaType? mediaType,
    String? title,
    Value<String?> originalTitle = const Value.absent(),
    Value<int?> year = const Value.absent(),
    Value<String?> posterPath = const Value.absent(),
    double? score,
    String? reasonsJson,
    Value<int?> episodeCount = const Value.absent(),
  }) => ScrapeCandidateRow(
    workId: workId ?? this.workId,
    rank: rank ?? this.rank,
    tmdbId: tmdbId ?? this.tmdbId,
    mediaType: mediaType ?? this.mediaType,
    title: title ?? this.title,
    originalTitle: originalTitle.present
        ? originalTitle.value
        : this.originalTitle,
    year: year.present ? year.value : this.year,
    posterPath: posterPath.present ? posterPath.value : this.posterPath,
    score: score ?? this.score,
    reasonsJson: reasonsJson ?? this.reasonsJson,
    episodeCount: episodeCount.present ? episodeCount.value : this.episodeCount,
  );
  ScrapeCandidateRow copyWithCompanion(ScrapeCandidatesCompanion data) {
    return ScrapeCandidateRow(
      workId: data.workId.present ? data.workId.value : this.workId,
      rank: data.rank.present ? data.rank.value : this.rank,
      tmdbId: data.tmdbId.present ? data.tmdbId.value : this.tmdbId,
      mediaType: data.mediaType.present ? data.mediaType.value : this.mediaType,
      title: data.title.present ? data.title.value : this.title,
      originalTitle: data.originalTitle.present
          ? data.originalTitle.value
          : this.originalTitle,
      year: data.year.present ? data.year.value : this.year,
      posterPath: data.posterPath.present
          ? data.posterPath.value
          : this.posterPath,
      score: data.score.present ? data.score.value : this.score,
      reasonsJson: data.reasonsJson.present
          ? data.reasonsJson.value
          : this.reasonsJson,
      episodeCount: data.episodeCount.present
          ? data.episodeCount.value
          : this.episodeCount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ScrapeCandidateRow(')
          ..write('workId: $workId, ')
          ..write('rank: $rank, ')
          ..write('tmdbId: $tmdbId, ')
          ..write('mediaType: $mediaType, ')
          ..write('title: $title, ')
          ..write('originalTitle: $originalTitle, ')
          ..write('year: $year, ')
          ..write('posterPath: $posterPath, ')
          ..write('score: $score, ')
          ..write('reasonsJson: $reasonsJson, ')
          ..write('episodeCount: $episodeCount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    workId,
    rank,
    tmdbId,
    mediaType,
    title,
    originalTitle,
    year,
    posterPath,
    score,
    reasonsJson,
    episodeCount,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScrapeCandidateRow &&
          other.workId == this.workId &&
          other.rank == this.rank &&
          other.tmdbId == this.tmdbId &&
          other.mediaType == this.mediaType &&
          other.title == this.title &&
          other.originalTitle == this.originalTitle &&
          other.year == this.year &&
          other.posterPath == this.posterPath &&
          other.score == this.score &&
          other.reasonsJson == this.reasonsJson &&
          other.episodeCount == this.episodeCount);
}

class ScrapeCandidatesCompanion extends UpdateCompanion<ScrapeCandidateRow> {
  final Value<String> workId;
  final Value<int> rank;
  final Value<int> tmdbId;
  final Value<TmdbMediaType> mediaType;
  final Value<String> title;
  final Value<String?> originalTitle;
  final Value<int?> year;
  final Value<String?> posterPath;
  final Value<double> score;
  final Value<String> reasonsJson;
  final Value<int?> episodeCount;
  final Value<int> rowid;
  const ScrapeCandidatesCompanion({
    this.workId = const Value.absent(),
    this.rank = const Value.absent(),
    this.tmdbId = const Value.absent(),
    this.mediaType = const Value.absent(),
    this.title = const Value.absent(),
    this.originalTitle = const Value.absent(),
    this.year = const Value.absent(),
    this.posterPath = const Value.absent(),
    this.score = const Value.absent(),
    this.reasonsJson = const Value.absent(),
    this.episodeCount = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ScrapeCandidatesCompanion.insert({
    required String workId,
    required int rank,
    required int tmdbId,
    required TmdbMediaType mediaType,
    required String title,
    this.originalTitle = const Value.absent(),
    this.year = const Value.absent(),
    this.posterPath = const Value.absent(),
    required double score,
    this.reasonsJson = const Value.absent(),
    this.episodeCount = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : workId = Value(workId),
       rank = Value(rank),
       tmdbId = Value(tmdbId),
       mediaType = Value(mediaType),
       title = Value(title),
       score = Value(score);
  static Insertable<ScrapeCandidateRow> custom({
    Expression<String>? workId,
    Expression<int>? rank,
    Expression<int>? tmdbId,
    Expression<String>? mediaType,
    Expression<String>? title,
    Expression<String>? originalTitle,
    Expression<int>? year,
    Expression<String>? posterPath,
    Expression<double>? score,
    Expression<String>? reasonsJson,
    Expression<int>? episodeCount,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (workId != null) 'work_id': workId,
      if (rank != null) 'rank': rank,
      if (tmdbId != null) 'tmdb_id': tmdbId,
      if (mediaType != null) 'media_type': mediaType,
      if (title != null) 'title': title,
      if (originalTitle != null) 'original_title': originalTitle,
      if (year != null) 'year': year,
      if (posterPath != null) 'poster_path': posterPath,
      if (score != null) 'score': score,
      if (reasonsJson != null) 'reasons_json': reasonsJson,
      if (episodeCount != null) 'episode_count': episodeCount,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ScrapeCandidatesCompanion copyWith({
    Value<String>? workId,
    Value<int>? rank,
    Value<int>? tmdbId,
    Value<TmdbMediaType>? mediaType,
    Value<String>? title,
    Value<String?>? originalTitle,
    Value<int?>? year,
    Value<String?>? posterPath,
    Value<double>? score,
    Value<String>? reasonsJson,
    Value<int?>? episodeCount,
    Value<int>? rowid,
  }) {
    return ScrapeCandidatesCompanion(
      workId: workId ?? this.workId,
      rank: rank ?? this.rank,
      tmdbId: tmdbId ?? this.tmdbId,
      mediaType: mediaType ?? this.mediaType,
      title: title ?? this.title,
      originalTitle: originalTitle ?? this.originalTitle,
      year: year ?? this.year,
      posterPath: posterPath ?? this.posterPath,
      score: score ?? this.score,
      reasonsJson: reasonsJson ?? this.reasonsJson,
      episodeCount: episodeCount ?? this.episodeCount,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (workId.present) {
      map['work_id'] = Variable<String>(workId.value);
    }
    if (rank.present) {
      map['rank'] = Variable<int>(rank.value);
    }
    if (tmdbId.present) {
      map['tmdb_id'] = Variable<int>(tmdbId.value);
    }
    if (mediaType.present) {
      map['media_type'] = Variable<String>(
        $ScrapeCandidatesTable.$convertermediaType.toSql(mediaType.value),
      );
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (originalTitle.present) {
      map['original_title'] = Variable<String>(originalTitle.value);
    }
    if (year.present) {
      map['year'] = Variable<int>(year.value);
    }
    if (posterPath.present) {
      map['poster_path'] = Variable<String>(posterPath.value);
    }
    if (score.present) {
      map['score'] = Variable<double>(score.value);
    }
    if (reasonsJson.present) {
      map['reasons_json'] = Variable<String>(reasonsJson.value);
    }
    if (episodeCount.present) {
      map['episode_count'] = Variable<int>(episodeCount.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ScrapeCandidatesCompanion(')
          ..write('workId: $workId, ')
          ..write('rank: $rank, ')
          ..write('tmdbId: $tmdbId, ')
          ..write('mediaType: $mediaType, ')
          ..write('title: $title, ')
          ..write('originalTitle: $originalTitle, ')
          ..write('year: $year, ')
          ..write('posterPath: $posterPath, ')
          ..write('score: $score, ')
          ..write('reasonsJson: $reasonsJson, ')
          ..write('episodeCount: $episodeCount, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlaybackRecordsTable extends PlaybackRecords
    with TableInfo<$PlaybackRecordsTable, PlaybackRecordRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlaybackRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _workIdMeta = const VerificationMeta('workId');
  @override
  late final GeneratedColumn<String> workId = GeneratedColumn<String>(
    'work_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES works (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _episodeIdMeta = const VerificationMeta(
    'episodeId',
  );
  @override
  late final GeneratedColumn<String> episodeId = GeneratedColumn<String>(
    'episode_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _variantIdMeta = const VerificationMeta(
    'variantId',
  );
  @override
  late final GeneratedColumn<String> variantId = GeneratedColumn<String>(
    'variant_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seasonNumberMeta = const VerificationMeta(
    'seasonNumber',
  );
  @override
  late final GeneratedColumn<int> seasonNumber = GeneratedColumn<int>(
    'season_number',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _episodeNumberMeta = const VerificationMeta(
    'episodeNumber',
  );
  @override
  late final GeneratedColumn<int> episodeNumber = GeneratedColumn<int>(
    'episode_number',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _episodeTitleMeta = const VerificationMeta(
    'episodeTitle',
  );
  @override
  late final GeneratedColumn<String> episodeTitle = GeneratedColumn<String>(
    'episode_title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<MediaSourceKind, String>
  sourceType = GeneratedColumn<String>(
    'source_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  ).withConverter<MediaSourceKind>($PlaybackRecordsTable.$convertersourceType);
  static const VerificationMeta _playedAtMeta = const VerificationMeta(
    'playedAt',
  );
  @override
  late final GeneratedColumn<DateTime> playedAt = GeneratedColumn<DateTime>(
    'played_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionSecondsMeta = const VerificationMeta(
    'positionSeconds',
  );
  @override
  late final GeneratedColumn<int> positionSeconds = GeneratedColumn<int>(
    'position_seconds',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _durationSecondsMeta = const VerificationMeta(
    'durationSeconds',
  );
  @override
  late final GeneratedColumn<int> durationSeconds = GeneratedColumn<int>(
    'duration_seconds',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isCompletedMeta = const VerificationMeta(
    'isCompleted',
  );
  @override
  late final GeneratedColumn<bool> isCompleted = GeneratedColumn<bool>(
    'is_completed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_completed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _updatedAtMsMeta = const VerificationMeta(
    'updatedAtMs',
  );
  @override
  late final GeneratedColumn<int> updatedAtMs = GeneratedColumn<int>(
    'updated_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    workId,
    episodeId,
    variantId,
    seasonNumber,
    episodeNumber,
    episodeTitle,
    sourceType,
    playedAt,
    positionSeconds,
    durationSeconds,
    isCompleted,
    updatedAtMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playback_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlaybackRecordRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('work_id')) {
      context.handle(
        _workIdMeta,
        workId.isAcceptableOrUnknown(data['work_id']!, _workIdMeta),
      );
    } else if (isInserting) {
      context.missing(_workIdMeta);
    }
    if (data.containsKey('episode_id')) {
      context.handle(
        _episodeIdMeta,
        episodeId.isAcceptableOrUnknown(data['episode_id']!, _episodeIdMeta),
      );
    } else if (isInserting) {
      context.missing(_episodeIdMeta);
    }
    if (data.containsKey('variant_id')) {
      context.handle(
        _variantIdMeta,
        variantId.isAcceptableOrUnknown(data['variant_id']!, _variantIdMeta),
      );
    } else if (isInserting) {
      context.missing(_variantIdMeta);
    }
    if (data.containsKey('season_number')) {
      context.handle(
        _seasonNumberMeta,
        seasonNumber.isAcceptableOrUnknown(
          data['season_number']!,
          _seasonNumberMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_seasonNumberMeta);
    }
    if (data.containsKey('episode_number')) {
      context.handle(
        _episodeNumberMeta,
        episodeNumber.isAcceptableOrUnknown(
          data['episode_number']!,
          _episodeNumberMeta,
        ),
      );
    }
    if (data.containsKey('episode_title')) {
      context.handle(
        _episodeTitleMeta,
        episodeTitle.isAcceptableOrUnknown(
          data['episode_title']!,
          _episodeTitleMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_episodeTitleMeta);
    }
    if (data.containsKey('played_at')) {
      context.handle(
        _playedAtMeta,
        playedAt.isAcceptableOrUnknown(data['played_at']!, _playedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_playedAtMeta);
    }
    if (data.containsKey('position_seconds')) {
      context.handle(
        _positionSecondsMeta,
        positionSeconds.isAcceptableOrUnknown(
          data['position_seconds']!,
          _positionSecondsMeta,
        ),
      );
    }
    if (data.containsKey('duration_seconds')) {
      context.handle(
        _durationSecondsMeta,
        durationSeconds.isAcceptableOrUnknown(
          data['duration_seconds']!,
          _durationSecondsMeta,
        ),
      );
    }
    if (data.containsKey('is_completed')) {
      context.handle(
        _isCompletedMeta,
        isCompleted.isAcceptableOrUnknown(
          data['is_completed']!,
          _isCompletedMeta,
        ),
      );
    }
    if (data.containsKey('updated_at_ms')) {
      context.handle(
        _updatedAtMsMeta,
        updatedAtMs.isAcceptableOrUnknown(
          data['updated_at_ms']!,
          _updatedAtMsMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlaybackRecordRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlaybackRecordRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      workId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}work_id'],
      )!,
      episodeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}episode_id'],
      )!,
      variantId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}variant_id'],
      )!,
      seasonNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}season_number'],
      )!,
      episodeNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}episode_number'],
      ),
      episodeTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}episode_title'],
      )!,
      sourceType: $PlaybackRecordsTable.$convertersourceType.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}source_type'],
        )!,
      ),
      playedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}played_at'],
      )!,
      positionSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position_seconds'],
      )!,
      durationSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_seconds'],
      )!,
      isCompleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_completed'],
      )!,
      updatedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_ms'],
      )!,
    );
  }

  @override
  $PlaybackRecordsTable createAlias(String alias) {
    return $PlaybackRecordsTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<MediaSourceKind, String, String>
  $convertersourceType = const EnumNameConverter<MediaSourceKind>(
    MediaSourceKind.values,
  );
}

class PlaybackRecordRow extends DataClass
    implements Insertable<PlaybackRecordRow> {
  /// 记录唯一主键（UUID）。
  final String id;

  /// 所属作品 ID。
  final String workId;

  /// 所属逻辑剧集 ID。
  final String episodeId;

  /// 实际播放的物理版本 ID。
  final String variantId;

  /// 季号。
  final int seasonNumber;

  /// 集号（未识别集号的单集作品保持 null）。
  final int? episodeNumber;

  /// 单集展示标题。
  final String episodeTitle;

  /// 媒体源协议类型。
  final MediaSourceKind sourceType;

  /// 播放时间戳。
  final DateTime playedAt;

  /// 当前播放位置（秒）。
  final int positionSeconds;

  /// 视频总时长（秒）。
  final int durationSeconds;

  /// 是否已看完（自动阈值或手动标记）。
  final bool isCompleted;

  /// 最近一次进度变更的 UTC 毫秒时间戳（供多设备冲突合并判定新旧）。
  final int updatedAtMs;
  const PlaybackRecordRow({
    required this.id,
    required this.workId,
    required this.episodeId,
    required this.variantId,
    required this.seasonNumber,
    this.episodeNumber,
    required this.episodeTitle,
    required this.sourceType,
    required this.playedAt,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.isCompleted,
    required this.updatedAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['work_id'] = Variable<String>(workId);
    map['episode_id'] = Variable<String>(episodeId);
    map['variant_id'] = Variable<String>(variantId);
    map['season_number'] = Variable<int>(seasonNumber);
    if (!nullToAbsent || episodeNumber != null) {
      map['episode_number'] = Variable<int>(episodeNumber);
    }
    map['episode_title'] = Variable<String>(episodeTitle);
    {
      map['source_type'] = Variable<String>(
        $PlaybackRecordsTable.$convertersourceType.toSql(sourceType),
      );
    }
    map['played_at'] = Variable<DateTime>(playedAt);
    map['position_seconds'] = Variable<int>(positionSeconds);
    map['duration_seconds'] = Variable<int>(durationSeconds);
    map['is_completed'] = Variable<bool>(isCompleted);
    map['updated_at_ms'] = Variable<int>(updatedAtMs);
    return map;
  }

  PlaybackRecordsCompanion toCompanion(bool nullToAbsent) {
    return PlaybackRecordsCompanion(
      id: Value(id),
      workId: Value(workId),
      episodeId: Value(episodeId),
      variantId: Value(variantId),
      seasonNumber: Value(seasonNumber),
      episodeNumber: episodeNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(episodeNumber),
      episodeTitle: Value(episodeTitle),
      sourceType: Value(sourceType),
      playedAt: Value(playedAt),
      positionSeconds: Value(positionSeconds),
      durationSeconds: Value(durationSeconds),
      isCompleted: Value(isCompleted),
      updatedAtMs: Value(updatedAtMs),
    );
  }

  factory PlaybackRecordRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlaybackRecordRow(
      id: serializer.fromJson<String>(json['id']),
      workId: serializer.fromJson<String>(json['workId']),
      episodeId: serializer.fromJson<String>(json['episodeId']),
      variantId: serializer.fromJson<String>(json['variantId']),
      seasonNumber: serializer.fromJson<int>(json['seasonNumber']),
      episodeNumber: serializer.fromJson<int?>(json['episodeNumber']),
      episodeTitle: serializer.fromJson<String>(json['episodeTitle']),
      sourceType: $PlaybackRecordsTable.$convertersourceType.fromJson(
        serializer.fromJson<String>(json['sourceType']),
      ),
      playedAt: serializer.fromJson<DateTime>(json['playedAt']),
      positionSeconds: serializer.fromJson<int>(json['positionSeconds']),
      durationSeconds: serializer.fromJson<int>(json['durationSeconds']),
      isCompleted: serializer.fromJson<bool>(json['isCompleted']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'workId': serializer.toJson<String>(workId),
      'episodeId': serializer.toJson<String>(episodeId),
      'variantId': serializer.toJson<String>(variantId),
      'seasonNumber': serializer.toJson<int>(seasonNumber),
      'episodeNumber': serializer.toJson<int?>(episodeNumber),
      'episodeTitle': serializer.toJson<String>(episodeTitle),
      'sourceType': serializer.toJson<String>(
        $PlaybackRecordsTable.$convertersourceType.toJson(sourceType),
      ),
      'playedAt': serializer.toJson<DateTime>(playedAt),
      'positionSeconds': serializer.toJson<int>(positionSeconds),
      'durationSeconds': serializer.toJson<int>(durationSeconds),
      'isCompleted': serializer.toJson<bool>(isCompleted),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
    };
  }

  PlaybackRecordRow copyWith({
    String? id,
    String? workId,
    String? episodeId,
    String? variantId,
    int? seasonNumber,
    Value<int?> episodeNumber = const Value.absent(),
    String? episodeTitle,
    MediaSourceKind? sourceType,
    DateTime? playedAt,
    int? positionSeconds,
    int? durationSeconds,
    bool? isCompleted,
    int? updatedAtMs,
  }) => PlaybackRecordRow(
    id: id ?? this.id,
    workId: workId ?? this.workId,
    episodeId: episodeId ?? this.episodeId,
    variantId: variantId ?? this.variantId,
    seasonNumber: seasonNumber ?? this.seasonNumber,
    episodeNumber: episodeNumber.present
        ? episodeNumber.value
        : this.episodeNumber,
    episodeTitle: episodeTitle ?? this.episodeTitle,
    sourceType: sourceType ?? this.sourceType,
    playedAt: playedAt ?? this.playedAt,
    positionSeconds: positionSeconds ?? this.positionSeconds,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    isCompleted: isCompleted ?? this.isCompleted,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );
  PlaybackRecordRow copyWithCompanion(PlaybackRecordsCompanion data) {
    return PlaybackRecordRow(
      id: data.id.present ? data.id.value : this.id,
      workId: data.workId.present ? data.workId.value : this.workId,
      episodeId: data.episodeId.present ? data.episodeId.value : this.episodeId,
      variantId: data.variantId.present ? data.variantId.value : this.variantId,
      seasonNumber: data.seasonNumber.present
          ? data.seasonNumber.value
          : this.seasonNumber,
      episodeNumber: data.episodeNumber.present
          ? data.episodeNumber.value
          : this.episodeNumber,
      episodeTitle: data.episodeTitle.present
          ? data.episodeTitle.value
          : this.episodeTitle,
      sourceType: data.sourceType.present
          ? data.sourceType.value
          : this.sourceType,
      playedAt: data.playedAt.present ? data.playedAt.value : this.playedAt,
      positionSeconds: data.positionSeconds.present
          ? data.positionSeconds.value
          : this.positionSeconds,
      durationSeconds: data.durationSeconds.present
          ? data.durationSeconds.value
          : this.durationSeconds,
      isCompleted: data.isCompleted.present
          ? data.isCompleted.value
          : this.isCompleted,
      updatedAtMs: data.updatedAtMs.present
          ? data.updatedAtMs.value
          : this.updatedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlaybackRecordRow(')
          ..write('id: $id, ')
          ..write('workId: $workId, ')
          ..write('episodeId: $episodeId, ')
          ..write('variantId: $variantId, ')
          ..write('seasonNumber: $seasonNumber, ')
          ..write('episodeNumber: $episodeNumber, ')
          ..write('episodeTitle: $episodeTitle, ')
          ..write('sourceType: $sourceType, ')
          ..write('playedAt: $playedAt, ')
          ..write('positionSeconds: $positionSeconds, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('isCompleted: $isCompleted, ')
          ..write('updatedAtMs: $updatedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    workId,
    episodeId,
    variantId,
    seasonNumber,
    episodeNumber,
    episodeTitle,
    sourceType,
    playedAt,
    positionSeconds,
    durationSeconds,
    isCompleted,
    updatedAtMs,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackRecordRow &&
          other.id == this.id &&
          other.workId == this.workId &&
          other.episodeId == this.episodeId &&
          other.variantId == this.variantId &&
          other.seasonNumber == this.seasonNumber &&
          other.episodeNumber == this.episodeNumber &&
          other.episodeTitle == this.episodeTitle &&
          other.sourceType == this.sourceType &&
          other.playedAt == this.playedAt &&
          other.positionSeconds == this.positionSeconds &&
          other.durationSeconds == this.durationSeconds &&
          other.isCompleted == this.isCompleted &&
          other.updatedAtMs == this.updatedAtMs);
}

class PlaybackRecordsCompanion extends UpdateCompanion<PlaybackRecordRow> {
  final Value<String> id;
  final Value<String> workId;
  final Value<String> episodeId;
  final Value<String> variantId;
  final Value<int> seasonNumber;
  final Value<int?> episodeNumber;
  final Value<String> episodeTitle;
  final Value<MediaSourceKind> sourceType;
  final Value<DateTime> playedAt;
  final Value<int> positionSeconds;
  final Value<int> durationSeconds;
  final Value<bool> isCompleted;
  final Value<int> updatedAtMs;
  final Value<int> rowid;
  const PlaybackRecordsCompanion({
    this.id = const Value.absent(),
    this.workId = const Value.absent(),
    this.episodeId = const Value.absent(),
    this.variantId = const Value.absent(),
    this.seasonNumber = const Value.absent(),
    this.episodeNumber = const Value.absent(),
    this.episodeTitle = const Value.absent(),
    this.sourceType = const Value.absent(),
    this.playedAt = const Value.absent(),
    this.positionSeconds = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.isCompleted = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlaybackRecordsCompanion.insert({
    required String id,
    required String workId,
    required String episodeId,
    required String variantId,
    required int seasonNumber,
    this.episodeNumber = const Value.absent(),
    required String episodeTitle,
    required MediaSourceKind sourceType,
    required DateTime playedAt,
    this.positionSeconds = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.isCompleted = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       workId = Value(workId),
       episodeId = Value(episodeId),
       variantId = Value(variantId),
       seasonNumber = Value(seasonNumber),
       episodeTitle = Value(episodeTitle),
       sourceType = Value(sourceType),
       playedAt = Value(playedAt);
  static Insertable<PlaybackRecordRow> custom({
    Expression<String>? id,
    Expression<String>? workId,
    Expression<String>? episodeId,
    Expression<String>? variantId,
    Expression<int>? seasonNumber,
    Expression<int>? episodeNumber,
    Expression<String>? episodeTitle,
    Expression<String>? sourceType,
    Expression<DateTime>? playedAt,
    Expression<int>? positionSeconds,
    Expression<int>? durationSeconds,
    Expression<bool>? isCompleted,
    Expression<int>? updatedAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (workId != null) 'work_id': workId,
      if (episodeId != null) 'episode_id': episodeId,
      if (variantId != null) 'variant_id': variantId,
      if (seasonNumber != null) 'season_number': seasonNumber,
      if (episodeNumber != null) 'episode_number': episodeNumber,
      if (episodeTitle != null) 'episode_title': episodeTitle,
      if (sourceType != null) 'source_type': sourceType,
      if (playedAt != null) 'played_at': playedAt,
      if (positionSeconds != null) 'position_seconds': positionSeconds,
      if (durationSeconds != null) 'duration_seconds': durationSeconds,
      if (isCompleted != null) 'is_completed': isCompleted,
      if (updatedAtMs != null) 'updated_at_ms': updatedAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlaybackRecordsCompanion copyWith({
    Value<String>? id,
    Value<String>? workId,
    Value<String>? episodeId,
    Value<String>? variantId,
    Value<int>? seasonNumber,
    Value<int?>? episodeNumber,
    Value<String>? episodeTitle,
    Value<MediaSourceKind>? sourceType,
    Value<DateTime>? playedAt,
    Value<int>? positionSeconds,
    Value<int>? durationSeconds,
    Value<bool>? isCompleted,
    Value<int>? updatedAtMs,
    Value<int>? rowid,
  }) {
    return PlaybackRecordsCompanion(
      id: id ?? this.id,
      workId: workId ?? this.workId,
      episodeId: episodeId ?? this.episodeId,
      variantId: variantId ?? this.variantId,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      episodeTitle: episodeTitle ?? this.episodeTitle,
      sourceType: sourceType ?? this.sourceType,
      playedAt: playedAt ?? this.playedAt,
      positionSeconds: positionSeconds ?? this.positionSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      isCompleted: isCompleted ?? this.isCompleted,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (workId.present) {
      map['work_id'] = Variable<String>(workId.value);
    }
    if (episodeId.present) {
      map['episode_id'] = Variable<String>(episodeId.value);
    }
    if (variantId.present) {
      map['variant_id'] = Variable<String>(variantId.value);
    }
    if (seasonNumber.present) {
      map['season_number'] = Variable<int>(seasonNumber.value);
    }
    if (episodeNumber.present) {
      map['episode_number'] = Variable<int>(episodeNumber.value);
    }
    if (episodeTitle.present) {
      map['episode_title'] = Variable<String>(episodeTitle.value);
    }
    if (sourceType.present) {
      map['source_type'] = Variable<String>(
        $PlaybackRecordsTable.$convertersourceType.toSql(sourceType.value),
      );
    }
    if (playedAt.present) {
      map['played_at'] = Variable<DateTime>(playedAt.value);
    }
    if (positionSeconds.present) {
      map['position_seconds'] = Variable<int>(positionSeconds.value);
    }
    if (durationSeconds.present) {
      map['duration_seconds'] = Variable<int>(durationSeconds.value);
    }
    if (isCompleted.present) {
      map['is_completed'] = Variable<bool>(isCompleted.value);
    }
    if (updatedAtMs.present) {
      map['updated_at_ms'] = Variable<int>(updatedAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlaybackRecordsCompanion(')
          ..write('id: $id, ')
          ..write('workId: $workId, ')
          ..write('episodeId: $episodeId, ')
          ..write('variantId: $variantId, ')
          ..write('seasonNumber: $seasonNumber, ')
          ..write('episodeNumber: $episodeNumber, ')
          ..write('episodeTitle: $episodeTitle, ')
          ..write('sourceType: $sourceType, ')
          ..write('playedAt: $playedAt, ')
          ..write('positionSeconds: $positionSeconds, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('isCompleted: $isCompleted, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $IgnoredFoldersTable extends IgnoredFolders
    with TableInfo<$IgnoredFoldersTable, IgnoredFolderRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $IgnoredFoldersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES media_sources (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _relativePathMeta = const VerificationMeta(
    'relativePath',
  );
  @override
  late final GeneratedColumn<String> relativePath = GeneratedColumn<String>(
    'relative_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [id, sourceId, relativePath, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ignored_folders';
  @override
  VerificationContext validateIntegrity(
    Insertable<IgnoredFolderRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('relative_path')) {
      context.handle(
        _relativePathMeta,
        relativePath.isAcceptableOrUnknown(
          data['relative_path']!,
          _relativePathMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_relativePathMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  IgnoredFolderRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return IgnoredFolderRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      )!,
      relativePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}relative_path'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      ),
    );
  }

  @override
  $IgnoredFoldersTable createAlias(String alias) {
    return $IgnoredFoldersTable(attachedDatabase, alias);
  }
}

class IgnoredFolderRow extends DataClass
    implements Insertable<IgnoredFolderRow> {
  /// 忽略规则唯一主键 (`sourceId::relativePath`)。
  final String id;

  /// 所属媒体源 ID。
  final String sourceId;

  /// 相对媒体源根目录的文件夹路径（POSIX）。
  final String relativePath;

  /// 添加时间。
  final DateTime? createdAt;
  const IgnoredFolderRow({
    required this.id,
    required this.sourceId,
    required this.relativePath,
    this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['source_id'] = Variable<String>(sourceId);
    map['relative_path'] = Variable<String>(relativePath);
    if (!nullToAbsent || createdAt != null) {
      map['created_at'] = Variable<DateTime>(createdAt);
    }
    return map;
  }

  IgnoredFoldersCompanion toCompanion(bool nullToAbsent) {
    return IgnoredFoldersCompanion(
      id: Value(id),
      sourceId: Value(sourceId),
      relativePath: Value(relativePath),
      createdAt: createdAt == null && nullToAbsent
          ? const Value.absent()
          : Value(createdAt),
    );
  }

  factory IgnoredFolderRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return IgnoredFolderRow(
      id: serializer.fromJson<String>(json['id']),
      sourceId: serializer.fromJson<String>(json['sourceId']),
      relativePath: serializer.fromJson<String>(json['relativePath']),
      createdAt: serializer.fromJson<DateTime?>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'sourceId': serializer.toJson<String>(sourceId),
      'relativePath': serializer.toJson<String>(relativePath),
      'createdAt': serializer.toJson<DateTime?>(createdAt),
    };
  }

  IgnoredFolderRow copyWith({
    String? id,
    String? sourceId,
    String? relativePath,
    Value<DateTime?> createdAt = const Value.absent(),
  }) => IgnoredFolderRow(
    id: id ?? this.id,
    sourceId: sourceId ?? this.sourceId,
    relativePath: relativePath ?? this.relativePath,
    createdAt: createdAt.present ? createdAt.value : this.createdAt,
  );
  IgnoredFolderRow copyWithCompanion(IgnoredFoldersCompanion data) {
    return IgnoredFolderRow(
      id: data.id.present ? data.id.value : this.id,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      relativePath: data.relativePath.present
          ? data.relativePath.value
          : this.relativePath,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('IgnoredFolderRow(')
          ..write('id: $id, ')
          ..write('sourceId: $sourceId, ')
          ..write('relativePath: $relativePath, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, sourceId, relativePath, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is IgnoredFolderRow &&
          other.id == this.id &&
          other.sourceId == this.sourceId &&
          other.relativePath == this.relativePath &&
          other.createdAt == this.createdAt);
}

class IgnoredFoldersCompanion extends UpdateCompanion<IgnoredFolderRow> {
  final Value<String> id;
  final Value<String> sourceId;
  final Value<String> relativePath;
  final Value<DateTime?> createdAt;
  final Value<int> rowid;
  const IgnoredFoldersCompanion({
    this.id = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.relativePath = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  IgnoredFoldersCompanion.insert({
    required String id,
    required String sourceId,
    required String relativePath,
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       sourceId = Value(sourceId),
       relativePath = Value(relativePath);
  static Insertable<IgnoredFolderRow> custom({
    Expression<String>? id,
    Expression<String>? sourceId,
    Expression<String>? relativePath,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sourceId != null) 'source_id': sourceId,
      if (relativePath != null) 'relative_path': relativePath,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  IgnoredFoldersCompanion copyWith({
    Value<String>? id,
    Value<String>? sourceId,
    Value<String>? relativePath,
    Value<DateTime?>? createdAt,
    Value<int>? rowid,
  }) {
    return IgnoredFoldersCompanion(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      relativePath: relativePath ?? this.relativePath,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (relativePath.present) {
      map['relative_path'] = Variable<String>(relativePath.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('IgnoredFoldersCompanion(')
          ..write('id: $id, ')
          ..write('sourceId: $sourceId, ')
          ..write('relativePath: $relativePath, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SeriesGroupsTable extends SeriesGroups
    with TableInfo<$SeriesGroupsTable, SeriesGroupRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SeriesGroupsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tmdbCollectionIdMeta = const VerificationMeta(
    'tmdbCollectionId',
  );
  @override
  late final GeneratedColumn<int> tmdbCollectionId = GeneratedColumn<int>(
    'tmdb_collection_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _rootFolderHintMeta = const VerificationMeta(
    'rootFolderHint',
  );
  @override
  late final GeneratedColumn<String> rootFolderHint = GeneratedColumn<String>(
    'root_folder_hint',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    tmdbCollectionId,
    rootFolderHint,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'series_groups';
  @override
  VerificationContext validateIntegrity(
    Insertable<SeriesGroupRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('tmdb_collection_id')) {
      context.handle(
        _tmdbCollectionIdMeta,
        tmdbCollectionId.isAcceptableOrUnknown(
          data['tmdb_collection_id']!,
          _tmdbCollectionIdMeta,
        ),
      );
    }
    if (data.containsKey('root_folder_hint')) {
      context.handle(
        _rootFolderHintMeta,
        rootFolderHint.isAcceptableOrUnknown(
          data['root_folder_hint']!,
          _rootFolderHintMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SeriesGroupRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SeriesGroupRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      tmdbCollectionId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tmdb_collection_id'],
      ),
      rootFolderHint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}root_folder_hint'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $SeriesGroupsTable createAlias(String alias) {
    return $SeriesGroupsTable(attachedDatabase, alias);
  }
}

class SeriesGroupRow extends DataClass implements Insertable<SeriesGroupRow> {
  /// 系列唯一主键。
  final String id;

  /// 系列展示标题。
  final String title;

  /// 关联的 TMDB 电影合集 ID。
  final int? tmdbCollectionId;

  /// 关联的合集根目录相对路径提示。
  final String? rootFolderHint;

  /// 创建时间。
  final DateTime createdAt;

  /// 最近更新时间。
  final DateTime updatedAt;
  const SeriesGroupRow({
    required this.id,
    required this.title,
    this.tmdbCollectionId,
    this.rootFolderHint,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || tmdbCollectionId != null) {
      map['tmdb_collection_id'] = Variable<int>(tmdbCollectionId);
    }
    if (!nullToAbsent || rootFolderHint != null) {
      map['root_folder_hint'] = Variable<String>(rootFolderHint);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  SeriesGroupsCompanion toCompanion(bool nullToAbsent) {
    return SeriesGroupsCompanion(
      id: Value(id),
      title: Value(title),
      tmdbCollectionId: tmdbCollectionId == null && nullToAbsent
          ? const Value.absent()
          : Value(tmdbCollectionId),
      rootFolderHint: rootFolderHint == null && nullToAbsent
          ? const Value.absent()
          : Value(rootFolderHint),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory SeriesGroupRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SeriesGroupRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      tmdbCollectionId: serializer.fromJson<int?>(json['tmdbCollectionId']),
      rootFolderHint: serializer.fromJson<String?>(json['rootFolderHint']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'tmdbCollectionId': serializer.toJson<int?>(tmdbCollectionId),
      'rootFolderHint': serializer.toJson<String?>(rootFolderHint),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  SeriesGroupRow copyWith({
    String? id,
    String? title,
    Value<int?> tmdbCollectionId = const Value.absent(),
    Value<String?> rootFolderHint = const Value.absent(),
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => SeriesGroupRow(
    id: id ?? this.id,
    title: title ?? this.title,
    tmdbCollectionId: tmdbCollectionId.present
        ? tmdbCollectionId.value
        : this.tmdbCollectionId,
    rootFolderHint: rootFolderHint.present
        ? rootFolderHint.value
        : this.rootFolderHint,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  SeriesGroupRow copyWithCompanion(SeriesGroupsCompanion data) {
    return SeriesGroupRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      tmdbCollectionId: data.tmdbCollectionId.present
          ? data.tmdbCollectionId.value
          : this.tmdbCollectionId,
      rootFolderHint: data.rootFolderHint.present
          ? data.rootFolderHint.value
          : this.rootFolderHint,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SeriesGroupRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('tmdbCollectionId: $tmdbCollectionId, ')
          ..write('rootFolderHint: $rootFolderHint, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    tmdbCollectionId,
    rootFolderHint,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SeriesGroupRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.tmdbCollectionId == this.tmdbCollectionId &&
          other.rootFolderHint == this.rootFolderHint &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class SeriesGroupsCompanion extends UpdateCompanion<SeriesGroupRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<int?> tmdbCollectionId;
  final Value<String?> rootFolderHint;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const SeriesGroupsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.tmdbCollectionId = const Value.absent(),
    this.rootFolderHint = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SeriesGroupsCompanion.insert({
    required String id,
    required String title,
    this.tmdbCollectionId = const Value.absent(),
    this.rootFolderHint = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<SeriesGroupRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<int>? tmdbCollectionId,
    Expression<String>? rootFolderHint,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (tmdbCollectionId != null) 'tmdb_collection_id': tmdbCollectionId,
      if (rootFolderHint != null) 'root_folder_hint': rootFolderHint,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SeriesGroupsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<int?>? tmdbCollectionId,
    Value<String?>? rootFolderHint,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return SeriesGroupsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      tmdbCollectionId: tmdbCollectionId ?? this.tmdbCollectionId,
      rootFolderHint: rootFolderHint ?? this.rootFolderHint,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (tmdbCollectionId.present) {
      map['tmdb_collection_id'] = Variable<int>(tmdbCollectionId.value);
    }
    if (rootFolderHint.present) {
      map['root_folder_hint'] = Variable<String>(rootFolderHint.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SeriesGroupsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('tmdbCollectionId: $tmdbCollectionId, ')
          ..write('rootFolderHint: $rootFolderHint, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LyricCacheEntriesTable extends LyricCacheEntries
    with TableInfo<$LyricCacheEntriesTable, LyricCacheRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LyricCacheEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _trackKeyMeta = const VerificationMeta(
    'trackKey',
  );
  @override
  late final GeneratedColumn<String> trackKey = GeneratedColumn<String>(
    'track_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _songKeyMeta = const VerificationMeta(
    'songKey',
  );
  @override
  late final GeneratedColumn<String> songKey = GeneratedColumn<String>(
    'song_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<LyricCacheStatus, String> status =
      GeneratedColumn<String>(
        'status',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<LyricCacheStatus>(
        $LyricCacheEntriesTable.$converterstatus,
      );
  @override
  late final GeneratedColumnWithTypeConverter<LyricSource?, String> source =
      GeneratedColumn<String>(
        'source',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      ).withConverter<LyricSource?>($LyricCacheEntriesTable.$convertersourcen);
  static const VerificationMeta _sourceIdMeta = const VerificationMeta(
    'sourceId',
  );
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _lrcContentMeta = const VerificationMeta(
    'lrcContent',
  );
  @override
  late final GeneratedColumn<String> lrcContent = GeneratedColumn<String>(
    'lrc_content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _scoreMeta = const VerificationMeta('score');
  @override
  late final GeneratedColumn<double> score = GeneratedColumn<double>(
    'score',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0.0),
  );
  static const VerificationMeta _engineVersionMeta = const VerificationMeta(
    'engineVersion',
  );
  @override
  late final GeneratedColumn<int> engineVersion = GeneratedColumn<int>(
    'engine_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    trackKey,
    songKey,
    status,
    source,
    sourceId,
    lrcContent,
    score,
    engineVersion,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'lyric_cache_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<LyricCacheRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('track_key')) {
      context.handle(
        _trackKeyMeta,
        trackKey.isAcceptableOrUnknown(data['track_key']!, _trackKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_trackKeyMeta);
    }
    if (data.containsKey('song_key')) {
      context.handle(
        _songKeyMeta,
        songKey.isAcceptableOrUnknown(data['song_key']!, _songKeyMeta),
      );
    }
    if (data.containsKey('source_id')) {
      context.handle(
        _sourceIdMeta,
        sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta),
      );
    }
    if (data.containsKey('lrc_content')) {
      context.handle(
        _lrcContentMeta,
        lrcContent.isAcceptableOrUnknown(data['lrc_content']!, _lrcContentMeta),
      );
    }
    if (data.containsKey('score')) {
      context.handle(
        _scoreMeta,
        score.isAcceptableOrUnknown(data['score']!, _scoreMeta),
      );
    }
    if (data.containsKey('engine_version')) {
      context.handle(
        _engineVersionMeta,
        engineVersion.isAcceptableOrUnknown(
          data['engine_version']!,
          _engineVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_engineVersionMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {trackKey};
  @override
  LyricCacheRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LyricCacheRow(
      trackKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}track_key'],
      )!,
      songKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}song_key'],
      ),
      status: $LyricCacheEntriesTable.$converterstatus.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}status'],
        )!,
      ),
      source: $LyricCacheEntriesTable.$convertersourcen.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}source'],
        ),
      ),
      sourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_id'],
      )!,
      lrcContent: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}lrc_content'],
      )!,
      score: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}score'],
      )!,
      engineVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}engine_version'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $LyricCacheEntriesTable createAlias(String alias) {
    return $LyricCacheEntriesTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<LyricCacheStatus, String, String> $converterstatus =
      const EnumNameConverter<LyricCacheStatus>(LyricCacheStatus.values);
  static JsonTypeConverter2<LyricSource, String, String> $convertersource =
      const EnumNameConverter<LyricSource>(LyricSource.values);
  static JsonTypeConverter2<LyricSource?, String?, String?> $convertersourcen =
      JsonTypeConverter2.asNullable($convertersource);
}

class LyricCacheRow extends DataClass implements Insertable<LyricCacheRow> {
  /// 物理曲目键（媒体源 + 相对路径 + 文件大小 + CUE 分轨起点）。
  final String trackKey;

  /// 跨文件共享的歌曲身份键。
  final String? songKey;

  /// 缓存状态。
  final LyricCacheStatus status;

  /// 命中来源。
  final LyricSource? source;

  /// 来源内部歌曲标识。
  final String sourceId;

  /// 增强 LRC 正文。
  final String lrcContent;

  /// 命中候选得分。
  final double score;

  /// 歌词引擎版本。
  final int engineVersion;

  /// 最近写入时间。
  final DateTime updatedAt;
  const LyricCacheRow({
    required this.trackKey,
    this.songKey,
    required this.status,
    this.source,
    required this.sourceId,
    required this.lrcContent,
    required this.score,
    required this.engineVersion,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['track_key'] = Variable<String>(trackKey);
    if (!nullToAbsent || songKey != null) {
      map['song_key'] = Variable<String>(songKey);
    }
    {
      map['status'] = Variable<String>(
        $LyricCacheEntriesTable.$converterstatus.toSql(status),
      );
    }
    if (!nullToAbsent || source != null) {
      map['source'] = Variable<String>(
        $LyricCacheEntriesTable.$convertersourcen.toSql(source),
      );
    }
    map['source_id'] = Variable<String>(sourceId);
    map['lrc_content'] = Variable<String>(lrcContent);
    map['score'] = Variable<double>(score);
    map['engine_version'] = Variable<int>(engineVersion);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  LyricCacheEntriesCompanion toCompanion(bool nullToAbsent) {
    return LyricCacheEntriesCompanion(
      trackKey: Value(trackKey),
      songKey: songKey == null && nullToAbsent
          ? const Value.absent()
          : Value(songKey),
      status: Value(status),
      source: source == null && nullToAbsent
          ? const Value.absent()
          : Value(source),
      sourceId: Value(sourceId),
      lrcContent: Value(lrcContent),
      score: Value(score),
      engineVersion: Value(engineVersion),
      updatedAt: Value(updatedAt),
    );
  }

  factory LyricCacheRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LyricCacheRow(
      trackKey: serializer.fromJson<String>(json['trackKey']),
      songKey: serializer.fromJson<String?>(json['songKey']),
      status: $LyricCacheEntriesTable.$converterstatus.fromJson(
        serializer.fromJson<String>(json['status']),
      ),
      source: $LyricCacheEntriesTable.$convertersourcen.fromJson(
        serializer.fromJson<String?>(json['source']),
      ),
      sourceId: serializer.fromJson<String>(json['sourceId']),
      lrcContent: serializer.fromJson<String>(json['lrcContent']),
      score: serializer.fromJson<double>(json['score']),
      engineVersion: serializer.fromJson<int>(json['engineVersion']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'trackKey': serializer.toJson<String>(trackKey),
      'songKey': serializer.toJson<String?>(songKey),
      'status': serializer.toJson<String>(
        $LyricCacheEntriesTable.$converterstatus.toJson(status),
      ),
      'source': serializer.toJson<String?>(
        $LyricCacheEntriesTable.$convertersourcen.toJson(source),
      ),
      'sourceId': serializer.toJson<String>(sourceId),
      'lrcContent': serializer.toJson<String>(lrcContent),
      'score': serializer.toJson<double>(score),
      'engineVersion': serializer.toJson<int>(engineVersion),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  LyricCacheRow copyWith({
    String? trackKey,
    Value<String?> songKey = const Value.absent(),
    LyricCacheStatus? status,
    Value<LyricSource?> source = const Value.absent(),
    String? sourceId,
    String? lrcContent,
    double? score,
    int? engineVersion,
    DateTime? updatedAt,
  }) => LyricCacheRow(
    trackKey: trackKey ?? this.trackKey,
    songKey: songKey.present ? songKey.value : this.songKey,
    status: status ?? this.status,
    source: source.present ? source.value : this.source,
    sourceId: sourceId ?? this.sourceId,
    lrcContent: lrcContent ?? this.lrcContent,
    score: score ?? this.score,
    engineVersion: engineVersion ?? this.engineVersion,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  LyricCacheRow copyWithCompanion(LyricCacheEntriesCompanion data) {
    return LyricCacheRow(
      trackKey: data.trackKey.present ? data.trackKey.value : this.trackKey,
      songKey: data.songKey.present ? data.songKey.value : this.songKey,
      status: data.status.present ? data.status.value : this.status,
      source: data.source.present ? data.source.value : this.source,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      lrcContent: data.lrcContent.present
          ? data.lrcContent.value
          : this.lrcContent,
      score: data.score.present ? data.score.value : this.score,
      engineVersion: data.engineVersion.present
          ? data.engineVersion.value
          : this.engineVersion,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LyricCacheRow(')
          ..write('trackKey: $trackKey, ')
          ..write('songKey: $songKey, ')
          ..write('status: $status, ')
          ..write('source: $source, ')
          ..write('sourceId: $sourceId, ')
          ..write('lrcContent: $lrcContent, ')
          ..write('score: $score, ')
          ..write('engineVersion: $engineVersion, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    trackKey,
    songKey,
    status,
    source,
    sourceId,
    lrcContent,
    score,
    engineVersion,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LyricCacheRow &&
          other.trackKey == this.trackKey &&
          other.songKey == this.songKey &&
          other.status == this.status &&
          other.source == this.source &&
          other.sourceId == this.sourceId &&
          other.lrcContent == this.lrcContent &&
          other.score == this.score &&
          other.engineVersion == this.engineVersion &&
          other.updatedAt == this.updatedAt);
}

class LyricCacheEntriesCompanion extends UpdateCompanion<LyricCacheRow> {
  final Value<String> trackKey;
  final Value<String?> songKey;
  final Value<LyricCacheStatus> status;
  final Value<LyricSource?> source;
  final Value<String> sourceId;
  final Value<String> lrcContent;
  final Value<double> score;
  final Value<int> engineVersion;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const LyricCacheEntriesCompanion({
    this.trackKey = const Value.absent(),
    this.songKey = const Value.absent(),
    this.status = const Value.absent(),
    this.source = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.lrcContent = const Value.absent(),
    this.score = const Value.absent(),
    this.engineVersion = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LyricCacheEntriesCompanion.insert({
    required String trackKey,
    this.songKey = const Value.absent(),
    required LyricCacheStatus status,
    this.source = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.lrcContent = const Value.absent(),
    this.score = const Value.absent(),
    required int engineVersion,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : trackKey = Value(trackKey),
       status = Value(status),
       engineVersion = Value(engineVersion),
       updatedAt = Value(updatedAt);
  static Insertable<LyricCacheRow> custom({
    Expression<String>? trackKey,
    Expression<String>? songKey,
    Expression<String>? status,
    Expression<String>? source,
    Expression<String>? sourceId,
    Expression<String>? lrcContent,
    Expression<double>? score,
    Expression<int>? engineVersion,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (trackKey != null) 'track_key': trackKey,
      if (songKey != null) 'song_key': songKey,
      if (status != null) 'status': status,
      if (source != null) 'source': source,
      if (sourceId != null) 'source_id': sourceId,
      if (lrcContent != null) 'lrc_content': lrcContent,
      if (score != null) 'score': score,
      if (engineVersion != null) 'engine_version': engineVersion,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LyricCacheEntriesCompanion copyWith({
    Value<String>? trackKey,
    Value<String?>? songKey,
    Value<LyricCacheStatus>? status,
    Value<LyricSource?>? source,
    Value<String>? sourceId,
    Value<String>? lrcContent,
    Value<double>? score,
    Value<int>? engineVersion,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return LyricCacheEntriesCompanion(
      trackKey: trackKey ?? this.trackKey,
      songKey: songKey ?? this.songKey,
      status: status ?? this.status,
      source: source ?? this.source,
      sourceId: sourceId ?? this.sourceId,
      lrcContent: lrcContent ?? this.lrcContent,
      score: score ?? this.score,
      engineVersion: engineVersion ?? this.engineVersion,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (trackKey.present) {
      map['track_key'] = Variable<String>(trackKey.value);
    }
    if (songKey.present) {
      map['song_key'] = Variable<String>(songKey.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(
        $LyricCacheEntriesTable.$converterstatus.toSql(status.value),
      );
    }
    if (source.present) {
      map['source'] = Variable<String>(
        $LyricCacheEntriesTable.$convertersourcen.toSql(source.value),
      );
    }
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (lrcContent.present) {
      map['lrc_content'] = Variable<String>(lrcContent.value);
    }
    if (score.present) {
      map['score'] = Variable<double>(score.value);
    }
    if (engineVersion.present) {
      map['engine_version'] = Variable<int>(engineVersion.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LyricCacheEntriesCompanion(')
          ..write('trackKey: $trackKey, ')
          ..write('songKey: $songKey, ')
          ..write('status: $status, ')
          ..write('source: $source, ')
          ..write('sourceId: $sourceId, ')
          ..write('lrcContent: $lrcContent, ')
          ..write('score: $score, ')
          ..write('engineVersion: $engineVersion, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncTombstonesTable extends SyncTombstones
    with TableInfo<$SyncTombstonesTable, SyncTombstoneRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncTombstonesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _entityKeyMeta = const VerificationMeta(
    'entityKey',
  );
  @override
  late final GeneratedColumn<String> entityKey = GeneratedColumn<String>(
    'entity_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityTypeMeta = const VerificationMeta(
    'entityType',
  );
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
    'entity_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMsMeta = const VerificationMeta(
    'deletedAtMs',
  );
  @override
  late final GeneratedColumn<int> deletedAtMs = GeneratedColumn<int>(
    'deleted_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    entityKey,
    entityType,
    deletedAtMs,
    deviceId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_tombstones';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncTombstoneRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('entity_key')) {
      context.handle(
        _entityKeyMeta,
        entityKey.isAcceptableOrUnknown(data['entity_key']!, _entityKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_entityKeyMeta);
    }
    if (data.containsKey('entity_type')) {
      context.handle(
        _entityTypeMeta,
        entityType.isAcceptableOrUnknown(data['entity_type']!, _entityTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    if (data.containsKey('deleted_at_ms')) {
      context.handle(
        _deletedAtMsMeta,
        deletedAtMs.isAcceptableOrUnknown(
          data['deleted_at_ms']!,
          _deletedAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_deletedAtMsMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {entityKey};
  @override
  SyncTombstoneRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncTombstoneRow(
      entityKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_key'],
      )!,
      entityType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_type'],
      )!,
      deletedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at_ms'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
    );
  }

  @override
  $SyncTombstonesTable createAlias(String alias) {
    return $SyncTombstonesTable(attachedDatabase, alias);
  }
}

class SyncTombstoneRow extends DataClass
    implements Insertable<SyncTombstoneRow> {
  /// 逻辑实体唯一键（如 `playback::<canonicalKey>::s1::e3`）。
  final String entityKey;

  /// 实体类型（`playback` / `work_override` / `series`）。
  final String entityType;

  /// 删除发生的 UTC 毫秒时间戳。
  final int deletedAtMs;

  /// 产生该删除动作的设备标识。
  final String deviceId;
  const SyncTombstoneRow({
    required this.entityKey,
    required this.entityType,
    required this.deletedAtMs,
    required this.deviceId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['entity_key'] = Variable<String>(entityKey);
    map['entity_type'] = Variable<String>(entityType);
    map['deleted_at_ms'] = Variable<int>(deletedAtMs);
    map['device_id'] = Variable<String>(deviceId);
    return map;
  }

  SyncTombstonesCompanion toCompanion(bool nullToAbsent) {
    return SyncTombstonesCompanion(
      entityKey: Value(entityKey),
      entityType: Value(entityType),
      deletedAtMs: Value(deletedAtMs),
      deviceId: Value(deviceId),
    );
  }

  factory SyncTombstoneRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncTombstoneRow(
      entityKey: serializer.fromJson<String>(json['entityKey']),
      entityType: serializer.fromJson<String>(json['entityType']),
      deletedAtMs: serializer.fromJson<int>(json['deletedAtMs']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'entityKey': serializer.toJson<String>(entityKey),
      'entityType': serializer.toJson<String>(entityType),
      'deletedAtMs': serializer.toJson<int>(deletedAtMs),
      'deviceId': serializer.toJson<String>(deviceId),
    };
  }

  SyncTombstoneRow copyWith({
    String? entityKey,
    String? entityType,
    int? deletedAtMs,
    String? deviceId,
  }) => SyncTombstoneRow(
    entityKey: entityKey ?? this.entityKey,
    entityType: entityType ?? this.entityType,
    deletedAtMs: deletedAtMs ?? this.deletedAtMs,
    deviceId: deviceId ?? this.deviceId,
  );
  SyncTombstoneRow copyWithCompanion(SyncTombstonesCompanion data) {
    return SyncTombstoneRow(
      entityKey: data.entityKey.present ? data.entityKey.value : this.entityKey,
      entityType: data.entityType.present
          ? data.entityType.value
          : this.entityType,
      deletedAtMs: data.deletedAtMs.present
          ? data.deletedAtMs.value
          : this.deletedAtMs,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncTombstoneRow(')
          ..write('entityKey: $entityKey, ')
          ..write('entityType: $entityType, ')
          ..write('deletedAtMs: $deletedAtMs, ')
          ..write('deviceId: $deviceId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(entityKey, entityType, deletedAtMs, deviceId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncTombstoneRow &&
          other.entityKey == this.entityKey &&
          other.entityType == this.entityType &&
          other.deletedAtMs == this.deletedAtMs &&
          other.deviceId == this.deviceId);
}

class SyncTombstonesCompanion extends UpdateCompanion<SyncTombstoneRow> {
  final Value<String> entityKey;
  final Value<String> entityType;
  final Value<int> deletedAtMs;
  final Value<String> deviceId;
  final Value<int> rowid;
  const SyncTombstonesCompanion({
    this.entityKey = const Value.absent(),
    this.entityType = const Value.absent(),
    this.deletedAtMs = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncTombstonesCompanion.insert({
    required String entityKey,
    required String entityType,
    required int deletedAtMs,
    required String deviceId,
    this.rowid = const Value.absent(),
  }) : entityKey = Value(entityKey),
       entityType = Value(entityType),
       deletedAtMs = Value(deletedAtMs),
       deviceId = Value(deviceId);
  static Insertable<SyncTombstoneRow> custom({
    Expression<String>? entityKey,
    Expression<String>? entityType,
    Expression<int>? deletedAtMs,
    Expression<String>? deviceId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (entityKey != null) 'entity_key': entityKey,
      if (entityType != null) 'entity_type': entityType,
      if (deletedAtMs != null) 'deleted_at_ms': deletedAtMs,
      if (deviceId != null) 'device_id': deviceId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncTombstonesCompanion copyWith({
    Value<String>? entityKey,
    Value<String>? entityType,
    Value<int>? deletedAtMs,
    Value<String>? deviceId,
    Value<int>? rowid,
  }) {
    return SyncTombstonesCompanion(
      entityKey: entityKey ?? this.entityKey,
      entityType: entityType ?? this.entityType,
      deletedAtMs: deletedAtMs ?? this.deletedAtMs,
      deviceId: deviceId ?? this.deviceId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (entityKey.present) {
      map['entity_key'] = Variable<String>(entityKey.value);
    }
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (deletedAtMs.present) {
      map['deleted_at_ms'] = Variable<int>(deletedAtMs.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncTombstonesCompanion(')
          ..write('entityKey: $entityKey, ')
          ..write('entityType: $entityType, ')
          ..write('deletedAtMs: $deletedAtMs, ')
          ..write('deviceId: $deviceId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncKvMetaTable extends SyncKvMeta
    with TableInfo<$SyncKvMetaTable, SyncKvMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncKvMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMsMeta = const VerificationMeta(
    'updatedAtMs',
  );
  @override
  late final GeneratedColumn<int> updatedAtMs = GeneratedColumn<int>(
    'updated_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value, updatedAtMs];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_kv_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncKvMetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    if (data.containsKey('updated_at_ms')) {
      context.handle(
        _updatedAtMsMeta,
        updatedAtMs.isAcceptableOrUnknown(
          data['updated_at_ms']!,
          _updatedAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  SyncKvMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncKvMetaRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
      updatedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at_ms'],
      )!,
    );
  }

  @override
  $SyncKvMetaTable createAlias(String alias) {
    return $SyncKvMetaTable(attachedDatabase, alias);
  }
}

class SyncKvMetaRow extends DataClass implements Insertable<SyncKvMetaRow> {
  /// 元信息键名。
  final String key;

  /// 元信息值文本。
  final String value;

  /// 最近更新的 UTC 毫秒时间戳。
  final int updatedAtMs;
  const SyncKvMetaRow({
    required this.key,
    required this.value,
    required this.updatedAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    map['updated_at_ms'] = Variable<int>(updatedAtMs);
    return map;
  }

  SyncKvMetaCompanion toCompanion(bool nullToAbsent) {
    return SyncKvMetaCompanion(
      key: Value(key),
      value: Value(value),
      updatedAtMs: Value(updatedAtMs),
    );
  }

  factory SyncKvMetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncKvMetaRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
    };
  }

  SyncKvMetaRow copyWith({String? key, String? value, int? updatedAtMs}) =>
      SyncKvMetaRow(
        key: key ?? this.key,
        value: value ?? this.value,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      );
  SyncKvMetaRow copyWithCompanion(SyncKvMetaCompanion data) {
    return SyncKvMetaRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
      updatedAtMs: data.updatedAtMs.present
          ? data.updatedAtMs.value
          : this.updatedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncKvMetaRow(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAtMs: $updatedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value, updatedAtMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncKvMetaRow &&
          other.key == this.key &&
          other.value == this.value &&
          other.updatedAtMs == this.updatedAtMs);
}

class SyncKvMetaCompanion extends UpdateCompanion<SyncKvMetaRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> updatedAtMs;
  final Value<int> rowid;
  const SyncKvMetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncKvMetaCompanion.insert({
    required String key,
    required String value,
    required int updatedAtMs,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value),
       updatedAtMs = Value(updatedAtMs);
  static Insertable<SyncKvMetaRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? updatedAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (updatedAtMs != null) 'updated_at_ms': updatedAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncKvMetaCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? updatedAtMs,
    Value<int>? rowid,
  }) {
    return SyncKvMetaCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (updatedAtMs.present) {
      map['updated_at_ms'] = Variable<int>(updatedAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncKvMetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BangumiSyncQueueTable extends BangumiSyncQueue
    with TableInfo<$BangumiSyncQueueTable, BangumiSyncQueueRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BangumiSyncQueueTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _queueKeyMeta = const VerificationMeta(
    'queueKey',
  );
  @override
  late final GeneratedColumn<String> queueKey = GeneratedColumn<String>(
    'queue_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subjectIdMeta = const VerificationMeta(
    'subjectId',
  );
  @override
  late final GeneratedColumn<int> subjectId = GeneratedColumn<int>(
    'subject_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seasonNumberMeta = const VerificationMeta(
    'seasonNumber',
  );
  @override
  late final GeneratedColumn<int> seasonNumber = GeneratedColumn<int>(
    'season_number',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _episodeNumberMeta = const VerificationMeta(
    'episodeNumber',
  );
  @override
  late final GeneratedColumn<int> episodeNumber = GeneratedColumn<int>(
    'episode_number',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _targetStatusMeta = const VerificationMeta(
    'targetStatus',
  );
  @override
  late final GeneratedColumn<int> targetStatus = GeneratedColumn<int>(
    'target_status',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _enqueuedAtMsMeta = const VerificationMeta(
    'enqueuedAtMs',
  );
  @override
  late final GeneratedColumn<int> enqueuedAtMs = GeneratedColumn<int>(
    'enqueued_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _retryCountMeta = const VerificationMeta(
    'retryCount',
  );
  @override
  late final GeneratedColumn<int> retryCount = GeneratedColumn<int>(
    'retry_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nextRetryAtMsMeta = const VerificationMeta(
    'nextRetryAtMs',
  );
  @override
  late final GeneratedColumn<int> nextRetryAtMs = GeneratedColumn<int>(
    'next_retry_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    queueKey,
    subjectId,
    seasonNumber,
    episodeNumber,
    targetStatus,
    enqueuedAtMs,
    retryCount,
    lastError,
    nextRetryAtMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'bangumi_sync_queue';
  @override
  VerificationContext validateIntegrity(
    Insertable<BangumiSyncQueueRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('queue_key')) {
      context.handle(
        _queueKeyMeta,
        queueKey.isAcceptableOrUnknown(data['queue_key']!, _queueKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_queueKeyMeta);
    }
    if (data.containsKey('subject_id')) {
      context.handle(
        _subjectIdMeta,
        subjectId.isAcceptableOrUnknown(data['subject_id']!, _subjectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_subjectIdMeta);
    }
    if (data.containsKey('season_number')) {
      context.handle(
        _seasonNumberMeta,
        seasonNumber.isAcceptableOrUnknown(
          data['season_number']!,
          _seasonNumberMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_seasonNumberMeta);
    }
    if (data.containsKey('episode_number')) {
      context.handle(
        _episodeNumberMeta,
        episodeNumber.isAcceptableOrUnknown(
          data['episode_number']!,
          _episodeNumberMeta,
        ),
      );
    }
    if (data.containsKey('target_status')) {
      context.handle(
        _targetStatusMeta,
        targetStatus.isAcceptableOrUnknown(
          data['target_status']!,
          _targetStatusMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_targetStatusMeta);
    }
    if (data.containsKey('enqueued_at_ms')) {
      context.handle(
        _enqueuedAtMsMeta,
        enqueuedAtMs.isAcceptableOrUnknown(
          data['enqueued_at_ms']!,
          _enqueuedAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_enqueuedAtMsMeta);
    }
    if (data.containsKey('retry_count')) {
      context.handle(
        _retryCountMeta,
        retryCount.isAcceptableOrUnknown(data['retry_count']!, _retryCountMeta),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    if (data.containsKey('next_retry_at_ms')) {
      context.handle(
        _nextRetryAtMsMeta,
        nextRetryAtMs.isAcceptableOrUnknown(
          data['next_retry_at_ms']!,
          _nextRetryAtMsMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {queueKey};
  @override
  BangumiSyncQueueRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BangumiSyncQueueRow(
      queueKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}queue_key'],
      )!,
      subjectId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}subject_id'],
      )!,
      seasonNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}season_number'],
      )!,
      episodeNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}episode_number'],
      ),
      targetStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}target_status'],
      )!,
      enqueuedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}enqueued_at_ms'],
      )!,
      retryCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}retry_count'],
      )!,
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
      nextRetryAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_retry_at_ms'],
      )!,
    );
  }

  @override
  $BangumiSyncQueueTable createAlias(String alias) {
    return $BangumiSyncQueueTable(attachedDatabase, alias);
  }
}

class BangumiSyncQueueRow extends DataClass
    implements Insertable<BangumiSyncQueueRow> {
  /// 队列项唯一去重键（如 `ep::<subjectId>::s<season>::e<ep>`）。
  final String queueKey;

  /// Bangumi 条目 ID。
  final int subjectId;

  /// 本地季号（用于区分配对关系与特典 SP）。
  final int seasonNumber;

  /// 集号（单部剧场版可为空）。
  final int? episodeNumber;

  /// 目标 Bangumi 单集观看状态（`2=看过`、`0=未看`）。
  final int targetStatus;

  /// 首次入队的 UTC 毫秒时间戳。
  final int enqueuedAtMs;

  /// 已失败重试次数。
  final int retryCount;

  /// 最近一次失败原因（已脱敏）。
  final String? lastError;

  /// 下次允许重试的 UTC 毫秒时间戳。
  final int nextRetryAtMs;
  const BangumiSyncQueueRow({
    required this.queueKey,
    required this.subjectId,
    required this.seasonNumber,
    this.episodeNumber,
    required this.targetStatus,
    required this.enqueuedAtMs,
    required this.retryCount,
    this.lastError,
    required this.nextRetryAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['queue_key'] = Variable<String>(queueKey);
    map['subject_id'] = Variable<int>(subjectId);
    map['season_number'] = Variable<int>(seasonNumber);
    if (!nullToAbsent || episodeNumber != null) {
      map['episode_number'] = Variable<int>(episodeNumber);
    }
    map['target_status'] = Variable<int>(targetStatus);
    map['enqueued_at_ms'] = Variable<int>(enqueuedAtMs);
    map['retry_count'] = Variable<int>(retryCount);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    map['next_retry_at_ms'] = Variable<int>(nextRetryAtMs);
    return map;
  }

  BangumiSyncQueueCompanion toCompanion(bool nullToAbsent) {
    return BangumiSyncQueueCompanion(
      queueKey: Value(queueKey),
      subjectId: Value(subjectId),
      seasonNumber: Value(seasonNumber),
      episodeNumber: episodeNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(episodeNumber),
      targetStatus: Value(targetStatus),
      enqueuedAtMs: Value(enqueuedAtMs),
      retryCount: Value(retryCount),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      nextRetryAtMs: Value(nextRetryAtMs),
    );
  }

  factory BangumiSyncQueueRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BangumiSyncQueueRow(
      queueKey: serializer.fromJson<String>(json['queueKey']),
      subjectId: serializer.fromJson<int>(json['subjectId']),
      seasonNumber: serializer.fromJson<int>(json['seasonNumber']),
      episodeNumber: serializer.fromJson<int?>(json['episodeNumber']),
      targetStatus: serializer.fromJson<int>(json['targetStatus']),
      enqueuedAtMs: serializer.fromJson<int>(json['enqueuedAtMs']),
      retryCount: serializer.fromJson<int>(json['retryCount']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      nextRetryAtMs: serializer.fromJson<int>(json['nextRetryAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'queueKey': serializer.toJson<String>(queueKey),
      'subjectId': serializer.toJson<int>(subjectId),
      'seasonNumber': serializer.toJson<int>(seasonNumber),
      'episodeNumber': serializer.toJson<int?>(episodeNumber),
      'targetStatus': serializer.toJson<int>(targetStatus),
      'enqueuedAtMs': serializer.toJson<int>(enqueuedAtMs),
      'retryCount': serializer.toJson<int>(retryCount),
      'lastError': serializer.toJson<String?>(lastError),
      'nextRetryAtMs': serializer.toJson<int>(nextRetryAtMs),
    };
  }

  BangumiSyncQueueRow copyWith({
    String? queueKey,
    int? subjectId,
    int? seasonNumber,
    Value<int?> episodeNumber = const Value.absent(),
    int? targetStatus,
    int? enqueuedAtMs,
    int? retryCount,
    Value<String?> lastError = const Value.absent(),
    int? nextRetryAtMs,
  }) => BangumiSyncQueueRow(
    queueKey: queueKey ?? this.queueKey,
    subjectId: subjectId ?? this.subjectId,
    seasonNumber: seasonNumber ?? this.seasonNumber,
    episodeNumber: episodeNumber.present
        ? episodeNumber.value
        : this.episodeNumber,
    targetStatus: targetStatus ?? this.targetStatus,
    enqueuedAtMs: enqueuedAtMs ?? this.enqueuedAtMs,
    retryCount: retryCount ?? this.retryCount,
    lastError: lastError.present ? lastError.value : this.lastError,
    nextRetryAtMs: nextRetryAtMs ?? this.nextRetryAtMs,
  );
  BangumiSyncQueueRow copyWithCompanion(BangumiSyncQueueCompanion data) {
    return BangumiSyncQueueRow(
      queueKey: data.queueKey.present ? data.queueKey.value : this.queueKey,
      subjectId: data.subjectId.present ? data.subjectId.value : this.subjectId,
      seasonNumber: data.seasonNumber.present
          ? data.seasonNumber.value
          : this.seasonNumber,
      episodeNumber: data.episodeNumber.present
          ? data.episodeNumber.value
          : this.episodeNumber,
      targetStatus: data.targetStatus.present
          ? data.targetStatus.value
          : this.targetStatus,
      enqueuedAtMs: data.enqueuedAtMs.present
          ? data.enqueuedAtMs.value
          : this.enqueuedAtMs,
      retryCount: data.retryCount.present
          ? data.retryCount.value
          : this.retryCount,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      nextRetryAtMs: data.nextRetryAtMs.present
          ? data.nextRetryAtMs.value
          : this.nextRetryAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BangumiSyncQueueRow(')
          ..write('queueKey: $queueKey, ')
          ..write('subjectId: $subjectId, ')
          ..write('seasonNumber: $seasonNumber, ')
          ..write('episodeNumber: $episodeNumber, ')
          ..write('targetStatus: $targetStatus, ')
          ..write('enqueuedAtMs: $enqueuedAtMs, ')
          ..write('retryCount: $retryCount, ')
          ..write('lastError: $lastError, ')
          ..write('nextRetryAtMs: $nextRetryAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    queueKey,
    subjectId,
    seasonNumber,
    episodeNumber,
    targetStatus,
    enqueuedAtMs,
    retryCount,
    lastError,
    nextRetryAtMs,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BangumiSyncQueueRow &&
          other.queueKey == this.queueKey &&
          other.subjectId == this.subjectId &&
          other.seasonNumber == this.seasonNumber &&
          other.episodeNumber == this.episodeNumber &&
          other.targetStatus == this.targetStatus &&
          other.enqueuedAtMs == this.enqueuedAtMs &&
          other.retryCount == this.retryCount &&
          other.lastError == this.lastError &&
          other.nextRetryAtMs == this.nextRetryAtMs);
}

class BangumiSyncQueueCompanion extends UpdateCompanion<BangumiSyncQueueRow> {
  final Value<String> queueKey;
  final Value<int> subjectId;
  final Value<int> seasonNumber;
  final Value<int?> episodeNumber;
  final Value<int> targetStatus;
  final Value<int> enqueuedAtMs;
  final Value<int> retryCount;
  final Value<String?> lastError;
  final Value<int> nextRetryAtMs;
  final Value<int> rowid;
  const BangumiSyncQueueCompanion({
    this.queueKey = const Value.absent(),
    this.subjectId = const Value.absent(),
    this.seasonNumber = const Value.absent(),
    this.episodeNumber = const Value.absent(),
    this.targetStatus = const Value.absent(),
    this.enqueuedAtMs = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.lastError = const Value.absent(),
    this.nextRetryAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BangumiSyncQueueCompanion.insert({
    required String queueKey,
    required int subjectId,
    required int seasonNumber,
    this.episodeNumber = const Value.absent(),
    required int targetStatus,
    required int enqueuedAtMs,
    this.retryCount = const Value.absent(),
    this.lastError = const Value.absent(),
    this.nextRetryAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : queueKey = Value(queueKey),
       subjectId = Value(subjectId),
       seasonNumber = Value(seasonNumber),
       targetStatus = Value(targetStatus),
       enqueuedAtMs = Value(enqueuedAtMs);
  static Insertable<BangumiSyncQueueRow> custom({
    Expression<String>? queueKey,
    Expression<int>? subjectId,
    Expression<int>? seasonNumber,
    Expression<int>? episodeNumber,
    Expression<int>? targetStatus,
    Expression<int>? enqueuedAtMs,
    Expression<int>? retryCount,
    Expression<String>? lastError,
    Expression<int>? nextRetryAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (queueKey != null) 'queue_key': queueKey,
      if (subjectId != null) 'subject_id': subjectId,
      if (seasonNumber != null) 'season_number': seasonNumber,
      if (episodeNumber != null) 'episode_number': episodeNumber,
      if (targetStatus != null) 'target_status': targetStatus,
      if (enqueuedAtMs != null) 'enqueued_at_ms': enqueuedAtMs,
      if (retryCount != null) 'retry_count': retryCount,
      if (lastError != null) 'last_error': lastError,
      if (nextRetryAtMs != null) 'next_retry_at_ms': nextRetryAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BangumiSyncQueueCompanion copyWith({
    Value<String>? queueKey,
    Value<int>? subjectId,
    Value<int>? seasonNumber,
    Value<int?>? episodeNumber,
    Value<int>? targetStatus,
    Value<int>? enqueuedAtMs,
    Value<int>? retryCount,
    Value<String?>? lastError,
    Value<int>? nextRetryAtMs,
    Value<int>? rowid,
  }) {
    return BangumiSyncQueueCompanion(
      queueKey: queueKey ?? this.queueKey,
      subjectId: subjectId ?? this.subjectId,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      targetStatus: targetStatus ?? this.targetStatus,
      enqueuedAtMs: enqueuedAtMs ?? this.enqueuedAtMs,
      retryCount: retryCount ?? this.retryCount,
      lastError: lastError ?? this.lastError,
      nextRetryAtMs: nextRetryAtMs ?? this.nextRetryAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (queueKey.present) {
      map['queue_key'] = Variable<String>(queueKey.value);
    }
    if (subjectId.present) {
      map['subject_id'] = Variable<int>(subjectId.value);
    }
    if (seasonNumber.present) {
      map['season_number'] = Variable<int>(seasonNumber.value);
    }
    if (episodeNumber.present) {
      map['episode_number'] = Variable<int>(episodeNumber.value);
    }
    if (targetStatus.present) {
      map['target_status'] = Variable<int>(targetStatus.value);
    }
    if (enqueuedAtMs.present) {
      map['enqueued_at_ms'] = Variable<int>(enqueuedAtMs.value);
    }
    if (retryCount.present) {
      map['retry_count'] = Variable<int>(retryCount.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (nextRetryAtMs.present) {
      map['next_retry_at_ms'] = Variable<int>(nextRetryAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BangumiSyncQueueCompanion(')
          ..write('queueKey: $queueKey, ')
          ..write('subjectId: $subjectId, ')
          ..write('seasonNumber: $seasonNumber, ')
          ..write('episodeNumber: $episodeNumber, ')
          ..write('targetStatus: $targetStatus, ')
          ..write('enqueuedAtMs: $enqueuedAtMs, ')
          ..write('retryCount: $retryCount, ')
          ..write('lastError: $lastError, ')
          ..write('nextRetryAtMs: $nextRetryAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$KonataDatabase extends GeneratedDatabase {
  _$KonataDatabase(QueryExecutor e) : super(e);
  $KonataDatabaseManager get managers => $KonataDatabaseManager(this);
  late final $MediaSourcesTable mediaSources = $MediaSourcesTable(this);
  late final $WorksTable works = $WorksTable(this);
  late final $EpisodesTable episodes = $EpisodesTable(this);
  late final $MediaVariantsTable mediaVariants = $MediaVariantsTable(this);
  late final $ScrapeCandidatesTable scrapeCandidates = $ScrapeCandidatesTable(
    this,
  );
  late final $PlaybackRecordsTable playbackRecords = $PlaybackRecordsTable(
    this,
  );
  late final $IgnoredFoldersTable ignoredFolders = $IgnoredFoldersTable(this);
  late final $SeriesGroupsTable seriesGroups = $SeriesGroupsTable(this);
  late final $LyricCacheEntriesTable lyricCacheEntries =
      $LyricCacheEntriesTable(this);
  late final $SyncTombstonesTable syncTombstones = $SyncTombstonesTable(this);
  late final $SyncKvMetaTable syncKvMeta = $SyncKvMetaTable(this);
  late final $BangumiSyncQueueTable bangumiSyncQueue = $BangumiSyncQueueTable(
    this,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    mediaSources,
    works,
    episodes,
    mediaVariants,
    scrapeCandidates,
    playbackRecords,
    ignoredFolders,
    seriesGroups,
    lyricCacheEntries,
    syncTombstones,
    syncKvMeta,
    bangumiSyncQueue,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'works',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('episodes', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'works',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('media_variants', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'episodes',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('media_variants', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'media_sources',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('media_variants', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'works',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('scrape_candidates', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'works',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('playback_records', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'media_sources',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('ignored_folders', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$MediaSourcesTableCreateCompanionBuilder =
    MediaSourcesCompanion Function({
      required String id,
      required MediaSourceKind kind,
      required String label,
      required String location,
      Value<String?> username,
      Value<DateTime?> createdAt,
      Value<int> rowid,
    });
typedef $$MediaSourcesTableUpdateCompanionBuilder =
    MediaSourcesCompanion Function({
      Value<String> id,
      Value<MediaSourceKind> kind,
      Value<String> label,
      Value<String> location,
      Value<String?> username,
      Value<DateTime?> createdAt,
      Value<int> rowid,
    });

final class $$MediaSourcesTableReferences
    extends
        BaseReferences<_$KonataDatabase, $MediaSourcesTable, MediaSourceRow> {
  $$MediaSourcesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$MediaVariantsTable, List<MediaVariantRow>>
  _mediaVariantsRefsTable(_$KonataDatabase db) => MultiTypedResultKey.fromTable(
    db.mediaVariants,
    aliasName: 'media_sources__id__media_variants__source_id',
  );

  $$MediaVariantsTableProcessedTableManager get mediaVariantsRefs {
    final manager = $$MediaVariantsTableTableManager(
      $_db,
      $_db.mediaVariants,
    ).filter((f) => f.sourceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_mediaVariantsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$IgnoredFoldersTable, List<IgnoredFolderRow>>
  _ignoredFoldersRefsTable(_$KonataDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.ignoredFolders,
        aliasName: 'media_sources__id__ignored_folders__source_id',
      );

  $$IgnoredFoldersTableProcessedTableManager get ignoredFoldersRefs {
    final manager = $$IgnoredFoldersTableTableManager(
      $_db,
      $_db.ignoredFolders,
    ).filter((f) => f.sourceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_ignoredFoldersRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$MediaSourcesTableFilterComposer
    extends Composer<_$KonataDatabase, $MediaSourcesTable> {
  $$MediaSourcesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<MediaSourceKind, MediaSourceKind, String>
  get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get label => $composableBuilder(
    column: $table.label,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get location => $composableBuilder(
    column: $table.location,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> mediaVariantsRefs(
    Expression<bool> Function($$MediaVariantsTableFilterComposer f) f,
  ) {
    final $$MediaVariantsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.mediaVariants,
      getReferencedColumn: (t) => t.sourceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaVariantsTableFilterComposer(
            $db: $db,
            $table: $db.mediaVariants,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> ignoredFoldersRefs(
    Expression<bool> Function($$IgnoredFoldersTableFilterComposer f) f,
  ) {
    final $$IgnoredFoldersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.ignoredFolders,
      getReferencedColumn: (t) => t.sourceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$IgnoredFoldersTableFilterComposer(
            $db: $db,
            $table: $db.ignoredFolders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MediaSourcesTableOrderingComposer
    extends Composer<_$KonataDatabase, $MediaSourcesTable> {
  $$MediaSourcesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get label => $composableBuilder(
    column: $table.label,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get location => $composableBuilder(
    column: $table.location,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MediaSourcesTableAnnotationComposer
    extends Composer<_$KonataDatabase, $MediaSourcesTable> {
  $$MediaSourcesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumnWithTypeConverter<MediaSourceKind, String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get label =>
      $composableBuilder(column: $table.label, builder: (column) => column);

  GeneratedColumn<String> get location =>
      $composableBuilder(column: $table.location, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  Expression<T> mediaVariantsRefs<T extends Object>(
    Expression<T> Function($$MediaVariantsTableAnnotationComposer a) f,
  ) {
    final $$MediaVariantsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.mediaVariants,
      getReferencedColumn: (t) => t.sourceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaVariantsTableAnnotationComposer(
            $db: $db,
            $table: $db.mediaVariants,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> ignoredFoldersRefs<T extends Object>(
    Expression<T> Function($$IgnoredFoldersTableAnnotationComposer a) f,
  ) {
    final $$IgnoredFoldersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.ignoredFolders,
      getReferencedColumn: (t) => t.sourceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$IgnoredFoldersTableAnnotationComposer(
            $db: $db,
            $table: $db.ignoredFolders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MediaSourcesTableTableManager
    extends
        RootTableManager<
          _$KonataDatabase,
          $MediaSourcesTable,
          MediaSourceRow,
          $$MediaSourcesTableFilterComposer,
          $$MediaSourcesTableOrderingComposer,
          $$MediaSourcesTableAnnotationComposer,
          $$MediaSourcesTableCreateCompanionBuilder,
          $$MediaSourcesTableUpdateCompanionBuilder,
          (MediaSourceRow, $$MediaSourcesTableReferences),
          MediaSourceRow,
          PrefetchHooks Function({
            bool mediaVariantsRefs,
            bool ignoredFoldersRefs,
          })
        > {
  $$MediaSourcesTableTableManager(_$KonataDatabase db, $MediaSourcesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MediaSourcesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MediaSourcesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MediaSourcesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<MediaSourceKind> kind = const Value.absent(),
                Value<String> label = const Value.absent(),
                Value<String> location = const Value.absent(),
                Value<String?> username = const Value.absent(),
                Value<DateTime?> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaSourcesCompanion(
                id: id,
                kind: kind,
                label: label,
                location: location,
                username: username,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required MediaSourceKind kind,
                required String label,
                required String location,
                Value<String?> username = const Value.absent(),
                Value<DateTime?> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaSourcesCompanion.insert(
                id: id,
                kind: kind,
                label: label,
                location: location,
                username: username,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MediaSourcesTable, MediaSourceRow>(table),
                  $$MediaSourcesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({mediaVariantsRefs = false, ignoredFoldersRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (mediaVariantsRefs) db.mediaVariants,
                    if (ignoredFoldersRefs) db.ignoredFolders,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (mediaVariantsRefs)
                        await $_getPrefetchedDataByColumns<
                          MediaSourceRow,
                          $MediaSourcesTable,
                          MediaVariantRow,
                          $MediaVariantsTable
                        >(
                          currentTable: table,
                          referencedTable: $$MediaSourcesTableReferences
                              ._mediaVariantsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MediaSourcesTableReferences(
                                db,
                                table,
                                p0,
                              ).mediaVariantsRefs,
                          currentColumn: 'id',
                          referencedColumn: 'source_id',
                          typedResults: items,
                        ),
                      if (ignoredFoldersRefs)
                        await $_getPrefetchedDataByColumns<
                          MediaSourceRow,
                          $MediaSourcesTable,
                          IgnoredFolderRow,
                          $IgnoredFoldersTable
                        >(
                          currentTable: table,
                          referencedTable: $$MediaSourcesTableReferences
                              ._ignoredFoldersRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MediaSourcesTableReferences(
                                db,
                                table,
                                p0,
                              ).ignoredFoldersRefs,
                          currentColumn: 'id',
                          referencedColumn: 'source_id',
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$MediaSourcesTableProcessedTableManager =
    ProcessedTableManager<
      _$KonataDatabase,
      $MediaSourcesTable,
      MediaSourceRow,
      $$MediaSourcesTableFilterComposer,
      $$MediaSourcesTableOrderingComposer,
      $$MediaSourcesTableAnnotationComposer,
      $$MediaSourcesTableCreateCompanionBuilder,
      $$MediaSourcesTableUpdateCompanionBuilder,
      (MediaSourceRow, $$MediaSourcesTableReferences),
      MediaSourceRow,
      PrefetchHooks Function({bool mediaVariantsRefs, bool ignoredFoldersRefs})
    >;
typedef $$WorksTableCreateCompanionBuilder =
    WorksCompanion Function({
      required String id,
      Value<int?> tmdbId,
      Value<int?> bangumiId,
      Value<int?> tvdbId,
      Value<TmdbMediaType?> tmdbMediaType,
      Value<int?> matchedSeason,
      required String title,
      Value<String?> originalTitle,
      Value<int?> year,
      Value<String?> overview,
      Value<String?> posterPath,
      Value<String?> posterFallback,
      Value<String?> bangumiPosterPath,
      Value<String?> backdropPath,
      Value<String?> logoPath,
      Value<double?> voteAverage,
      Value<double?> bangumiScore,
      Value<int?> folderTmdbHint,
      Value<bool> isManualLocked,
      Value<bool> metadataLocked,
      Value<bool> posterLocked,
      Value<bool> backdropLocked,
      Value<bool> logoLocked,
      Value<DateTime?> logoNegativeUntil,
      Value<int> logoNegativeMask,
      Value<bool> isHidden,
      Value<bool> keepHidden,
      required ScrapeStatus scrapeStatus,
      Value<String?> reviewReason,
      Value<String?> seriesId,
      Value<int?> seriesOrder,
      Value<String?> seriesLabel,
      Value<bool> seriesLocked,
      Value<int> updatedAtMs,
      Value<int> rowid,
    });
typedef $$WorksTableUpdateCompanionBuilder =
    WorksCompanion Function({
      Value<String> id,
      Value<int?> tmdbId,
      Value<int?> bangumiId,
      Value<int?> tvdbId,
      Value<TmdbMediaType?> tmdbMediaType,
      Value<int?> matchedSeason,
      Value<String> title,
      Value<String?> originalTitle,
      Value<int?> year,
      Value<String?> overview,
      Value<String?> posterPath,
      Value<String?> posterFallback,
      Value<String?> bangumiPosterPath,
      Value<String?> backdropPath,
      Value<String?> logoPath,
      Value<double?> voteAverage,
      Value<double?> bangumiScore,
      Value<int?> folderTmdbHint,
      Value<bool> isManualLocked,
      Value<bool> metadataLocked,
      Value<bool> posterLocked,
      Value<bool> backdropLocked,
      Value<bool> logoLocked,
      Value<DateTime?> logoNegativeUntil,
      Value<int> logoNegativeMask,
      Value<bool> isHidden,
      Value<bool> keepHidden,
      Value<ScrapeStatus> scrapeStatus,
      Value<String?> reviewReason,
      Value<String?> seriesId,
      Value<int?> seriesOrder,
      Value<String?> seriesLabel,
      Value<bool> seriesLocked,
      Value<int> updatedAtMs,
      Value<int> rowid,
    });

final class $$WorksTableReferences
    extends BaseReferences<_$KonataDatabase, $WorksTable, WorkRow> {
  $$WorksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$EpisodesTable, List<EpisodeRow>>
  _episodesRefsTable(_$KonataDatabase db) => MultiTypedResultKey.fromTable(
    db.episodes,
    aliasName: 'works__id__episodes__work_id',
  );

  $$EpisodesTableProcessedTableManager get episodesRefs {
    final manager = $$EpisodesTableTableManager(
      $_db,
      $_db.episodes,
    ).filter((f) => f.workId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_episodesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$MediaVariantsTable, List<MediaVariantRow>>
  _mediaVariantsRefsTable(_$KonataDatabase db) => MultiTypedResultKey.fromTable(
    db.mediaVariants,
    aliasName: 'works__id__media_variants__work_id',
  );

  $$MediaVariantsTableProcessedTableManager get mediaVariantsRefs {
    final manager = $$MediaVariantsTableTableManager(
      $_db,
      $_db.mediaVariants,
    ).filter((f) => f.workId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_mediaVariantsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ScrapeCandidatesTable, List<ScrapeCandidateRow>>
  _scrapeCandidatesRefsTable(_$KonataDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.scrapeCandidates,
        aliasName: 'works__id__scrape_candidates__work_id',
      );

  $$ScrapeCandidatesTableProcessedTableManager get scrapeCandidatesRefs {
    final manager = $$ScrapeCandidatesTableTableManager(
      $_db,
      $_db.scrapeCandidates,
    ).filter((f) => f.workId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _scrapeCandidatesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$PlaybackRecordsTable, List<PlaybackRecordRow>>
  _playbackRecordsRefsTable(_$KonataDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.playbackRecords,
        aliasName: 'works__id__playback_records__work_id',
      );

  $$PlaybackRecordsTableProcessedTableManager get playbackRecordsRefs {
    final manager = $$PlaybackRecordsTableTableManager(
      $_db,
      $_db.playbackRecords,
    ).filter((f) => f.workId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _playbackRecordsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$WorksTableFilterComposer
    extends Composer<_$KonataDatabase, $WorksTable> {
  $$WorksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tmdbId => $composableBuilder(
    column: $table.tmdbId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bangumiId => $composableBuilder(
    column: $table.bangumiId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tvdbId => $composableBuilder(
    column: $table.tvdbId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<TmdbMediaType?, TmdbMediaType, String>
  get tmdbMediaType => $composableBuilder(
    column: $table.tmdbMediaType,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<int> get matchedSeason => $composableBuilder(
    column: $table.matchedSeason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get originalTitle => $composableBuilder(
    column: $table.originalTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get overview => $composableBuilder(
    column: $table.overview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get posterPath => $composableBuilder(
    column: $table.posterPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get posterFallback => $composableBuilder(
    column: $table.posterFallback,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bangumiPosterPath => $composableBuilder(
    column: $table.bangumiPosterPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get backdropPath => $composableBuilder(
    column: $table.backdropPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get logoPath => $composableBuilder(
    column: $table.logoPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get voteAverage => $composableBuilder(
    column: $table.voteAverage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get bangumiScore => $composableBuilder(
    column: $table.bangumiScore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get folderTmdbHint => $composableBuilder(
    column: $table.folderTmdbHint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isManualLocked => $composableBuilder(
    column: $table.isManualLocked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get metadataLocked => $composableBuilder(
    column: $table.metadataLocked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get posterLocked => $composableBuilder(
    column: $table.posterLocked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get backdropLocked => $composableBuilder(
    column: $table.backdropLocked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get logoLocked => $composableBuilder(
    column: $table.logoLocked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get logoNegativeUntil => $composableBuilder(
    column: $table.logoNegativeUntil,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get logoNegativeMask => $composableBuilder(
    column: $table.logoNegativeMask,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isHidden => $composableBuilder(
    column: $table.isHidden,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get keepHidden => $composableBuilder(
    column: $table.keepHidden,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<ScrapeStatus, ScrapeStatus, String>
  get scrapeStatus => $composableBuilder(
    column: $table.scrapeStatus,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get reviewReason => $composableBuilder(
    column: $table.reviewReason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get seriesId => $composableBuilder(
    column: $table.seriesId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seriesOrder => $composableBuilder(
    column: $table.seriesOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get seriesLabel => $composableBuilder(
    column: $table.seriesLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get seriesLocked => $composableBuilder(
    column: $table.seriesLocked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> episodesRefs(
    Expression<bool> Function($$EpisodesTableFilterComposer f) f,
  ) {
    final $$EpisodesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.episodes,
      getReferencedColumn: (t) => t.workId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$EpisodesTableFilterComposer(
            $db: $db,
            $table: $db.episodes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> mediaVariantsRefs(
    Expression<bool> Function($$MediaVariantsTableFilterComposer f) f,
  ) {
    final $$MediaVariantsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.mediaVariants,
      getReferencedColumn: (t) => t.workId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaVariantsTableFilterComposer(
            $db: $db,
            $table: $db.mediaVariants,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> scrapeCandidatesRefs(
    Expression<bool> Function($$ScrapeCandidatesTableFilterComposer f) f,
  ) {
    final $$ScrapeCandidatesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scrapeCandidates,
      getReferencedColumn: (t) => t.workId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScrapeCandidatesTableFilterComposer(
            $db: $db,
            $table: $db.scrapeCandidates,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> playbackRecordsRefs(
    Expression<bool> Function($$PlaybackRecordsTableFilterComposer f) f,
  ) {
    final $$PlaybackRecordsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.playbackRecords,
      getReferencedColumn: (t) => t.workId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaybackRecordsTableFilterComposer(
            $db: $db,
            $table: $db.playbackRecords,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$WorksTableOrderingComposer
    extends Composer<_$KonataDatabase, $WorksTable> {
  $$WorksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tmdbId => $composableBuilder(
    column: $table.tmdbId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bangumiId => $composableBuilder(
    column: $table.bangumiId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tvdbId => $composableBuilder(
    column: $table.tvdbId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tmdbMediaType => $composableBuilder(
    column: $table.tmdbMediaType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get matchedSeason => $composableBuilder(
    column: $table.matchedSeason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get originalTitle => $composableBuilder(
    column: $table.originalTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get overview => $composableBuilder(
    column: $table.overview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get posterPath => $composableBuilder(
    column: $table.posterPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get posterFallback => $composableBuilder(
    column: $table.posterFallback,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bangumiPosterPath => $composableBuilder(
    column: $table.bangumiPosterPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get backdropPath => $composableBuilder(
    column: $table.backdropPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get logoPath => $composableBuilder(
    column: $table.logoPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get voteAverage => $composableBuilder(
    column: $table.voteAverage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get bangumiScore => $composableBuilder(
    column: $table.bangumiScore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get folderTmdbHint => $composableBuilder(
    column: $table.folderTmdbHint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isManualLocked => $composableBuilder(
    column: $table.isManualLocked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get metadataLocked => $composableBuilder(
    column: $table.metadataLocked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get posterLocked => $composableBuilder(
    column: $table.posterLocked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get backdropLocked => $composableBuilder(
    column: $table.backdropLocked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get logoLocked => $composableBuilder(
    column: $table.logoLocked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get logoNegativeUntil => $composableBuilder(
    column: $table.logoNegativeUntil,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get logoNegativeMask => $composableBuilder(
    column: $table.logoNegativeMask,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isHidden => $composableBuilder(
    column: $table.isHidden,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get keepHidden => $composableBuilder(
    column: $table.keepHidden,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scrapeStatus => $composableBuilder(
    column: $table.scrapeStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reviewReason => $composableBuilder(
    column: $table.reviewReason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get seriesId => $composableBuilder(
    column: $table.seriesId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seriesOrder => $composableBuilder(
    column: $table.seriesOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get seriesLabel => $composableBuilder(
    column: $table.seriesLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get seriesLocked => $composableBuilder(
    column: $table.seriesLocked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$WorksTableAnnotationComposer
    extends Composer<_$KonataDatabase, $WorksTable> {
  $$WorksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get tmdbId =>
      $composableBuilder(column: $table.tmdbId, builder: (column) => column);

  GeneratedColumn<int> get bangumiId =>
      $composableBuilder(column: $table.bangumiId, builder: (column) => column);

  GeneratedColumn<int> get tvdbId =>
      $composableBuilder(column: $table.tvdbId, builder: (column) => column);

  GeneratedColumnWithTypeConverter<TmdbMediaType?, String> get tmdbMediaType =>
      $composableBuilder(
        column: $table.tmdbMediaType,
        builder: (column) => column,
      );

  GeneratedColumn<int> get matchedSeason => $composableBuilder(
    column: $table.matchedSeason,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get originalTitle => $composableBuilder(
    column: $table.originalTitle,
    builder: (column) => column,
  );

  GeneratedColumn<int> get year =>
      $composableBuilder(column: $table.year, builder: (column) => column);

  GeneratedColumn<String> get overview =>
      $composableBuilder(column: $table.overview, builder: (column) => column);

  GeneratedColumn<String> get posterPath => $composableBuilder(
    column: $table.posterPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get posterFallback => $composableBuilder(
    column: $table.posterFallback,
    builder: (column) => column,
  );

  GeneratedColumn<String> get bangumiPosterPath => $composableBuilder(
    column: $table.bangumiPosterPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get backdropPath => $composableBuilder(
    column: $table.backdropPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get logoPath =>
      $composableBuilder(column: $table.logoPath, builder: (column) => column);

  GeneratedColumn<double> get voteAverage => $composableBuilder(
    column: $table.voteAverage,
    builder: (column) => column,
  );

  GeneratedColumn<double> get bangumiScore => $composableBuilder(
    column: $table.bangumiScore,
    builder: (column) => column,
  );

  GeneratedColumn<int> get folderTmdbHint => $composableBuilder(
    column: $table.folderTmdbHint,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isManualLocked => $composableBuilder(
    column: $table.isManualLocked,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get metadataLocked => $composableBuilder(
    column: $table.metadataLocked,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get posterLocked => $composableBuilder(
    column: $table.posterLocked,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get backdropLocked => $composableBuilder(
    column: $table.backdropLocked,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get logoLocked => $composableBuilder(
    column: $table.logoLocked,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get logoNegativeUntil => $composableBuilder(
    column: $table.logoNegativeUntil,
    builder: (column) => column,
  );

  GeneratedColumn<int> get logoNegativeMask => $composableBuilder(
    column: $table.logoNegativeMask,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isHidden =>
      $composableBuilder(column: $table.isHidden, builder: (column) => column);

  GeneratedColumn<bool> get keepHidden => $composableBuilder(
    column: $table.keepHidden,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<ScrapeStatus, String> get scrapeStatus =>
      $composableBuilder(
        column: $table.scrapeStatus,
        builder: (column) => column,
      );

  GeneratedColumn<String> get reviewReason => $composableBuilder(
    column: $table.reviewReason,
    builder: (column) => column,
  );

  GeneratedColumn<String> get seriesId =>
      $composableBuilder(column: $table.seriesId, builder: (column) => column);

  GeneratedColumn<int> get seriesOrder => $composableBuilder(
    column: $table.seriesOrder,
    builder: (column) => column,
  );

  GeneratedColumn<String> get seriesLabel => $composableBuilder(
    column: $table.seriesLabel,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get seriesLocked => $composableBuilder(
    column: $table.seriesLocked,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => column,
  );

  Expression<T> episodesRefs<T extends Object>(
    Expression<T> Function($$EpisodesTableAnnotationComposer a) f,
  ) {
    final $$EpisodesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.episodes,
      getReferencedColumn: (t) => t.workId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$EpisodesTableAnnotationComposer(
            $db: $db,
            $table: $db.episodes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> mediaVariantsRefs<T extends Object>(
    Expression<T> Function($$MediaVariantsTableAnnotationComposer a) f,
  ) {
    final $$MediaVariantsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.mediaVariants,
      getReferencedColumn: (t) => t.workId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaVariantsTableAnnotationComposer(
            $db: $db,
            $table: $db.mediaVariants,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> scrapeCandidatesRefs<T extends Object>(
    Expression<T> Function($$ScrapeCandidatesTableAnnotationComposer a) f,
  ) {
    final $$ScrapeCandidatesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scrapeCandidates,
      getReferencedColumn: (t) => t.workId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScrapeCandidatesTableAnnotationComposer(
            $db: $db,
            $table: $db.scrapeCandidates,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> playbackRecordsRefs<T extends Object>(
    Expression<T> Function($$PlaybackRecordsTableAnnotationComposer a) f,
  ) {
    final $$PlaybackRecordsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.playbackRecords,
      getReferencedColumn: (t) => t.workId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaybackRecordsTableAnnotationComposer(
            $db: $db,
            $table: $db.playbackRecords,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$WorksTableTableManager
    extends
        RootTableManager<
          _$KonataDatabase,
          $WorksTable,
          WorkRow,
          $$WorksTableFilterComposer,
          $$WorksTableOrderingComposer,
          $$WorksTableAnnotationComposer,
          $$WorksTableCreateCompanionBuilder,
          $$WorksTableUpdateCompanionBuilder,
          (WorkRow, $$WorksTableReferences),
          WorkRow,
          PrefetchHooks Function({
            bool episodesRefs,
            bool mediaVariantsRefs,
            bool scrapeCandidatesRefs,
            bool playbackRecordsRefs,
          })
        > {
  $$WorksTableTableManager(_$KonataDatabase db, $WorksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$WorksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$WorksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$WorksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int?> tmdbId = const Value.absent(),
                Value<int?> bangumiId = const Value.absent(),
                Value<int?> tvdbId = const Value.absent(),
                Value<TmdbMediaType?> tmdbMediaType = const Value.absent(),
                Value<int?> matchedSeason = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> originalTitle = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> overview = const Value.absent(),
                Value<String?> posterPath = const Value.absent(),
                Value<String?> posterFallback = const Value.absent(),
                Value<String?> bangumiPosterPath = const Value.absent(),
                Value<String?> backdropPath = const Value.absent(),
                Value<String?> logoPath = const Value.absent(),
                Value<double?> voteAverage = const Value.absent(),
                Value<double?> bangumiScore = const Value.absent(),
                Value<int?> folderTmdbHint = const Value.absent(),
                Value<bool> isManualLocked = const Value.absent(),
                Value<bool> metadataLocked = const Value.absent(),
                Value<bool> posterLocked = const Value.absent(),
                Value<bool> backdropLocked = const Value.absent(),
                Value<bool> logoLocked = const Value.absent(),
                Value<DateTime?> logoNegativeUntil = const Value.absent(),
                Value<int> logoNegativeMask = const Value.absent(),
                Value<bool> isHidden = const Value.absent(),
                Value<bool> keepHidden = const Value.absent(),
                Value<ScrapeStatus> scrapeStatus = const Value.absent(),
                Value<String?> reviewReason = const Value.absent(),
                Value<String?> seriesId = const Value.absent(),
                Value<int?> seriesOrder = const Value.absent(),
                Value<String?> seriesLabel = const Value.absent(),
                Value<bool> seriesLocked = const Value.absent(),
                Value<int> updatedAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WorksCompanion(
                id: id,
                tmdbId: tmdbId,
                bangumiId: bangumiId,
                tvdbId: tvdbId,
                tmdbMediaType: tmdbMediaType,
                matchedSeason: matchedSeason,
                title: title,
                originalTitle: originalTitle,
                year: year,
                overview: overview,
                posterPath: posterPath,
                posterFallback: posterFallback,
                bangumiPosterPath: bangumiPosterPath,
                backdropPath: backdropPath,
                logoPath: logoPath,
                voteAverage: voteAverage,
                bangumiScore: bangumiScore,
                folderTmdbHint: folderTmdbHint,
                isManualLocked: isManualLocked,
                metadataLocked: metadataLocked,
                posterLocked: posterLocked,
                backdropLocked: backdropLocked,
                logoLocked: logoLocked,
                logoNegativeUntil: logoNegativeUntil,
                logoNegativeMask: logoNegativeMask,
                isHidden: isHidden,
                keepHidden: keepHidden,
                scrapeStatus: scrapeStatus,
                reviewReason: reviewReason,
                seriesId: seriesId,
                seriesOrder: seriesOrder,
                seriesLabel: seriesLabel,
                seriesLocked: seriesLocked,
                updatedAtMs: updatedAtMs,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<int?> tmdbId = const Value.absent(),
                Value<int?> bangumiId = const Value.absent(),
                Value<int?> tvdbId = const Value.absent(),
                Value<TmdbMediaType?> tmdbMediaType = const Value.absent(),
                Value<int?> matchedSeason = const Value.absent(),
                required String title,
                Value<String?> originalTitle = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> overview = const Value.absent(),
                Value<String?> posterPath = const Value.absent(),
                Value<String?> posterFallback = const Value.absent(),
                Value<String?> bangumiPosterPath = const Value.absent(),
                Value<String?> backdropPath = const Value.absent(),
                Value<String?> logoPath = const Value.absent(),
                Value<double?> voteAverage = const Value.absent(),
                Value<double?> bangumiScore = const Value.absent(),
                Value<int?> folderTmdbHint = const Value.absent(),
                Value<bool> isManualLocked = const Value.absent(),
                Value<bool> metadataLocked = const Value.absent(),
                Value<bool> posterLocked = const Value.absent(),
                Value<bool> backdropLocked = const Value.absent(),
                Value<bool> logoLocked = const Value.absent(),
                Value<DateTime?> logoNegativeUntil = const Value.absent(),
                Value<int> logoNegativeMask = const Value.absent(),
                Value<bool> isHidden = const Value.absent(),
                Value<bool> keepHidden = const Value.absent(),
                required ScrapeStatus scrapeStatus,
                Value<String?> reviewReason = const Value.absent(),
                Value<String?> seriesId = const Value.absent(),
                Value<int?> seriesOrder = const Value.absent(),
                Value<String?> seriesLabel = const Value.absent(),
                Value<bool> seriesLocked = const Value.absent(),
                Value<int> updatedAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WorksCompanion.insert(
                id: id,
                tmdbId: tmdbId,
                bangumiId: bangumiId,
                tvdbId: tvdbId,
                tmdbMediaType: tmdbMediaType,
                matchedSeason: matchedSeason,
                title: title,
                originalTitle: originalTitle,
                year: year,
                overview: overview,
                posterPath: posterPath,
                posterFallback: posterFallback,
                bangumiPosterPath: bangumiPosterPath,
                backdropPath: backdropPath,
                logoPath: logoPath,
                voteAverage: voteAverage,
                bangumiScore: bangumiScore,
                folderTmdbHint: folderTmdbHint,
                isManualLocked: isManualLocked,
                metadataLocked: metadataLocked,
                posterLocked: posterLocked,
                backdropLocked: backdropLocked,
                logoLocked: logoLocked,
                logoNegativeUntil: logoNegativeUntil,
                logoNegativeMask: logoNegativeMask,
                isHidden: isHidden,
                keepHidden: keepHidden,
                scrapeStatus: scrapeStatus,
                reviewReason: reviewReason,
                seriesId: seriesId,
                seriesOrder: seriesOrder,
                seriesLabel: seriesLabel,
                seriesLocked: seriesLocked,
                updatedAtMs: updatedAtMs,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$WorksTable, WorkRow>(table),
                  $$WorksTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                episodesRefs = false,
                mediaVariantsRefs = false,
                scrapeCandidatesRefs = false,
                playbackRecordsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (episodesRefs) db.episodes,
                    if (mediaVariantsRefs) db.mediaVariants,
                    if (scrapeCandidatesRefs) db.scrapeCandidates,
                    if (playbackRecordsRefs) db.playbackRecords,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (episodesRefs)
                        await $_getPrefetchedDataByColumns<
                          WorkRow,
                          $WorksTable,
                          EpisodeRow,
                          $EpisodesTable
                        >(
                          currentTable: table,
                          referencedTable: $$WorksTableReferences
                              ._episodesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$WorksTableReferences(
                                db,
                                table,
                                p0,
                              ).episodesRefs,
                          currentColumn: 'id',
                          referencedColumn: 'work_id',
                          typedResults: items,
                        ),
                      if (mediaVariantsRefs)
                        await $_getPrefetchedDataByColumns<
                          WorkRow,
                          $WorksTable,
                          MediaVariantRow,
                          $MediaVariantsTable
                        >(
                          currentTable: table,
                          referencedTable: $$WorksTableReferences
                              ._mediaVariantsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$WorksTableReferences(
                                db,
                                table,
                                p0,
                              ).mediaVariantsRefs,
                          currentColumn: 'id',
                          referencedColumn: 'work_id',
                          typedResults: items,
                        ),
                      if (scrapeCandidatesRefs)
                        await $_getPrefetchedDataByColumns<
                          WorkRow,
                          $WorksTable,
                          ScrapeCandidateRow,
                          $ScrapeCandidatesTable
                        >(
                          currentTable: table,
                          referencedTable: $$WorksTableReferences
                              ._scrapeCandidatesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$WorksTableReferences(
                                db,
                                table,
                                p0,
                              ).scrapeCandidatesRefs,
                          currentColumn: 'id',
                          referencedColumn: 'work_id',
                          typedResults: items,
                        ),
                      if (playbackRecordsRefs)
                        await $_getPrefetchedDataByColumns<
                          WorkRow,
                          $WorksTable,
                          PlaybackRecordRow,
                          $PlaybackRecordsTable
                        >(
                          currentTable: table,
                          referencedTable: $$WorksTableReferences
                              ._playbackRecordsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$WorksTableReferences(
                                db,
                                table,
                                p0,
                              ).playbackRecordsRefs,
                          currentColumn: 'id',
                          referencedColumn: 'work_id',
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$WorksTableProcessedTableManager =
    ProcessedTableManager<
      _$KonataDatabase,
      $WorksTable,
      WorkRow,
      $$WorksTableFilterComposer,
      $$WorksTableOrderingComposer,
      $$WorksTableAnnotationComposer,
      $$WorksTableCreateCompanionBuilder,
      $$WorksTableUpdateCompanionBuilder,
      (WorkRow, $$WorksTableReferences),
      WorkRow,
      PrefetchHooks Function({
        bool episodesRefs,
        bool mediaVariantsRefs,
        bool scrapeCandidatesRefs,
        bool playbackRecordsRefs,
      })
    >;
typedef $$EpisodesTableCreateCompanionBuilder =
    EpisodesCompanion Function({
      required String id,
      required String workId,
      required int seasonNumber,
      Value<int?> episodeNumber,
      Value<int?> episodeNumberEnd,
      required EpisodeCategory category,
      Value<ExtraKind?> extraType,
      Value<String?> title,
      Value<String?> overview,
      Value<String?> stillPath,
      Value<int> rowid,
    });
typedef $$EpisodesTableUpdateCompanionBuilder =
    EpisodesCompanion Function({
      Value<String> id,
      Value<String> workId,
      Value<int> seasonNumber,
      Value<int?> episodeNumber,
      Value<int?> episodeNumberEnd,
      Value<EpisodeCategory> category,
      Value<ExtraKind?> extraType,
      Value<String?> title,
      Value<String?> overview,
      Value<String?> stillPath,
      Value<int> rowid,
    });

final class $$EpisodesTableReferences
    extends BaseReferences<_$KonataDatabase, $EpisodesTable, EpisodeRow> {
  $$EpisodesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $WorksTable _workIdTable(_$KonataDatabase db) =>
      db.works.createAlias('episodes__work_id__works__id');

  $$WorksTableProcessedTableManager get workId {
    final $_column = $_itemColumn<String>('work_id')!;

    final manager = $$WorksTableTableManager(
      $_db,
      $_db.works,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_workIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$MediaVariantsTable, List<MediaVariantRow>>
  _mediaVariantsRefsTable(_$KonataDatabase db) => MultiTypedResultKey.fromTable(
    db.mediaVariants,
    aliasName: 'episodes__id__media_variants__episode_id',
  );

  $$MediaVariantsTableProcessedTableManager get mediaVariantsRefs {
    final manager = $$MediaVariantsTableTableManager(
      $_db,
      $_db.mediaVariants,
    ).filter((f) => f.episodeId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_mediaVariantsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$EpisodesTableFilterComposer
    extends Composer<_$KonataDatabase, $EpisodesTable> {
  $$EpisodesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seasonNumber => $composableBuilder(
    column: $table.seasonNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get episodeNumber => $composableBuilder(
    column: $table.episodeNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get episodeNumberEnd => $composableBuilder(
    column: $table.episodeNumberEnd,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<EpisodeCategory, EpisodeCategory, String>
  get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnWithTypeConverterFilters<ExtraKind?, ExtraKind, String> get extraType =>
      $composableBuilder(
        column: $table.extraType,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get overview => $composableBuilder(
    column: $table.overview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stillPath => $composableBuilder(
    column: $table.stillPath,
    builder: (column) => ColumnFilters(column),
  );

  $$WorksTableFilterComposer get workId {
    final $$WorksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.workId,
      referencedTable: $db.works,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorksTableFilterComposer(
            $db: $db,
            $table: $db.works,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> mediaVariantsRefs(
    Expression<bool> Function($$MediaVariantsTableFilterComposer f) f,
  ) {
    final $$MediaVariantsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.mediaVariants,
      getReferencedColumn: (t) => t.episodeId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaVariantsTableFilterComposer(
            $db: $db,
            $table: $db.mediaVariants,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$EpisodesTableOrderingComposer
    extends Composer<_$KonataDatabase, $EpisodesTable> {
  $$EpisodesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seasonNumber => $composableBuilder(
    column: $table.seasonNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get episodeNumber => $composableBuilder(
    column: $table.episodeNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get episodeNumberEnd => $composableBuilder(
    column: $table.episodeNumberEnd,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extraType => $composableBuilder(
    column: $table.extraType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get overview => $composableBuilder(
    column: $table.overview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stillPath => $composableBuilder(
    column: $table.stillPath,
    builder: (column) => ColumnOrderings(column),
  );

  $$WorksTableOrderingComposer get workId {
    final $$WorksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.workId,
      referencedTable: $db.works,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorksTableOrderingComposer(
            $db: $db,
            $table: $db.works,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$EpisodesTableAnnotationComposer
    extends Composer<_$KonataDatabase, $EpisodesTable> {
  $$EpisodesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get seasonNumber => $composableBuilder(
    column: $table.seasonNumber,
    builder: (column) => column,
  );

  GeneratedColumn<int> get episodeNumber => $composableBuilder(
    column: $table.episodeNumber,
    builder: (column) => column,
  );

  GeneratedColumn<int> get episodeNumberEnd => $composableBuilder(
    column: $table.episodeNumberEnd,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<EpisodeCategory, String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumnWithTypeConverter<ExtraKind?, String> get extraType =>
      $composableBuilder(column: $table.extraType, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get overview =>
      $composableBuilder(column: $table.overview, builder: (column) => column);

  GeneratedColumn<String> get stillPath =>
      $composableBuilder(column: $table.stillPath, builder: (column) => column);

  $$WorksTableAnnotationComposer get workId {
    final $$WorksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.workId,
      referencedTable: $db.works,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorksTableAnnotationComposer(
            $db: $db,
            $table: $db.works,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> mediaVariantsRefs<T extends Object>(
    Expression<T> Function($$MediaVariantsTableAnnotationComposer a) f,
  ) {
    final $$MediaVariantsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.mediaVariants,
      getReferencedColumn: (t) => t.episodeId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaVariantsTableAnnotationComposer(
            $db: $db,
            $table: $db.mediaVariants,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$EpisodesTableTableManager
    extends
        RootTableManager<
          _$KonataDatabase,
          $EpisodesTable,
          EpisodeRow,
          $$EpisodesTableFilterComposer,
          $$EpisodesTableOrderingComposer,
          $$EpisodesTableAnnotationComposer,
          $$EpisodesTableCreateCompanionBuilder,
          $$EpisodesTableUpdateCompanionBuilder,
          (EpisodeRow, $$EpisodesTableReferences),
          EpisodeRow,
          PrefetchHooks Function({bool workId, bool mediaVariantsRefs})
        > {
  $$EpisodesTableTableManager(_$KonataDatabase db, $EpisodesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EpisodesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$EpisodesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EpisodesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> workId = const Value.absent(),
                Value<int> seasonNumber = const Value.absent(),
                Value<int?> episodeNumber = const Value.absent(),
                Value<int?> episodeNumberEnd = const Value.absent(),
                Value<EpisodeCategory> category = const Value.absent(),
                Value<ExtraKind?> extraType = const Value.absent(),
                Value<String?> title = const Value.absent(),
                Value<String?> overview = const Value.absent(),
                Value<String?> stillPath = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EpisodesCompanion(
                id: id,
                workId: workId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                episodeNumberEnd: episodeNumberEnd,
                category: category,
                extraType: extraType,
                title: title,
                overview: overview,
                stillPath: stillPath,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String workId,
                required int seasonNumber,
                Value<int?> episodeNumber = const Value.absent(),
                Value<int?> episodeNumberEnd = const Value.absent(),
                required EpisodeCategory category,
                Value<ExtraKind?> extraType = const Value.absent(),
                Value<String?> title = const Value.absent(),
                Value<String?> overview = const Value.absent(),
                Value<String?> stillPath = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EpisodesCompanion.insert(
                id: id,
                workId: workId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                episodeNumberEnd: episodeNumberEnd,
                category: category,
                extraType: extraType,
                title: title,
                overview: overview,
                stillPath: stillPath,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$EpisodesTable, EpisodeRow>(table),
                  $$EpisodesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({workId = false, mediaVariantsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (mediaVariantsRefs) db.mediaVariants,
              ],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (workId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.workId,
                                referencedTable: $$EpisodesTableReferences
                                    ._workIdTable(db),
                                referencedColumn: $$EpisodesTableReferences
                                    ._workIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (mediaVariantsRefs)
                    await $_getPrefetchedDataByColumns<
                      EpisodeRow,
                      $EpisodesTable,
                      MediaVariantRow,
                      $MediaVariantsTable
                    >(
                      currentTable: table,
                      referencedTable: $$EpisodesTableReferences
                          ._mediaVariantsRefsTable(db),
                      managerFromTypedResult: (p0) => $$EpisodesTableReferences(
                        db,
                        table,
                        p0,
                      ).mediaVariantsRefs,
                      currentColumn: 'id',
                      referencedColumn: 'episode_id',
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$EpisodesTableProcessedTableManager =
    ProcessedTableManager<
      _$KonataDatabase,
      $EpisodesTable,
      EpisodeRow,
      $$EpisodesTableFilterComposer,
      $$EpisodesTableOrderingComposer,
      $$EpisodesTableAnnotationComposer,
      $$EpisodesTableCreateCompanionBuilder,
      $$EpisodesTableUpdateCompanionBuilder,
      (EpisodeRow, $$EpisodesTableReferences),
      EpisodeRow,
      PrefetchHooks Function({bool workId, bool mediaVariantsRefs})
    >;
typedef $$MediaVariantsTableCreateCompanionBuilder =
    MediaVariantsCompanion Function({
      required String id,
      required String workId,
      Value<String?> episodeId,
      required String sourceId,
      required String relativePath,
      required String fileName,
      required int fileSize,
      required AssetKind assetKind,
      Value<String?> releaseGroup,
      Value<String?> subtitleGroup,
      Value<String?> videoCodec,
      Value<String?> bitDepth,
      Value<String?> resolution,
      Value<String?> audioCodec,
      Value<String> externalSubtitlesJson,
      Value<bool> mappingLocked,
      Value<bool> workLocked,
      Value<SupplementaryAssetScope> assetScope,
      Value<bool> scopeLocked,
      Value<int> rowid,
    });
typedef $$MediaVariantsTableUpdateCompanionBuilder =
    MediaVariantsCompanion Function({
      Value<String> id,
      Value<String> workId,
      Value<String?> episodeId,
      Value<String> sourceId,
      Value<String> relativePath,
      Value<String> fileName,
      Value<int> fileSize,
      Value<AssetKind> assetKind,
      Value<String?> releaseGroup,
      Value<String?> subtitleGroup,
      Value<String?> videoCodec,
      Value<String?> bitDepth,
      Value<String?> resolution,
      Value<String?> audioCodec,
      Value<String> externalSubtitlesJson,
      Value<bool> mappingLocked,
      Value<bool> workLocked,
      Value<SupplementaryAssetScope> assetScope,
      Value<bool> scopeLocked,
      Value<int> rowid,
    });

final class $$MediaVariantsTableReferences
    extends
        BaseReferences<_$KonataDatabase, $MediaVariantsTable, MediaVariantRow> {
  $$MediaVariantsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $WorksTable _workIdTable(_$KonataDatabase db) =>
      db.works.createAlias('media_variants__work_id__works__id');

  $$WorksTableProcessedTableManager get workId {
    final $_column = $_itemColumn<String>('work_id')!;

    final manager = $$WorksTableTableManager(
      $_db,
      $_db.works,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_workIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $EpisodesTable _episodeIdTable(_$KonataDatabase db) =>
      db.episodes.createAlias('media_variants__episode_id__episodes__id');

  $$EpisodesTableProcessedTableManager? get episodeId {
    final $_column = $_itemColumn<String>('episode_id');
    if ($_column == null) return null;
    final manager = $$EpisodesTableTableManager(
      $_db,
      $_db.episodes,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_episodeIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $MediaSourcesTable _sourceIdTable(_$KonataDatabase db) => db
      .mediaSources
      .createAlias('media_variants__source_id__media_sources__id');

  $$MediaSourcesTableProcessedTableManager get sourceId {
    final $_column = $_itemColumn<String>('source_id')!;

    final manager = $$MediaSourcesTableTableManager(
      $_db,
      $_db.mediaSources,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_sourceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$MediaVariantsTableFilterComposer
    extends Composer<_$KonataDatabase, $MediaVariantsTable> {
  $$MediaVariantsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get fileSize => $composableBuilder(
    column: $table.fileSize,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<AssetKind, AssetKind, String> get assetKind =>
      $composableBuilder(
        column: $table.assetKind,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get releaseGroup => $composableBuilder(
    column: $table.releaseGroup,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get subtitleGroup => $composableBuilder(
    column: $table.subtitleGroup,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get videoCodec => $composableBuilder(
    column: $table.videoCodec,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bitDepth => $composableBuilder(
    column: $table.bitDepth,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resolution => $composableBuilder(
    column: $table.resolution,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get audioCodec => $composableBuilder(
    column: $table.audioCodec,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get externalSubtitlesJson => $composableBuilder(
    column: $table.externalSubtitlesJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get mappingLocked => $composableBuilder(
    column: $table.mappingLocked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get workLocked => $composableBuilder(
    column: $table.workLocked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<
    SupplementaryAssetScope,
    SupplementaryAssetScope,
    String
  >
  get assetScope => $composableBuilder(
    column: $table.assetScope,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<bool> get scopeLocked => $composableBuilder(
    column: $table.scopeLocked,
    builder: (column) => ColumnFilters(column),
  );

  $$WorksTableFilterComposer get workId {
    final $$WorksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.workId,
      referencedTable: $db.works,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorksTableFilterComposer(
            $db: $db,
            $table: $db.works,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$EpisodesTableFilterComposer get episodeId {
    final $$EpisodesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.episodeId,
      referencedTable: $db.episodes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$EpisodesTableFilterComposer(
            $db: $db,
            $table: $db.episodes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$MediaSourcesTableFilterComposer get sourceId {
    final $$MediaSourcesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sourceId,
      referencedTable: $db.mediaSources,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaSourcesTableFilterComposer(
            $db: $db,
            $table: $db.mediaSources,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MediaVariantsTableOrderingComposer
    extends Composer<_$KonataDatabase, $MediaVariantsTable> {
  $$MediaVariantsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get fileSize => $composableBuilder(
    column: $table.fileSize,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get assetKind => $composableBuilder(
    column: $table.assetKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get releaseGroup => $composableBuilder(
    column: $table.releaseGroup,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get subtitleGroup => $composableBuilder(
    column: $table.subtitleGroup,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get videoCodec => $composableBuilder(
    column: $table.videoCodec,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bitDepth => $composableBuilder(
    column: $table.bitDepth,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resolution => $composableBuilder(
    column: $table.resolution,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get audioCodec => $composableBuilder(
    column: $table.audioCodec,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get externalSubtitlesJson => $composableBuilder(
    column: $table.externalSubtitlesJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get mappingLocked => $composableBuilder(
    column: $table.mappingLocked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get workLocked => $composableBuilder(
    column: $table.workLocked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get assetScope => $composableBuilder(
    column: $table.assetScope,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get scopeLocked => $composableBuilder(
    column: $table.scopeLocked,
    builder: (column) => ColumnOrderings(column),
  );

  $$WorksTableOrderingComposer get workId {
    final $$WorksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.workId,
      referencedTable: $db.works,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorksTableOrderingComposer(
            $db: $db,
            $table: $db.works,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$EpisodesTableOrderingComposer get episodeId {
    final $$EpisodesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.episodeId,
      referencedTable: $db.episodes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$EpisodesTableOrderingComposer(
            $db: $db,
            $table: $db.episodes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$MediaSourcesTableOrderingComposer get sourceId {
    final $$MediaSourcesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sourceId,
      referencedTable: $db.mediaSources,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaSourcesTableOrderingComposer(
            $db: $db,
            $table: $db.mediaSources,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MediaVariantsTableAnnotationComposer
    extends Composer<_$KonataDatabase, $MediaVariantsTable> {
  $$MediaVariantsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<int> get fileSize =>
      $composableBuilder(column: $table.fileSize, builder: (column) => column);

  GeneratedColumnWithTypeConverter<AssetKind, String> get assetKind =>
      $composableBuilder(column: $table.assetKind, builder: (column) => column);

  GeneratedColumn<String> get releaseGroup => $composableBuilder(
    column: $table.releaseGroup,
    builder: (column) => column,
  );

  GeneratedColumn<String> get subtitleGroup => $composableBuilder(
    column: $table.subtitleGroup,
    builder: (column) => column,
  );

  GeneratedColumn<String> get videoCodec => $composableBuilder(
    column: $table.videoCodec,
    builder: (column) => column,
  );

  GeneratedColumn<String> get bitDepth =>
      $composableBuilder(column: $table.bitDepth, builder: (column) => column);

  GeneratedColumn<String> get resolution => $composableBuilder(
    column: $table.resolution,
    builder: (column) => column,
  );

  GeneratedColumn<String> get audioCodec => $composableBuilder(
    column: $table.audioCodec,
    builder: (column) => column,
  );

  GeneratedColumn<String> get externalSubtitlesJson => $composableBuilder(
    column: $table.externalSubtitlesJson,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get mappingLocked => $composableBuilder(
    column: $table.mappingLocked,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get workLocked => $composableBuilder(
    column: $table.workLocked,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<SupplementaryAssetScope, String>
  get assetScope => $composableBuilder(
    column: $table.assetScope,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get scopeLocked => $composableBuilder(
    column: $table.scopeLocked,
    builder: (column) => column,
  );

  $$WorksTableAnnotationComposer get workId {
    final $$WorksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.workId,
      referencedTable: $db.works,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorksTableAnnotationComposer(
            $db: $db,
            $table: $db.works,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$EpisodesTableAnnotationComposer get episodeId {
    final $$EpisodesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.episodeId,
      referencedTable: $db.episodes,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$EpisodesTableAnnotationComposer(
            $db: $db,
            $table: $db.episodes,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$MediaSourcesTableAnnotationComposer get sourceId {
    final $$MediaSourcesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sourceId,
      referencedTable: $db.mediaSources,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaSourcesTableAnnotationComposer(
            $db: $db,
            $table: $db.mediaSources,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MediaVariantsTableTableManager
    extends
        RootTableManager<
          _$KonataDatabase,
          $MediaVariantsTable,
          MediaVariantRow,
          $$MediaVariantsTableFilterComposer,
          $$MediaVariantsTableOrderingComposer,
          $$MediaVariantsTableAnnotationComposer,
          $$MediaVariantsTableCreateCompanionBuilder,
          $$MediaVariantsTableUpdateCompanionBuilder,
          (MediaVariantRow, $$MediaVariantsTableReferences),
          MediaVariantRow,
          PrefetchHooks Function({bool workId, bool episodeId, bool sourceId})
        > {
  $$MediaVariantsTableTableManager(
    _$KonataDatabase db,
    $MediaVariantsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MediaVariantsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MediaVariantsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MediaVariantsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> workId = const Value.absent(),
                Value<String?> episodeId = const Value.absent(),
                Value<String> sourceId = const Value.absent(),
                Value<String> relativePath = const Value.absent(),
                Value<String> fileName = const Value.absent(),
                Value<int> fileSize = const Value.absent(),
                Value<AssetKind> assetKind = const Value.absent(),
                Value<String?> releaseGroup = const Value.absent(),
                Value<String?> subtitleGroup = const Value.absent(),
                Value<String?> videoCodec = const Value.absent(),
                Value<String?> bitDepth = const Value.absent(),
                Value<String?> resolution = const Value.absent(),
                Value<String?> audioCodec = const Value.absent(),
                Value<String> externalSubtitlesJson = const Value.absent(),
                Value<bool> mappingLocked = const Value.absent(),
                Value<bool> workLocked = const Value.absent(),
                Value<SupplementaryAssetScope> assetScope =
                    const Value.absent(),
                Value<bool> scopeLocked = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaVariantsCompanion(
                id: id,
                workId: workId,
                episodeId: episodeId,
                sourceId: sourceId,
                relativePath: relativePath,
                fileName: fileName,
                fileSize: fileSize,
                assetKind: assetKind,
                releaseGroup: releaseGroup,
                subtitleGroup: subtitleGroup,
                videoCodec: videoCodec,
                bitDepth: bitDepth,
                resolution: resolution,
                audioCodec: audioCodec,
                externalSubtitlesJson: externalSubtitlesJson,
                mappingLocked: mappingLocked,
                workLocked: workLocked,
                assetScope: assetScope,
                scopeLocked: scopeLocked,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String workId,
                Value<String?> episodeId = const Value.absent(),
                required String sourceId,
                required String relativePath,
                required String fileName,
                required int fileSize,
                required AssetKind assetKind,
                Value<String?> releaseGroup = const Value.absent(),
                Value<String?> subtitleGroup = const Value.absent(),
                Value<String?> videoCodec = const Value.absent(),
                Value<String?> bitDepth = const Value.absent(),
                Value<String?> resolution = const Value.absent(),
                Value<String?> audioCodec = const Value.absent(),
                Value<String> externalSubtitlesJson = const Value.absent(),
                Value<bool> mappingLocked = const Value.absent(),
                Value<bool> workLocked = const Value.absent(),
                Value<SupplementaryAssetScope> assetScope =
                    const Value.absent(),
                Value<bool> scopeLocked = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaVariantsCompanion.insert(
                id: id,
                workId: workId,
                episodeId: episodeId,
                sourceId: sourceId,
                relativePath: relativePath,
                fileName: fileName,
                fileSize: fileSize,
                assetKind: assetKind,
                releaseGroup: releaseGroup,
                subtitleGroup: subtitleGroup,
                videoCodec: videoCodec,
                bitDepth: bitDepth,
                resolution: resolution,
                audioCodec: audioCodec,
                externalSubtitlesJson: externalSubtitlesJson,
                mappingLocked: mappingLocked,
                workLocked: workLocked,
                assetScope: assetScope,
                scopeLocked: scopeLocked,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MediaVariantsTable, MediaVariantRow>(table),
                  $$MediaVariantsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({workId = false, episodeId = false, sourceId = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (workId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.workId,
                                    referencedTable:
                                        $$MediaVariantsTableReferences
                                            ._workIdTable(db),
                                    referencedColumn:
                                        $$MediaVariantsTableReferences
                                            ._workIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (episodeId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.episodeId,
                                    referencedTable:
                                        $$MediaVariantsTableReferences
                                            ._episodeIdTable(db),
                                    referencedColumn:
                                        $$MediaVariantsTableReferences
                                            ._episodeIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (sourceId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.sourceId,
                                    referencedTable:
                                        $$MediaVariantsTableReferences
                                            ._sourceIdTable(db),
                                    referencedColumn:
                                        $$MediaVariantsTableReferences
                                            ._sourceIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [];
                  },
                );
              },
        ),
      );
}

typedef $$MediaVariantsTableProcessedTableManager =
    ProcessedTableManager<
      _$KonataDatabase,
      $MediaVariantsTable,
      MediaVariantRow,
      $$MediaVariantsTableFilterComposer,
      $$MediaVariantsTableOrderingComposer,
      $$MediaVariantsTableAnnotationComposer,
      $$MediaVariantsTableCreateCompanionBuilder,
      $$MediaVariantsTableUpdateCompanionBuilder,
      (MediaVariantRow, $$MediaVariantsTableReferences),
      MediaVariantRow,
      PrefetchHooks Function({bool workId, bool episodeId, bool sourceId})
    >;
typedef $$ScrapeCandidatesTableCreateCompanionBuilder =
    ScrapeCandidatesCompanion Function({
      required String workId,
      required int rank,
      required int tmdbId,
      required TmdbMediaType mediaType,
      required String title,
      Value<String?> originalTitle,
      Value<int?> year,
      Value<String?> posterPath,
      required double score,
      Value<String> reasonsJson,
      Value<int?> episodeCount,
      Value<int> rowid,
    });
typedef $$ScrapeCandidatesTableUpdateCompanionBuilder =
    ScrapeCandidatesCompanion Function({
      Value<String> workId,
      Value<int> rank,
      Value<int> tmdbId,
      Value<TmdbMediaType> mediaType,
      Value<String> title,
      Value<String?> originalTitle,
      Value<int?> year,
      Value<String?> posterPath,
      Value<double> score,
      Value<String> reasonsJson,
      Value<int?> episodeCount,
      Value<int> rowid,
    });

final class $$ScrapeCandidatesTableReferences
    extends
        BaseReferences<
          _$KonataDatabase,
          $ScrapeCandidatesTable,
          ScrapeCandidateRow
        > {
  $$ScrapeCandidatesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $WorksTable _workIdTable(_$KonataDatabase db) =>
      db.works.createAlias('scrape_candidates__work_id__works__id');

  $$WorksTableProcessedTableManager get workId {
    final $_column = $_itemColumn<String>('work_id')!;

    final manager = $$WorksTableTableManager(
      $_db,
      $_db.works,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_workIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ScrapeCandidatesTableFilterComposer
    extends Composer<_$KonataDatabase, $ScrapeCandidatesTable> {
  $$ScrapeCandidatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get rank => $composableBuilder(
    column: $table.rank,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tmdbId => $composableBuilder(
    column: $table.tmdbId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<TmdbMediaType, TmdbMediaType, String>
  get mediaType => $composableBuilder(
    column: $table.mediaType,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get originalTitle => $composableBuilder(
    column: $table.originalTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get posterPath => $composableBuilder(
    column: $table.posterPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get score => $composableBuilder(
    column: $table.score,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reasonsJson => $composableBuilder(
    column: $table.reasonsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get episodeCount => $composableBuilder(
    column: $table.episodeCount,
    builder: (column) => ColumnFilters(column),
  );

  $$WorksTableFilterComposer get workId {
    final $$WorksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.workId,
      referencedTable: $db.works,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorksTableFilterComposer(
            $db: $db,
            $table: $db.works,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScrapeCandidatesTableOrderingComposer
    extends Composer<_$KonataDatabase, $ScrapeCandidatesTable> {
  $$ScrapeCandidatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get rank => $composableBuilder(
    column: $table.rank,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tmdbId => $composableBuilder(
    column: $table.tmdbId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mediaType => $composableBuilder(
    column: $table.mediaType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get originalTitle => $composableBuilder(
    column: $table.originalTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get posterPath => $composableBuilder(
    column: $table.posterPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get score => $composableBuilder(
    column: $table.score,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reasonsJson => $composableBuilder(
    column: $table.reasonsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get episodeCount => $composableBuilder(
    column: $table.episodeCount,
    builder: (column) => ColumnOrderings(column),
  );

  $$WorksTableOrderingComposer get workId {
    final $$WorksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.workId,
      referencedTable: $db.works,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorksTableOrderingComposer(
            $db: $db,
            $table: $db.works,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScrapeCandidatesTableAnnotationComposer
    extends Composer<_$KonataDatabase, $ScrapeCandidatesTable> {
  $$ScrapeCandidatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get rank =>
      $composableBuilder(column: $table.rank, builder: (column) => column);

  GeneratedColumn<int> get tmdbId =>
      $composableBuilder(column: $table.tmdbId, builder: (column) => column);

  GeneratedColumnWithTypeConverter<TmdbMediaType, String> get mediaType =>
      $composableBuilder(column: $table.mediaType, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get originalTitle => $composableBuilder(
    column: $table.originalTitle,
    builder: (column) => column,
  );

  GeneratedColumn<int> get year =>
      $composableBuilder(column: $table.year, builder: (column) => column);

  GeneratedColumn<String> get posterPath => $composableBuilder(
    column: $table.posterPath,
    builder: (column) => column,
  );

  GeneratedColumn<double> get score =>
      $composableBuilder(column: $table.score, builder: (column) => column);

  GeneratedColumn<String> get reasonsJson => $composableBuilder(
    column: $table.reasonsJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get episodeCount => $composableBuilder(
    column: $table.episodeCount,
    builder: (column) => column,
  );

  $$WorksTableAnnotationComposer get workId {
    final $$WorksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.workId,
      referencedTable: $db.works,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorksTableAnnotationComposer(
            $db: $db,
            $table: $db.works,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScrapeCandidatesTableTableManager
    extends
        RootTableManager<
          _$KonataDatabase,
          $ScrapeCandidatesTable,
          ScrapeCandidateRow,
          $$ScrapeCandidatesTableFilterComposer,
          $$ScrapeCandidatesTableOrderingComposer,
          $$ScrapeCandidatesTableAnnotationComposer,
          $$ScrapeCandidatesTableCreateCompanionBuilder,
          $$ScrapeCandidatesTableUpdateCompanionBuilder,
          (ScrapeCandidateRow, $$ScrapeCandidatesTableReferences),
          ScrapeCandidateRow,
          PrefetchHooks Function({bool workId})
        > {
  $$ScrapeCandidatesTableTableManager(
    _$KonataDatabase db,
    $ScrapeCandidatesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ScrapeCandidatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ScrapeCandidatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ScrapeCandidatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> workId = const Value.absent(),
                Value<int> rank = const Value.absent(),
                Value<int> tmdbId = const Value.absent(),
                Value<TmdbMediaType> mediaType = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> originalTitle = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> posterPath = const Value.absent(),
                Value<double> score = const Value.absent(),
                Value<String> reasonsJson = const Value.absent(),
                Value<int?> episodeCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ScrapeCandidatesCompanion(
                workId: workId,
                rank: rank,
                tmdbId: tmdbId,
                mediaType: mediaType,
                title: title,
                originalTitle: originalTitle,
                year: year,
                posterPath: posterPath,
                score: score,
                reasonsJson: reasonsJson,
                episodeCount: episodeCount,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String workId,
                required int rank,
                required int tmdbId,
                required TmdbMediaType mediaType,
                required String title,
                Value<String?> originalTitle = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> posterPath = const Value.absent(),
                required double score,
                Value<String> reasonsJson = const Value.absent(),
                Value<int?> episodeCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ScrapeCandidatesCompanion.insert(
                workId: workId,
                rank: rank,
                tmdbId: tmdbId,
                mediaType: mediaType,
                title: title,
                originalTitle: originalTitle,
                year: year,
                posterPath: posterPath,
                score: score,
                reasonsJson: reasonsJson,
                episodeCount: episodeCount,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ScrapeCandidatesTable, ScrapeCandidateRow>(
                    table,
                  ),
                  $$ScrapeCandidatesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({workId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (workId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.workId,
                                referencedTable:
                                    $$ScrapeCandidatesTableReferences
                                        ._workIdTable(db),
                                referencedColumn:
                                    $$ScrapeCandidatesTableReferences
                                        ._workIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ScrapeCandidatesTableProcessedTableManager =
    ProcessedTableManager<
      _$KonataDatabase,
      $ScrapeCandidatesTable,
      ScrapeCandidateRow,
      $$ScrapeCandidatesTableFilterComposer,
      $$ScrapeCandidatesTableOrderingComposer,
      $$ScrapeCandidatesTableAnnotationComposer,
      $$ScrapeCandidatesTableCreateCompanionBuilder,
      $$ScrapeCandidatesTableUpdateCompanionBuilder,
      (ScrapeCandidateRow, $$ScrapeCandidatesTableReferences),
      ScrapeCandidateRow,
      PrefetchHooks Function({bool workId})
    >;
typedef $$PlaybackRecordsTableCreateCompanionBuilder =
    PlaybackRecordsCompanion Function({
      required String id,
      required String workId,
      required String episodeId,
      required String variantId,
      required int seasonNumber,
      Value<int?> episodeNumber,
      required String episodeTitle,
      required MediaSourceKind sourceType,
      required DateTime playedAt,
      Value<int> positionSeconds,
      Value<int> durationSeconds,
      Value<bool> isCompleted,
      Value<int> updatedAtMs,
      Value<int> rowid,
    });
typedef $$PlaybackRecordsTableUpdateCompanionBuilder =
    PlaybackRecordsCompanion Function({
      Value<String> id,
      Value<String> workId,
      Value<String> episodeId,
      Value<String> variantId,
      Value<int> seasonNumber,
      Value<int?> episodeNumber,
      Value<String> episodeTitle,
      Value<MediaSourceKind> sourceType,
      Value<DateTime> playedAt,
      Value<int> positionSeconds,
      Value<int> durationSeconds,
      Value<bool> isCompleted,
      Value<int> updatedAtMs,
      Value<int> rowid,
    });

final class $$PlaybackRecordsTableReferences
    extends
        BaseReferences<
          _$KonataDatabase,
          $PlaybackRecordsTable,
          PlaybackRecordRow
        > {
  $$PlaybackRecordsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $WorksTable _workIdTable(_$KonataDatabase db) =>
      db.works.createAlias('playback_records__work_id__works__id');

  $$WorksTableProcessedTableManager get workId {
    final $_column = $_itemColumn<String>('work_id')!;

    final manager = $$WorksTableTableManager(
      $_db,
      $_db.works,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_workIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$PlaybackRecordsTableFilterComposer
    extends Composer<_$KonataDatabase, $PlaybackRecordsTable> {
  $$PlaybackRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get episodeId => $composableBuilder(
    column: $table.episodeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seasonNumber => $composableBuilder(
    column: $table.seasonNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get episodeNumber => $composableBuilder(
    column: $table.episodeNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get episodeTitle => $composableBuilder(
    column: $table.episodeTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<MediaSourceKind, MediaSourceKind, String>
  get sourceType => $composableBuilder(
    column: $table.sourceType,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<DateTime> get playedAt => $composableBuilder(
    column: $table.playedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get positionSeconds => $composableBuilder(
    column: $table.positionSeconds,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isCompleted => $composableBuilder(
    column: $table.isCompleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  $$WorksTableFilterComposer get workId {
    final $$WorksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.workId,
      referencedTable: $db.works,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorksTableFilterComposer(
            $db: $db,
            $table: $db.works,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlaybackRecordsTableOrderingComposer
    extends Composer<_$KonataDatabase, $PlaybackRecordsTable> {
  $$PlaybackRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get episodeId => $composableBuilder(
    column: $table.episodeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get variantId => $composableBuilder(
    column: $table.variantId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seasonNumber => $composableBuilder(
    column: $table.seasonNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get episodeNumber => $composableBuilder(
    column: $table.episodeNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get episodeTitle => $composableBuilder(
    column: $table.episodeTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceType => $composableBuilder(
    column: $table.sourceType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get playedAt => $composableBuilder(
    column: $table.playedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get positionSeconds => $composableBuilder(
    column: $table.positionSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isCompleted => $composableBuilder(
    column: $table.isCompleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  $$WorksTableOrderingComposer get workId {
    final $$WorksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.workId,
      referencedTable: $db.works,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorksTableOrderingComposer(
            $db: $db,
            $table: $db.works,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlaybackRecordsTableAnnotationComposer
    extends Composer<_$KonataDatabase, $PlaybackRecordsTable> {
  $$PlaybackRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get episodeId =>
      $composableBuilder(column: $table.episodeId, builder: (column) => column);

  GeneratedColumn<String> get variantId =>
      $composableBuilder(column: $table.variantId, builder: (column) => column);

  GeneratedColumn<int> get seasonNumber => $composableBuilder(
    column: $table.seasonNumber,
    builder: (column) => column,
  );

  GeneratedColumn<int> get episodeNumber => $composableBuilder(
    column: $table.episodeNumber,
    builder: (column) => column,
  );

  GeneratedColumn<String> get episodeTitle => $composableBuilder(
    column: $table.episodeTitle,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<MediaSourceKind, String> get sourceType =>
      $composableBuilder(
        column: $table.sourceType,
        builder: (column) => column,
      );

  GeneratedColumn<DateTime> get playedAt =>
      $composableBuilder(column: $table.playedAt, builder: (column) => column);

  GeneratedColumn<int> get positionSeconds => $composableBuilder(
    column: $table.positionSeconds,
    builder: (column) => column,
  );

  GeneratedColumn<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isCompleted => $composableBuilder(
    column: $table.isCompleted,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => column,
  );

  $$WorksTableAnnotationComposer get workId {
    final $$WorksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.workId,
      referencedTable: $db.works,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorksTableAnnotationComposer(
            $db: $db,
            $table: $db.works,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlaybackRecordsTableTableManager
    extends
        RootTableManager<
          _$KonataDatabase,
          $PlaybackRecordsTable,
          PlaybackRecordRow,
          $$PlaybackRecordsTableFilterComposer,
          $$PlaybackRecordsTableOrderingComposer,
          $$PlaybackRecordsTableAnnotationComposer,
          $$PlaybackRecordsTableCreateCompanionBuilder,
          $$PlaybackRecordsTableUpdateCompanionBuilder,
          (PlaybackRecordRow, $$PlaybackRecordsTableReferences),
          PlaybackRecordRow,
          PrefetchHooks Function({bool workId})
        > {
  $$PlaybackRecordsTableTableManager(
    _$KonataDatabase db,
    $PlaybackRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlaybackRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlaybackRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlaybackRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> workId = const Value.absent(),
                Value<String> episodeId = const Value.absent(),
                Value<String> variantId = const Value.absent(),
                Value<int> seasonNumber = const Value.absent(),
                Value<int?> episodeNumber = const Value.absent(),
                Value<String> episodeTitle = const Value.absent(),
                Value<MediaSourceKind> sourceType = const Value.absent(),
                Value<DateTime> playedAt = const Value.absent(),
                Value<int> positionSeconds = const Value.absent(),
                Value<int> durationSeconds = const Value.absent(),
                Value<bool> isCompleted = const Value.absent(),
                Value<int> updatedAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlaybackRecordsCompanion(
                id: id,
                workId: workId,
                episodeId: episodeId,
                variantId: variantId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                episodeTitle: episodeTitle,
                sourceType: sourceType,
                playedAt: playedAt,
                positionSeconds: positionSeconds,
                durationSeconds: durationSeconds,
                isCompleted: isCompleted,
                updatedAtMs: updatedAtMs,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String workId,
                required String episodeId,
                required String variantId,
                required int seasonNumber,
                Value<int?> episodeNumber = const Value.absent(),
                required String episodeTitle,
                required MediaSourceKind sourceType,
                required DateTime playedAt,
                Value<int> positionSeconds = const Value.absent(),
                Value<int> durationSeconds = const Value.absent(),
                Value<bool> isCompleted = const Value.absent(),
                Value<int> updatedAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlaybackRecordsCompanion.insert(
                id: id,
                workId: workId,
                episodeId: episodeId,
                variantId: variantId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                episodeTitle: episodeTitle,
                sourceType: sourceType,
                playedAt: playedAt,
                positionSeconds: positionSeconds,
                durationSeconds: durationSeconds,
                isCompleted: isCompleted,
                updatedAtMs: updatedAtMs,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PlaybackRecordsTable, PlaybackRecordRow>(table),
                  $$PlaybackRecordsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({workId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (workId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.workId,
                                referencedTable:
                                    $$PlaybackRecordsTableReferences
                                        ._workIdTable(db),
                                referencedColumn:
                                    $$PlaybackRecordsTableReferences
                                        ._workIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$PlaybackRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$KonataDatabase,
      $PlaybackRecordsTable,
      PlaybackRecordRow,
      $$PlaybackRecordsTableFilterComposer,
      $$PlaybackRecordsTableOrderingComposer,
      $$PlaybackRecordsTableAnnotationComposer,
      $$PlaybackRecordsTableCreateCompanionBuilder,
      $$PlaybackRecordsTableUpdateCompanionBuilder,
      (PlaybackRecordRow, $$PlaybackRecordsTableReferences),
      PlaybackRecordRow,
      PrefetchHooks Function({bool workId})
    >;
typedef $$IgnoredFoldersTableCreateCompanionBuilder =
    IgnoredFoldersCompanion Function({
      required String id,
      required String sourceId,
      required String relativePath,
      Value<DateTime?> createdAt,
      Value<int> rowid,
    });
typedef $$IgnoredFoldersTableUpdateCompanionBuilder =
    IgnoredFoldersCompanion Function({
      Value<String> id,
      Value<String> sourceId,
      Value<String> relativePath,
      Value<DateTime?> createdAt,
      Value<int> rowid,
    });

final class $$IgnoredFoldersTableReferences
    extends
        BaseReferences<
          _$KonataDatabase,
          $IgnoredFoldersTable,
          IgnoredFolderRow
        > {
  $$IgnoredFoldersTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $MediaSourcesTable _sourceIdTable(_$KonataDatabase db) => db
      .mediaSources
      .createAlias('ignored_folders__source_id__media_sources__id');

  $$MediaSourcesTableProcessedTableManager get sourceId {
    final $_column = $_itemColumn<String>('source_id')!;

    final manager = $$MediaSourcesTableTableManager(
      $_db,
      $_db.mediaSources,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_sourceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$IgnoredFoldersTableFilterComposer
    extends Composer<_$KonataDatabase, $IgnoredFoldersTable> {
  $$IgnoredFoldersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$MediaSourcesTableFilterComposer get sourceId {
    final $$MediaSourcesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sourceId,
      referencedTable: $db.mediaSources,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaSourcesTableFilterComposer(
            $db: $db,
            $table: $db.mediaSources,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$IgnoredFoldersTableOrderingComposer
    extends Composer<_$KonataDatabase, $IgnoredFoldersTable> {
  $$IgnoredFoldersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$MediaSourcesTableOrderingComposer get sourceId {
    final $$MediaSourcesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sourceId,
      referencedTable: $db.mediaSources,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaSourcesTableOrderingComposer(
            $db: $db,
            $table: $db.mediaSources,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$IgnoredFoldersTableAnnotationComposer
    extends Composer<_$KonataDatabase, $IgnoredFoldersTable> {
  $$IgnoredFoldersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get relativePath => $composableBuilder(
    column: $table.relativePath,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$MediaSourcesTableAnnotationComposer get sourceId {
    final $$MediaSourcesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sourceId,
      referencedTable: $db.mediaSources,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaSourcesTableAnnotationComposer(
            $db: $db,
            $table: $db.mediaSources,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$IgnoredFoldersTableTableManager
    extends
        RootTableManager<
          _$KonataDatabase,
          $IgnoredFoldersTable,
          IgnoredFolderRow,
          $$IgnoredFoldersTableFilterComposer,
          $$IgnoredFoldersTableOrderingComposer,
          $$IgnoredFoldersTableAnnotationComposer,
          $$IgnoredFoldersTableCreateCompanionBuilder,
          $$IgnoredFoldersTableUpdateCompanionBuilder,
          (IgnoredFolderRow, $$IgnoredFoldersTableReferences),
          IgnoredFolderRow,
          PrefetchHooks Function({bool sourceId})
        > {
  $$IgnoredFoldersTableTableManager(
    _$KonataDatabase db,
    $IgnoredFoldersTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$IgnoredFoldersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$IgnoredFoldersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$IgnoredFoldersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> sourceId = const Value.absent(),
                Value<String> relativePath = const Value.absent(),
                Value<DateTime?> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => IgnoredFoldersCompanion(
                id: id,
                sourceId: sourceId,
                relativePath: relativePath,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String sourceId,
                required String relativePath,
                Value<DateTime?> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => IgnoredFoldersCompanion.insert(
                id: id,
                sourceId: sourceId,
                relativePath: relativePath,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$IgnoredFoldersTable, IgnoredFolderRow>(table),
                  $$IgnoredFoldersTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({sourceId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (sourceId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.sourceId,
                                referencedTable: $$IgnoredFoldersTableReferences
                                    ._sourceIdTable(db),
                                referencedColumn:
                                    $$IgnoredFoldersTableReferences
                                        ._sourceIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$IgnoredFoldersTableProcessedTableManager =
    ProcessedTableManager<
      _$KonataDatabase,
      $IgnoredFoldersTable,
      IgnoredFolderRow,
      $$IgnoredFoldersTableFilterComposer,
      $$IgnoredFoldersTableOrderingComposer,
      $$IgnoredFoldersTableAnnotationComposer,
      $$IgnoredFoldersTableCreateCompanionBuilder,
      $$IgnoredFoldersTableUpdateCompanionBuilder,
      (IgnoredFolderRow, $$IgnoredFoldersTableReferences),
      IgnoredFolderRow,
      PrefetchHooks Function({bool sourceId})
    >;
typedef $$SeriesGroupsTableCreateCompanionBuilder =
    SeriesGroupsCompanion Function({
      required String id,
      required String title,
      Value<int?> tmdbCollectionId,
      Value<String?> rootFolderHint,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$SeriesGroupsTableUpdateCompanionBuilder =
    SeriesGroupsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<int?> tmdbCollectionId,
      Value<String?> rootFolderHint,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$SeriesGroupsTableFilterComposer
    extends Composer<_$KonataDatabase, $SeriesGroupsTable> {
  $$SeriesGroupsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tmdbCollectionId => $composableBuilder(
    column: $table.tmdbCollectionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rootFolderHint => $composableBuilder(
    column: $table.rootFolderHint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SeriesGroupsTableOrderingComposer
    extends Composer<_$KonataDatabase, $SeriesGroupsTable> {
  $$SeriesGroupsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tmdbCollectionId => $composableBuilder(
    column: $table.tmdbCollectionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rootFolderHint => $composableBuilder(
    column: $table.rootFolderHint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SeriesGroupsTableAnnotationComposer
    extends Composer<_$KonataDatabase, $SeriesGroupsTable> {
  $$SeriesGroupsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<int> get tmdbCollectionId => $composableBuilder(
    column: $table.tmdbCollectionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get rootFolderHint => $composableBuilder(
    column: $table.rootFolderHint,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$SeriesGroupsTableTableManager
    extends
        RootTableManager<
          _$KonataDatabase,
          $SeriesGroupsTable,
          SeriesGroupRow,
          $$SeriesGroupsTableFilterComposer,
          $$SeriesGroupsTableOrderingComposer,
          $$SeriesGroupsTableAnnotationComposer,
          $$SeriesGroupsTableCreateCompanionBuilder,
          $$SeriesGroupsTableUpdateCompanionBuilder,
          (
            SeriesGroupRow,
            BaseReferences<
              _$KonataDatabase,
              $SeriesGroupsTable,
              SeriesGroupRow
            >,
          ),
          SeriesGroupRow,
          PrefetchHooks Function()
        > {
  $$SeriesGroupsTableTableManager(_$KonataDatabase db, $SeriesGroupsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SeriesGroupsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SeriesGroupsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SeriesGroupsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<int?> tmdbCollectionId = const Value.absent(),
                Value<String?> rootFolderHint = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SeriesGroupsCompanion(
                id: id,
                title: title,
                tmdbCollectionId: tmdbCollectionId,
                rootFolderHint: rootFolderHint,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                Value<int?> tmdbCollectionId = const Value.absent(),
                Value<String?> rootFolderHint = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => SeriesGroupsCompanion.insert(
                id: id,
                title: title,
                tmdbCollectionId: tmdbCollectionId,
                rootFolderHint: rootFolderHint,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SeriesGroupsTable, SeriesGroupRow>(table),
                  BaseReferences<
                    _$KonataDatabase,
                    $SeriesGroupsTable,
                    SeriesGroupRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SeriesGroupsTableProcessedTableManager =
    ProcessedTableManager<
      _$KonataDatabase,
      $SeriesGroupsTable,
      SeriesGroupRow,
      $$SeriesGroupsTableFilterComposer,
      $$SeriesGroupsTableOrderingComposer,
      $$SeriesGroupsTableAnnotationComposer,
      $$SeriesGroupsTableCreateCompanionBuilder,
      $$SeriesGroupsTableUpdateCompanionBuilder,
      (
        SeriesGroupRow,
        BaseReferences<_$KonataDatabase, $SeriesGroupsTable, SeriesGroupRow>,
      ),
      SeriesGroupRow,
      PrefetchHooks Function()
    >;
typedef $$LyricCacheEntriesTableCreateCompanionBuilder =
    LyricCacheEntriesCompanion Function({
      required String trackKey,
      Value<String?> songKey,
      required LyricCacheStatus status,
      Value<LyricSource?> source,
      Value<String> sourceId,
      Value<String> lrcContent,
      Value<double> score,
      required int engineVersion,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$LyricCacheEntriesTableUpdateCompanionBuilder =
    LyricCacheEntriesCompanion Function({
      Value<String> trackKey,
      Value<String?> songKey,
      Value<LyricCacheStatus> status,
      Value<LyricSource?> source,
      Value<String> sourceId,
      Value<String> lrcContent,
      Value<double> score,
      Value<int> engineVersion,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$LyricCacheEntriesTableFilterComposer
    extends Composer<_$KonataDatabase, $LyricCacheEntriesTable> {
  $$LyricCacheEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get trackKey => $composableBuilder(
    column: $table.trackKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get songKey => $composableBuilder(
    column: $table.songKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<LyricCacheStatus, LyricCacheStatus, String>
  get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnWithTypeConverterFilters<LyricSource?, LyricSource, String>
  get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lrcContent => $composableBuilder(
    column: $table.lrcContent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get score => $composableBuilder(
    column: $table.score,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get engineVersion => $composableBuilder(
    column: $table.engineVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LyricCacheEntriesTableOrderingComposer
    extends Composer<_$KonataDatabase, $LyricCacheEntriesTable> {
  $$LyricCacheEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get trackKey => $composableBuilder(
    column: $table.trackKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get songKey => $composableBuilder(
    column: $table.songKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceId => $composableBuilder(
    column: $table.sourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lrcContent => $composableBuilder(
    column: $table.lrcContent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get score => $composableBuilder(
    column: $table.score,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get engineVersion => $composableBuilder(
    column: $table.engineVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LyricCacheEntriesTableAnnotationComposer
    extends Composer<_$KonataDatabase, $LyricCacheEntriesTable> {
  $$LyricCacheEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get trackKey =>
      $composableBuilder(column: $table.trackKey, builder: (column) => column);

  GeneratedColumn<String> get songKey =>
      $composableBuilder(column: $table.songKey, builder: (column) => column);

  GeneratedColumnWithTypeConverter<LyricCacheStatus, String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumnWithTypeConverter<LyricSource?, String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get lrcContent => $composableBuilder(
    column: $table.lrcContent,
    builder: (column) => column,
  );

  GeneratedColumn<double> get score =>
      $composableBuilder(column: $table.score, builder: (column) => column);

  GeneratedColumn<int> get engineVersion => $composableBuilder(
    column: $table.engineVersion,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$LyricCacheEntriesTableTableManager
    extends
        RootTableManager<
          _$KonataDatabase,
          $LyricCacheEntriesTable,
          LyricCacheRow,
          $$LyricCacheEntriesTableFilterComposer,
          $$LyricCacheEntriesTableOrderingComposer,
          $$LyricCacheEntriesTableAnnotationComposer,
          $$LyricCacheEntriesTableCreateCompanionBuilder,
          $$LyricCacheEntriesTableUpdateCompanionBuilder,
          (
            LyricCacheRow,
            BaseReferences<
              _$KonataDatabase,
              $LyricCacheEntriesTable,
              LyricCacheRow
            >,
          ),
          LyricCacheRow,
          PrefetchHooks Function()
        > {
  $$LyricCacheEntriesTableTableManager(
    _$KonataDatabase db,
    $LyricCacheEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LyricCacheEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LyricCacheEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LyricCacheEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> trackKey = const Value.absent(),
                Value<String?> songKey = const Value.absent(),
                Value<LyricCacheStatus> status = const Value.absent(),
                Value<LyricSource?> source = const Value.absent(),
                Value<String> sourceId = const Value.absent(),
                Value<String> lrcContent = const Value.absent(),
                Value<double> score = const Value.absent(),
                Value<int> engineVersion = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LyricCacheEntriesCompanion(
                trackKey: trackKey,
                songKey: songKey,
                status: status,
                source: source,
                sourceId: sourceId,
                lrcContent: lrcContent,
                score: score,
                engineVersion: engineVersion,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String trackKey,
                Value<String?> songKey = const Value.absent(),
                required LyricCacheStatus status,
                Value<LyricSource?> source = const Value.absent(),
                Value<String> sourceId = const Value.absent(),
                Value<String> lrcContent = const Value.absent(),
                Value<double> score = const Value.absent(),
                required int engineVersion,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => LyricCacheEntriesCompanion.insert(
                trackKey: trackKey,
                songKey: songKey,
                status: status,
                source: source,
                sourceId: sourceId,
                lrcContent: lrcContent,
                score: score,
                engineVersion: engineVersion,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LyricCacheEntriesTable, LyricCacheRow>(table),
                  BaseReferences<
                    _$KonataDatabase,
                    $LyricCacheEntriesTable,
                    LyricCacheRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LyricCacheEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$KonataDatabase,
      $LyricCacheEntriesTable,
      LyricCacheRow,
      $$LyricCacheEntriesTableFilterComposer,
      $$LyricCacheEntriesTableOrderingComposer,
      $$LyricCacheEntriesTableAnnotationComposer,
      $$LyricCacheEntriesTableCreateCompanionBuilder,
      $$LyricCacheEntriesTableUpdateCompanionBuilder,
      (
        LyricCacheRow,
        BaseReferences<
          _$KonataDatabase,
          $LyricCacheEntriesTable,
          LyricCacheRow
        >,
      ),
      LyricCacheRow,
      PrefetchHooks Function()
    >;
typedef $$SyncTombstonesTableCreateCompanionBuilder =
    SyncTombstonesCompanion Function({
      required String entityKey,
      required String entityType,
      required int deletedAtMs,
      required String deviceId,
      Value<int> rowid,
    });
typedef $$SyncTombstonesTableUpdateCompanionBuilder =
    SyncTombstonesCompanion Function({
      Value<String> entityKey,
      Value<String> entityType,
      Value<int> deletedAtMs,
      Value<String> deviceId,
      Value<int> rowid,
    });

class $$SyncTombstonesTableFilterComposer
    extends Composer<_$KonataDatabase, $SyncTombstonesTable> {
  $$SyncTombstonesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get entityKey => $composableBuilder(
    column: $table.entityKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAtMs => $composableBuilder(
    column: $table.deletedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncTombstonesTableOrderingComposer
    extends Composer<_$KonataDatabase, $SyncTombstonesTable> {
  $$SyncTombstonesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get entityKey => $composableBuilder(
    column: $table.entityKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAtMs => $composableBuilder(
    column: $table.deletedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncTombstonesTableAnnotationComposer
    extends Composer<_$KonataDatabase, $SyncTombstonesTable> {
  $$SyncTombstonesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get entityKey =>
      $composableBuilder(column: $table.entityKey, builder: (column) => column);

  GeneratedColumn<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => column,
  );

  GeneratedColumn<int> get deletedAtMs => $composableBuilder(
    column: $table.deletedAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);
}

class $$SyncTombstonesTableTableManager
    extends
        RootTableManager<
          _$KonataDatabase,
          $SyncTombstonesTable,
          SyncTombstoneRow,
          $$SyncTombstonesTableFilterComposer,
          $$SyncTombstonesTableOrderingComposer,
          $$SyncTombstonesTableAnnotationComposer,
          $$SyncTombstonesTableCreateCompanionBuilder,
          $$SyncTombstonesTableUpdateCompanionBuilder,
          (
            SyncTombstoneRow,
            BaseReferences<
              _$KonataDatabase,
              $SyncTombstonesTable,
              SyncTombstoneRow
            >,
          ),
          SyncTombstoneRow,
          PrefetchHooks Function()
        > {
  $$SyncTombstonesTableTableManager(
    _$KonataDatabase db,
    $SyncTombstonesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncTombstonesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncTombstonesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncTombstonesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> entityKey = const Value.absent(),
                Value<String> entityType = const Value.absent(),
                Value<int> deletedAtMs = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncTombstonesCompanion(
                entityKey: entityKey,
                entityType: entityType,
                deletedAtMs: deletedAtMs,
                deviceId: deviceId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String entityKey,
                required String entityType,
                required int deletedAtMs,
                required String deviceId,
                Value<int> rowid = const Value.absent(),
              }) => SyncTombstonesCompanion.insert(
                entityKey: entityKey,
                entityType: entityType,
                deletedAtMs: deletedAtMs,
                deviceId: deviceId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncTombstonesTable, SyncTombstoneRow>(table),
                  BaseReferences<
                    _$KonataDatabase,
                    $SyncTombstonesTable,
                    SyncTombstoneRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncTombstonesTableProcessedTableManager =
    ProcessedTableManager<
      _$KonataDatabase,
      $SyncTombstonesTable,
      SyncTombstoneRow,
      $$SyncTombstonesTableFilterComposer,
      $$SyncTombstonesTableOrderingComposer,
      $$SyncTombstonesTableAnnotationComposer,
      $$SyncTombstonesTableCreateCompanionBuilder,
      $$SyncTombstonesTableUpdateCompanionBuilder,
      (
        SyncTombstoneRow,
        BaseReferences<
          _$KonataDatabase,
          $SyncTombstonesTable,
          SyncTombstoneRow
        >,
      ),
      SyncTombstoneRow,
      PrefetchHooks Function()
    >;
typedef $$SyncKvMetaTableCreateCompanionBuilder =
    SyncKvMetaCompanion Function({
      required String key,
      required String value,
      required int updatedAtMs,
      Value<int> rowid,
    });
typedef $$SyncKvMetaTableUpdateCompanionBuilder =
    SyncKvMetaCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> updatedAtMs,
      Value<int> rowid,
    });

class $$SyncKvMetaTableFilterComposer
    extends Composer<_$KonataDatabase, $SyncKvMetaTable> {
  $$SyncKvMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncKvMetaTableOrderingComposer
    extends Composer<_$KonataDatabase, $SyncKvMetaTable> {
  $$SyncKvMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncKvMetaTableAnnotationComposer
    extends Composer<_$KonataDatabase, $SyncKvMetaTable> {
  $$SyncKvMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
    column: $table.updatedAtMs,
    builder: (column) => column,
  );
}

class $$SyncKvMetaTableTableManager
    extends
        RootTableManager<
          _$KonataDatabase,
          $SyncKvMetaTable,
          SyncKvMetaRow,
          $$SyncKvMetaTableFilterComposer,
          $$SyncKvMetaTableOrderingComposer,
          $$SyncKvMetaTableAnnotationComposer,
          $$SyncKvMetaTableCreateCompanionBuilder,
          $$SyncKvMetaTableUpdateCompanionBuilder,
          (
            SyncKvMetaRow,
            BaseReferences<_$KonataDatabase, $SyncKvMetaTable, SyncKvMetaRow>,
          ),
          SyncKvMetaRow,
          PrefetchHooks Function()
        > {
  $$SyncKvMetaTableTableManager(_$KonataDatabase db, $SyncKvMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncKvMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncKvMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncKvMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> updatedAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncKvMetaCompanion(
                key: key,
                value: value,
                updatedAtMs: updatedAtMs,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                required int updatedAtMs,
                Value<int> rowid = const Value.absent(),
              }) => SyncKvMetaCompanion.insert(
                key: key,
                value: value,
                updatedAtMs: updatedAtMs,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncKvMetaTable, SyncKvMetaRow>(table),
                  BaseReferences<
                    _$KonataDatabase,
                    $SyncKvMetaTable,
                    SyncKvMetaRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncKvMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$KonataDatabase,
      $SyncKvMetaTable,
      SyncKvMetaRow,
      $$SyncKvMetaTableFilterComposer,
      $$SyncKvMetaTableOrderingComposer,
      $$SyncKvMetaTableAnnotationComposer,
      $$SyncKvMetaTableCreateCompanionBuilder,
      $$SyncKvMetaTableUpdateCompanionBuilder,
      (
        SyncKvMetaRow,
        BaseReferences<_$KonataDatabase, $SyncKvMetaTable, SyncKvMetaRow>,
      ),
      SyncKvMetaRow,
      PrefetchHooks Function()
    >;
typedef $$BangumiSyncQueueTableCreateCompanionBuilder =
    BangumiSyncQueueCompanion Function({
      required String queueKey,
      required int subjectId,
      required int seasonNumber,
      Value<int?> episodeNumber,
      required int targetStatus,
      required int enqueuedAtMs,
      Value<int> retryCount,
      Value<String?> lastError,
      Value<int> nextRetryAtMs,
      Value<int> rowid,
    });
typedef $$BangumiSyncQueueTableUpdateCompanionBuilder =
    BangumiSyncQueueCompanion Function({
      Value<String> queueKey,
      Value<int> subjectId,
      Value<int> seasonNumber,
      Value<int?> episodeNumber,
      Value<int> targetStatus,
      Value<int> enqueuedAtMs,
      Value<int> retryCount,
      Value<String?> lastError,
      Value<int> nextRetryAtMs,
      Value<int> rowid,
    });

class $$BangumiSyncQueueTableFilterComposer
    extends Composer<_$KonataDatabase, $BangumiSyncQueueTable> {
  $$BangumiSyncQueueTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get queueKey => $composableBuilder(
    column: $table.queueKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seasonNumber => $composableBuilder(
    column: $table.seasonNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get episodeNumber => $composableBuilder(
    column: $table.episodeNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get targetStatus => $composableBuilder(
    column: $table.targetStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get enqueuedAtMs => $composableBuilder(
    column: $table.enqueuedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextRetryAtMs => $composableBuilder(
    column: $table.nextRetryAtMs,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BangumiSyncQueueTableOrderingComposer
    extends Composer<_$KonataDatabase, $BangumiSyncQueueTable> {
  $$BangumiSyncQueueTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get queueKey => $composableBuilder(
    column: $table.queueKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get subjectId => $composableBuilder(
    column: $table.subjectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seasonNumber => $composableBuilder(
    column: $table.seasonNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get episodeNumber => $composableBuilder(
    column: $table.episodeNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get targetStatus => $composableBuilder(
    column: $table.targetStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get enqueuedAtMs => $composableBuilder(
    column: $table.enqueuedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextRetryAtMs => $composableBuilder(
    column: $table.nextRetryAtMs,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BangumiSyncQueueTableAnnotationComposer
    extends Composer<_$KonataDatabase, $BangumiSyncQueueTable> {
  $$BangumiSyncQueueTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get queueKey =>
      $composableBuilder(column: $table.queueKey, builder: (column) => column);

  GeneratedColumn<int> get subjectId =>
      $composableBuilder(column: $table.subjectId, builder: (column) => column);

  GeneratedColumn<int> get seasonNumber => $composableBuilder(
    column: $table.seasonNumber,
    builder: (column) => column,
  );

  GeneratedColumn<int> get episodeNumber => $composableBuilder(
    column: $table.episodeNumber,
    builder: (column) => column,
  );

  GeneratedColumn<int> get targetStatus => $composableBuilder(
    column: $table.targetStatus,
    builder: (column) => column,
  );

  GeneratedColumn<int> get enqueuedAtMs => $composableBuilder(
    column: $table.enqueuedAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<int> get nextRetryAtMs => $composableBuilder(
    column: $table.nextRetryAtMs,
    builder: (column) => column,
  );
}

class $$BangumiSyncQueueTableTableManager
    extends
        RootTableManager<
          _$KonataDatabase,
          $BangumiSyncQueueTable,
          BangumiSyncQueueRow,
          $$BangumiSyncQueueTableFilterComposer,
          $$BangumiSyncQueueTableOrderingComposer,
          $$BangumiSyncQueueTableAnnotationComposer,
          $$BangumiSyncQueueTableCreateCompanionBuilder,
          $$BangumiSyncQueueTableUpdateCompanionBuilder,
          (
            BangumiSyncQueueRow,
            BaseReferences<
              _$KonataDatabase,
              $BangumiSyncQueueTable,
              BangumiSyncQueueRow
            >,
          ),
          BangumiSyncQueueRow,
          PrefetchHooks Function()
        > {
  $$BangumiSyncQueueTableTableManager(
    _$KonataDatabase db,
    $BangumiSyncQueueTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BangumiSyncQueueTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BangumiSyncQueueTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BangumiSyncQueueTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> queueKey = const Value.absent(),
                Value<int> subjectId = const Value.absent(),
                Value<int> seasonNumber = const Value.absent(),
                Value<int?> episodeNumber = const Value.absent(),
                Value<int> targetStatus = const Value.absent(),
                Value<int> enqueuedAtMs = const Value.absent(),
                Value<int> retryCount = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<int> nextRetryAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BangumiSyncQueueCompanion(
                queueKey: queueKey,
                subjectId: subjectId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                targetStatus: targetStatus,
                enqueuedAtMs: enqueuedAtMs,
                retryCount: retryCount,
                lastError: lastError,
                nextRetryAtMs: nextRetryAtMs,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String queueKey,
                required int subjectId,
                required int seasonNumber,
                Value<int?> episodeNumber = const Value.absent(),
                required int targetStatus,
                required int enqueuedAtMs,
                Value<int> retryCount = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<int> nextRetryAtMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BangumiSyncQueueCompanion.insert(
                queueKey: queueKey,
                subjectId: subjectId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                targetStatus: targetStatus,
                enqueuedAtMs: enqueuedAtMs,
                retryCount: retryCount,
                lastError: lastError,
                nextRetryAtMs: nextRetryAtMs,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BangumiSyncQueueTable, BangumiSyncQueueRow>(
                    table,
                  ),
                  BaseReferences<
                    _$KonataDatabase,
                    $BangumiSyncQueueTable,
                    BangumiSyncQueueRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BangumiSyncQueueTableProcessedTableManager =
    ProcessedTableManager<
      _$KonataDatabase,
      $BangumiSyncQueueTable,
      BangumiSyncQueueRow,
      $$BangumiSyncQueueTableFilterComposer,
      $$BangumiSyncQueueTableOrderingComposer,
      $$BangumiSyncQueueTableAnnotationComposer,
      $$BangumiSyncQueueTableCreateCompanionBuilder,
      $$BangumiSyncQueueTableUpdateCompanionBuilder,
      (
        BangumiSyncQueueRow,
        BaseReferences<
          _$KonataDatabase,
          $BangumiSyncQueueTable,
          BangumiSyncQueueRow
        >,
      ),
      BangumiSyncQueueRow,
      PrefetchHooks Function()
    >;

class $KonataDatabaseManager {
  final _$KonataDatabase _db;
  $KonataDatabaseManager(this._db);
  $$MediaSourcesTableTableManager get mediaSources =>
      $$MediaSourcesTableTableManager(_db, _db.mediaSources);
  $$WorksTableTableManager get works =>
      $$WorksTableTableManager(_db, _db.works);
  $$EpisodesTableTableManager get episodes =>
      $$EpisodesTableTableManager(_db, _db.episodes);
  $$MediaVariantsTableTableManager get mediaVariants =>
      $$MediaVariantsTableTableManager(_db, _db.mediaVariants);
  $$ScrapeCandidatesTableTableManager get scrapeCandidates =>
      $$ScrapeCandidatesTableTableManager(_db, _db.scrapeCandidates);
  $$PlaybackRecordsTableTableManager get playbackRecords =>
      $$PlaybackRecordsTableTableManager(_db, _db.playbackRecords);
  $$IgnoredFoldersTableTableManager get ignoredFolders =>
      $$IgnoredFoldersTableTableManager(_db, _db.ignoredFolders);
  $$SeriesGroupsTableTableManager get seriesGroups =>
      $$SeriesGroupsTableTableManager(_db, _db.seriesGroups);
  $$LyricCacheEntriesTableTableManager get lyricCacheEntries =>
      $$LyricCacheEntriesTableTableManager(_db, _db.lyricCacheEntries);
  $$SyncTombstonesTableTableManager get syncTombstones =>
      $$SyncTombstonesTableTableManager(_db, _db.syncTombstones);
  $$SyncKvMetaTableTableManager get syncKvMeta =>
      $$SyncKvMetaTableTableManager(_db, _db.syncKvMeta);
  $$BangumiSyncQueueTableTableManager get bangumiSyncQueue =>
      $$BangumiSyncQueueTableTableManager(_db, _db.bangumiSyncQueue);
}
