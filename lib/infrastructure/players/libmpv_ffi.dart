import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:developer' as developer;

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../../domain/playback/playback_probe_stats.dart';
import '../../domain/playback/track_preferences.dart';

part 'libmpv_ffi_bindings.dart';

/// 基于 `dart:ffi` 与 `NativeCallable.listener` 的真实 libmpv 客户端封装。
class FfiLibMpvClient
    implements LibMpvClient, LibMpvSoftwareFrameSource, LibMpvUnobservable {
  FfiLibMpvClient._({
    required this._libraryPath,
    required this._library,
    required this._handle,
  }) {
    _mpvErrorString = _library.lookupFunction<_MpvErrorStringNative, _MpvErrorStringDart>(
      'mpv_error_string',
    );
    _mpvInitialize = _library.lookupFunction<_MpvInitializeNative, _MpvInitializeDart>(
      'mpv_initialize',
    );
    _mpvFree = _library.lookupFunction<_MpvFreeNative, _MpvFreeDart>(
      'mpv_free',
    );
    _mpvFreeNodeContents = _library
        .lookupFunction<_MpvFreeNodeContentsNative, _MpvFreeNodeContentsDart>(
          'mpv_free_node_contents',
        );
    _mpvSetOptionString = _library
        .lookupFunction<_MpvSetOptionStringNative, _MpvSetOptionStringDart>(
          'mpv_set_option_string',
        );
    _mpvSetProperty = _library
        .lookupFunction<_MpvSetPropertyNative, _MpvSetPropertyDart>(
          'mpv_set_property',
        );
    _mpvSetPropertyString = _library
        .lookupFunction<_MpvSetPropertyStringNative, _MpvSetPropertyStringDart>(
          'mpv_set_property_string',
        );
    _mpvGetProperty = _library
        .lookupFunction<_MpvGetPropertyNative, _MpvGetPropertyDart>(
          'mpv_get_property',
        );
    _mpvGetPropertyString = _library
        .lookupFunction<_MpvGetPropertyStringNative, _MpvGetPropertyStringDart>(
          'mpv_get_property_string',
        );
    _mpvObserveProperty = _library
        .lookupFunction<_MpvObservePropertyNative, _MpvObservePropertyDart>(
          'mpv_observe_property',
        );
    _mpvUnobserveProperty = _library
        .lookupFunction<_MpvUnobservePropertyNative, _MpvUnobservePropertyDart>(
          'mpv_unobserve_property',
        );
    _mpvCommand = _library.lookupFunction<_MpvCommandNative, _MpvCommandDart>(
      'mpv_command',
    );
    _mpvCommandAsync = _library
        .lookupFunction<_MpvCommandAsyncNative, _MpvCommandAsyncDart>(
          'mpv_command_async',
        );
    _mpvRequestLogMessages = _library
        .lookupFunction<_MpvRequestLogMessagesNative, _MpvRequestLogMessagesDart>(
          'mpv_request_log_messages',
        );
    _mpvSetWakeupCallback = _library
        .lookupFunction<_MpvSetWakeupCallbackNative, _MpvSetWakeupCallbackDart>(
          'mpv_set_wakeup_callback',
        );
    _mpvWaitEvent = _library
        .lookupFunction<_MpvWaitEventNative, _MpvWaitEventDart>(
          'mpv_wait_event',
        );
  }

  static final bool _androidJavaVmRegisteredOnce = _registerAndroidJavaVmOnce();

  static bool _registerAndroidJavaVmOnce() {
    if (!Platform.isAndroid) return false;
    try {
      final helperLib = DynamicLibrary.open('libmediakitandroidhelper.so');
      final getJavaVm = helperLib
          .lookupFunction<_MediaKitGetJavaVmNative, _MediaKitGetJavaVmDart>(
            'MediaKitAndroidHelperGetJavaVM',
          );
      final jvm = getJavaVm();
      if (jvm == nullptr) return false;

      DynamicLibrary avCodecLib;
      try {
        avCodecLib = DynamicLibrary.open('libavcodec.so');
      } catch (_) {
        avCodecLib = DynamicLibrary.open('libmpv.so');
      }
      final setJavaVm = avCodecLib
          .lookupFunction<_AvJniSetJavaVmNative, _AvJniSetJavaVmDart>(
            'av_jni_set_java_vm',
          );
      return setJavaVm(jvm, nullptr) == 0;
    } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.libmpv_ffi', error: error);
      return false;
    }
  }

  /// 将 Android 宿主进程 JavaVM 句柄注册至 FFmpeg/libmpv JNI 上下文，解锁 vo=gpu 表面绑定与 MediaCodec 硬解。
  static void _ensureAndroidJavaVmRegistered(DynamicLibrary mpvLibrary) {
    if (!Platform.isAndroid || _androidJavaVmRegisteredOnce) return;
    try {
      final helperLib = DynamicLibrary.open('libmediakitandroidhelper.so');
      final getJavaVm = helperLib
          .lookupFunction<_MediaKitGetJavaVmNative, _MediaKitGetJavaVmDart>(
            'MediaKitAndroidHelperGetJavaVM',
          );
      final jvm = getJavaVm();
      if (jvm == nullptr) return;
      final setJavaVm = mpvLibrary
          .lookupFunction<_AvJniSetJavaVmNative, _AvJniSetJavaVmDart>(
            'av_jni_set_java_vm',
          );
      setJavaVm(jvm, nullptr);
    } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.libmpv_ffi', error: error);
    }
  }

  /// 创建尚未执行 `mpv_initialize()` 的原生 `libmpv` 客户端。
  factory FfiLibMpvClient.create({String? preferredLibraryPath}) {
    final resolved = _openLibMpv(preferredLibraryPath: preferredLibraryPath);
    _ensureAndroidJavaVmRegistered(resolved.library);
    final mpvCreate = resolved.library
        .lookupFunction<_MpvCreateNative, _MpvCreateDart>('mpv_create');
    final handle = mpvCreate();
    if (handle == nullptr) {
      throw StateError('mpv_create() returned nullptr (${resolved.path})');
    }
    return FfiLibMpvClient._(
      libraryPath: resolved.path,
      library: resolved.library,
      handle: handle,
    );
  }

  final String _libraryPath;
  final DynamicLibrary _library;
  Pointer<Void> _handle;
  bool _initialized = false;
  bool _disposed = false;

  final StreamController<MpvClientEvent> _eventsController =
      StreamController<MpvClientEvent>.broadcast();
  NativeCallable<_MpvWakeupNative>? _wakeupCallable;

  final StreamController<void> _renderUpdatesController =
      StreamController<void>.broadcast();
  Pointer<Void> _renderCtx = nullptr;
  NativeCallable<_MpvWakeupNative>? _renderWakeupCallable;
  Pointer<Uint8>? _swPixelRawBuffer;
  int _swPixelBufferCapacity = 0;
  _MpvRenderContextUpdateDart? _mpvRenderUpdate;
  _MpvRenderContextRenderDart? _mpvRenderRender;
  _MpvRenderContextFreeDart? _mpvRenderFree;
  _MpvRenderContextSetUpdateCallbackDart? _mpvRenderSetUpdateCb;

  late final _MpvErrorStringDart _mpvErrorString;
  late final _MpvInitializeDart _mpvInitialize;
  late final _MpvFreeDart _mpvFree;
  late final _MpvFreeNodeContentsDart _mpvFreeNodeContents;
  late final _MpvSetOptionStringDart _mpvSetOptionString;
  late final _MpvSetPropertyDart _mpvSetProperty;
  late final _MpvSetPropertyStringDart _mpvSetPropertyString;
  late final _MpvGetPropertyDart _mpvGetProperty;
  late final _MpvGetPropertyStringDart _mpvGetPropertyString;
  late final _MpvObservePropertyDart _mpvObserveProperty;
  late final _MpvUnobservePropertyDart _mpvUnobserveProperty;
  late final _MpvCommandDart _mpvCommand;
  late final _MpvCommandAsyncDart _mpvCommandAsync;
  late final _MpvRequestLogMessagesDart _mpvRequestLogMessages;
  late final _MpvSetWakeupCallbackDart _mpvSetWakeupCallback;
  late final _MpvWaitEventDart _mpvWaitEvent;

  @override
  int get handleAddress => _disposed ? 0 : _handle.address;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isDisposed => _disposed;

  @override
  Stream<MpvClientEvent> get events => _eventsController.stream;

  /// 解析当前可用 `libmpv` 动态库路径（Windows 优先可执行文件同目录，支持测试工作区回退）。
  static ({String path, DynamicLibrary library}) _openLibMpv({
    String? preferredLibraryPath,
  }) {
    final candidates = <String>[];
    if (preferredLibraryPath != null && preferredLibraryPath.trim().isNotEmpty) {
      candidates.add(preferredLibraryPath.trim());
    }
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      candidates.add(p.join(exeDir, 'libmpv-2.dll'));
      final cwd = Directory.current.path;
      candidates.add(
        p.join(cwd, 'native', 'konata-native', 'windows', 'libmpv-2.dll'),
      );
      candidates.add('libmpv-2.dll');
      candidates.add('mpv-2.dll');
    } else if (Platform.isAndroid || Platform.isLinux) {
      candidates.add('libmpv.so');
      candidates.add('libmpv.so.2');
    }

    Object? lastError;
    for (final candidate in candidates) {
      try {
        final isBareName =
            !candidate.contains('\\') && !candidate.contains('/');
        if (!isBareName && !File(candidate).existsSync()) {
          continue;
        }
        final lib = DynamicLibrary.open(candidate);
        return (path: candidate, library: lib);
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError(
      'Unable to load libmpv dynamic library (candidates: $candidates): $lastError',
    );
  }

  @override
  String errorString(int code) {
    final ptr = _mpvErrorString(code);
    if (ptr == nullptr) return 'mpv_error($code)';
    return ptr.toDartString();
  }

  @override
  int setOptionString(String name, String value) {
    if (_disposed) return -1;
    return using((arena) {
      return _mpvSetOptionString(
        _handle,
        name.toNativeUtf8(allocator: arena),
        value.toNativeUtf8(allocator: arena),
      );
    });
  }

  @override
  int initialize() {
    if (_disposed) return -1;
    if (_initialized) return MpvError.success;
    final rc = _mpvInitialize(_handle);
    if (rc >= 0) {
      _initialized = true;
      _attachWakeupCallback();
    }
    return rc;
  }

  void _attachWakeupCallback() {
    _wakeupCallable?.close();
    _wakeupCallable = NativeCallable<_MpvWakeupNative>.listener(_onMpvWakeup);
    _mpvSetWakeupCallback(
      _handle,
      _wakeupCallable!.nativeFunction,
      nullptr,
    );
  }

  void _onMpvWakeup(Pointer<Void> _) {
    drainEvents();
  }

  /// 非阻塞排空待处理 libmpv 事件队列。
  void drainEvents() {
    if (_disposed || _handle == nullptr) return;
    while (!_disposed && _handle != nullptr) {
      final evPtr = _mpvWaitEvent(_handle, 0.0);
      if (evPtr == nullptr) break;
      final ev = evPtr.ref;
      if (ev.eventId == MpvEventId.none) {
        break;
      }
      final parsed = _parseEvent(ev);
      if (parsed != null && !_eventsController.isClosed) {
        _eventsController.add(parsed);
      }
      if (ev.eventId == MpvEventId.shutdown) {
        break;
      }
    }
  }

  MpvClientEvent? _parseEvent(_MpvEventNative ev) {
    switch (ev.eventId) {
      case MpvEventId.shutdown:
        return const MpvShutdownEvent();
      case MpvEventId.fileLoaded:
        return const MpvFileLoadedEvent();
      case MpvEventId.videoReconfig:
        return const MpvVideoReconfigEvent();
      case MpvEventId.audioReconfig:
        return const MpvAudioReconfigEvent();
      case MpvEventId.seek:
        return const MpvSeekEvent();
      case MpvEventId.playbackRestart:
        return const MpvPlaybackRestartEvent();
      case MpvEventId.startFile:
        if (ev.data == nullptr) return const MpvStartFileEvent(0);
        final sf = ev.data.cast<_MpvEventStartFileNative>().ref;
        return MpvStartFileEvent(sf.playlistEntryId);
      case MpvEventId.endFile:
        if (ev.data == nullptr) {
          return const MpvEndFileEvent(
            reason: MpvEndFileReason.stop,
            errorCode: 0,
            playlistEntryId: 0,
          );
        }
        final ef = ev.data.cast<_MpvEventEndFileNative>().ref;
        return MpvEndFileEvent(
          reason: ef.reason,
          errorCode: ef.error,
          playlistEntryId: ef.playlistEntryId,
        );
      case MpvEventId.logMessage:
        if (ev.data == nullptr) return null;
        final msg = ev.data.cast<_MpvEventLogMessageNative>().ref;
        return MpvLogMessageEvent(
          prefix: _safeReadUtf8(msg.prefix),
          level: _safeReadUtf8(msg.level),
          text: _safeReadUtf8(msg.text).trimRight(),
        );
      case MpvEventId.propertyChange:
        if (ev.data == nullptr) return null;
        final prop = ev.data.cast<_MpvEventPropertyNative>().ref;
        final name = _safeReadUtf8(prop.name);
        String? strVal;
        bool? boolVal;
        int? intVal;
        double? dblVal;
        if (prop.data != nullptr) {
          switch (prop.format) {
            case MpvFormat.string:
            case MpvFormat.osdString:
              final ptr = prop.data.cast<Pointer<Utf8>>().value;
              if (ptr != nullptr) strVal = _safeReadUtf8(ptr);
            case MpvFormat.flag:
              boolVal = prop.data.cast<Int32>().value != 0;
            case MpvFormat.int64:
              intVal = prop.data.cast<Int64>().value;
            case MpvFormat.double_:
              dblVal = prop.data.cast<Double>().value;
          }
        }
        return MpvPropertyChangeEvent(
          name: name,
          replyUserdata: ev.replyUserdata,
          format: prop.format,
          stringValue: strVal,
          boolValue: boolVal,
          intValue: intVal,
          doubleValue: dblVal,
        );
      default:
        return null;
    }
  }

  @override
  int setPropertyString(String name, String value) {
    if (_disposed) return -1;
    return using((arena) {
      return _mpvSetPropertyString(
        _handle,
        name.toNativeUtf8(allocator: arena),
        value.toNativeUtf8(allocator: arena),
      );
    });
  }

  @override
  int setPropertyFlag(String name, bool value) {
    if (_disposed) return -1;
    return using((arena) {
      final flagPtr = arena<Int32>();
      flagPtr.value = value ? 1 : 0;
      return _mpvSetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.flag,
        flagPtr.cast<Void>(),
      );
    });
  }

  @override
  int setPropertyInt64(String name, int value) {
    if (_disposed) return -1;
    return using((arena) {
      final intPtr = arena<Int64>();
      intPtr.value = value;
      return _mpvSetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.int64,
        intPtr.cast<Void>(),
      );
    });
  }

  @override
  int setPropertyDouble(String name, double value) {
    if (_disposed) return -1;
    return using((arena) {
      final dblPtr = arena<Double>();
      dblPtr.value = value;
      return _mpvSetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.double_,
        dblPtr.cast<Void>(),
      );
    });
  }

  @override
  String? getPropertyString(String name) {
    if (_disposed) return null;
    return using((arena) {
      final ptr = _mpvGetPropertyString(
        _handle,
        name.toNativeUtf8(allocator: arena),
      );
      if (ptr == nullptr) return null;
      try {
        return _safeReadUtf8(ptr);
      } finally {
        _mpvFree(ptr.cast<Void>());
      }
    });
  }

  @override
  bool? getPropertyFlag(String name) {
    if (_disposed) return null;
    return using((arena) {
      final outPtr = arena<Int32>();
      final rc = _mpvGetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.flag,
        outPtr.cast<Void>(),
      );
      if (rc < 0) return null;
      return outPtr.value != 0;
    });
  }

  @override
  int? getPropertyInt64(String name) {
    if (_disposed) return null;
    return using((arena) {
      final outPtr = arena<Int64>();
      final rc = _mpvGetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.int64,
        outPtr.cast<Void>(),
      );
      if (rc < 0) return null;
      return outPtr.value;
    });
  }

  @override
  double? getPropertyDouble(String name) {
    if (_disposed) return null;
    return using((arena) {
      final outPtr = arena<Double>();
      final rc = _mpvGetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.double_,
        outPtr.cast<Void>(),
      );
      if (rc < 0) return null;
      return outPtr.value;
    });
  }

  @override
  List<MpvTrackInfo> readTrackList() {
    if (_disposed) return const [];
    return _withNodeProperty('track-list', (node) {
      if (node.format != MpvFormat.nodeArray || node.u.list == nullptr) {
        return const <MpvTrackInfo>[];
      }
      final list = node.u.list.ref;
      final tracks = <MpvTrackInfo>[];
      for (var i = 0; i < list.num; i++) {
        final item = list.values[i];
        final fields = _readNodeMapFields(item);
        if (fields == null) continue;
        final typeRaw = _asString(fields['type']);
        final trackType = switch (typeRaw) {
          'video' => MpvTrackType.video,
          'audio' => MpvTrackType.audio,
          'sub' => MpvTrackType.subtitle,
          _ => null,
        };
        if (trackType == null) continue;
        final id = _asInt(fields['id']) ?? 0;
        if (id <= 0) continue;

        final extFile = _asString(fields['external-filename']);
        tracks.add(
          MpvTrackInfo(
            id: id,
            type: trackType,
            title: _asString(fields['title']),
            lang: _asString(fields['lang']),
            codec: _asString(fields['codec']),
            channelCount: _asInt(fields['demux-channel-count']),
            sampleRateHz: _asInt(fields['demux-samplerate']),
            isDefault: _asBool(fields['default']),
            isForced: _asBool(fields['forced']),
            isExternal: _asBool(fields['external']),
            externalFilename: extFile.isEmpty ? null : extFile,
            selected: _asBool(fields['selected']),
          ),
        );
      }
      return tracks;
    }) ?? const [];
  }

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) {
    if (_disposed) return const [];
    final rawChapters = _withNodeProperty('chapter-list', (node) {
      if (node.format != MpvFormat.nodeArray || node.u.list == nullptr) {
        return const <PlaybackChapter>[];
      }
      final list = node.u.list.ref;
      final chapters = <PlaybackChapter>[];
      for (var i = 0; i < list.num; i++) {
        final fields = _readNodeMapFields(list.values[i]);
        if (fields == null) continue;
        final title = _asString(fields['title']);
        final time = _asDouble(fields['time']) ?? 0.0;
        chapters.add(
          PlaybackChapter(
            index: i,
            title: title,
            startSeconds: PlaybackProbeStats.clampChapterZeroPts(time),
          ),
        );
      }
      return chapters;
    }) ?? const [];
    return PlaybackProbeStats.normalizeChapters(
      rawChapters,
      totalDurationSeconds: totalDurationSeconds,
    );
  }

  @override
  List<MpvAudioDevice> readAudioDeviceList() {
    if (_disposed) return const [];
    return _withNodeProperty('audio-device-list', (node) {
      if (node.format != MpvFormat.nodeArray || node.u.list == nullptr) {
        return const <MpvAudioDevice>[];
      }
      final list = node.u.list.ref;
      final devices = <MpvAudioDevice>[];
      for (var i = 0; i < list.num; i++) {
        final fields = _readNodeMapFields(list.values[i]);
        if (fields == null) continue;
        final name = _asString(fields['name']);
        if (name.isEmpty) continue;
        final desc = _asString(fields['description']);
        devices.add(
          MpvAudioDevice(
            name: name,
            description: desc.isNotEmpty ? desc : name,
          ),
        );
      }
      return devices;
    }) ?? const [];
  }

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() {
    if (_disposed) return const [];
    return _withNodeProperty('demuxer-cache-state', (node) {
          if (node.format != MpvFormat.nodeMap || node.u.list == nullptr) {
            return const <MpvSeekableRange>[];
          }
          final mapList = node.u.list.ref;
          for (var i = 0; i < mapList.num; i++) {
            final keyPtr = mapList.keys[i];
            if (keyPtr == nullptr) continue;
            final key = _safeReadUtf8(keyPtr);
            if (key != 'seekable-ranges') continue;
            final rangesNode = mapList.values[i];
            if (rangesNode.format != MpvFormat.nodeArray ||
                rangesNode.u.list == nullptr) {
              return const <MpvSeekableRange>[];
            }
            final arr = rangesNode.u.list.ref;
            final ranges = <MpvSeekableRange>[];
            for (var j = 0; j < arr.num; j++) {
              final fields = _readNodeMapFields(arr.values[j]);
              if (fields == null) continue;
              final start = _asDouble(fields['start']);
              final end = _asDouble(fields['end']);
              if (start != null && end != null && end >= start) {
                ranges.add(MpvSeekableRange(start: start, end: end));
              }
            }
            return ranges;
          }
          return const <MpvSeekableRange>[];
        }) ??
        const [];
  }

  T? _withNodeProperty<T>(String name, T Function(_MpvNodeNative node) reader) {
    return using((arena) {
      final nodePtr = arena<_MpvNodeNative>();
      final rc = _mpvGetProperty(
        _handle,
        name.toNativeUtf8(allocator: arena),
        MpvFormat.node,
        nodePtr.cast<Void>(),
      );
      if (rc < 0) return null;
      try {
        return reader(nodePtr.ref);
      } finally {
        _mpvFreeNodeContents(nodePtr);
      }
    });
  }

  Map<String, Object?>? _readNodeMapFields(_MpvNodeNative node) {
    if (node.format != MpvFormat.nodeMap || node.u.list == nullptr) {
      return null;
    }
    final list = node.u.list.ref;
    final out = <String, Object?>{};
    for (var i = 0; i < list.num; i++) {
      final keyPtr = list.keys[i];
      if (keyPtr == nullptr) continue;
      final key = _safeReadUtf8(keyPtr);
      out[key] = _readPrimitiveNodeValue(list.values[i]);
    }
    return out;
  }

  Object? _readPrimitiveNodeValue(_MpvNodeNative node) {
    switch (node.format) {
      case MpvFormat.string:
      case MpvFormat.osdString:
        return node.u.string == nullptr ? '' : _safeReadUtf8(node.u.string);
      case MpvFormat.flag:
        return node.u.flag != 0;
      case MpvFormat.int64:
        return node.u.int64;
      case MpvFormat.double_:
        return node.u.double_;
      case MpvFormat.byteArray:
        if (node.u.ba == nullptr) return null;
        final ba = node.u.ba.ref;
        if (ba.data == nullptr || ba.size <= 0) return Uint8List(0);
        return Uint8List.fromList(ba.data.asTypedList(ba.size));
      default:
        return null;
    }
  }

  @override
  int observeProperty(int replyUserdata, String name, int format) {
    if (_disposed) return -1;
    return using((arena) {
      return _mpvObserveProperty(
        _handle,
        replyUserdata,
        name.toNativeUtf8(allocator: arena),
        format,
      );
    });
  }

  @override
  int unobserveProperty(int registeredReplyUserdata) {
    if (_disposed) return -1;
    return _mpvUnobserveProperty(_handle, registeredReplyUserdata);
  }

  @override
  int requestLogMessages(String minLevel) {
    if (_disposed) return -1;
    return using((arena) {
      return _mpvRequestLogMessages(
        _handle,
        minLevel.toNativeUtf8(allocator: arena),
      );
    });
  }

  @override
  int command(List<String> args) {
    if (_disposed || args.isEmpty) return -1;
    return using((arena) {
      final argv = arena<Pointer<Utf8>>(args.length + 1);
      for (var i = 0; i < args.length; i++) {
        argv[i] = args[i].toNativeUtf8(allocator: arena);
      }
      argv[args.length] = nullptr;
      return _mpvCommand(_handle, argv);
    });
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) {
    if (_disposed || args.isEmpty) return -1;
    return using((arena) {
      final argv = arena<Pointer<Utf8>>(args.length + 1);
      for (var i = 0; i < args.length; i++) {
        argv[i] = args[i].toNativeUtf8(allocator: arena);
      }
      argv[args.length] = nullptr;
      return _mpvCommandAsync(_handle, replyUserdata, argv);
    });
  }

  static const int _renderParamInvalid = 0;
  static const int _renderParamApiType = 1;
  static const int _renderParamBlockForTargetTime = 12;
  static const int _renderParamSwSize = 17;
  static const int _renderParamSwFormat = 18;
  static const int _renderParamSwStride = 19;
  static const int _renderParamSwPointer = 20;
  static const int _renderUpdateFrame = 1;

  @override
  Stream<void> get softwareRenderUpdates => _renderUpdatesController.stream;

  @override
  bool initSoftwareRenderer({int width = 192, int height = 108}) {
    if (_disposed || !_initialized || _handle == nullptr) return false;
    if (_renderCtx != nullptr) return true;
    final safeW = LibMpvSoftwareFrameSource.alignDimension(width);
    final safeH = LibMpvSoftwareFrameSource.alignDimension(height);

    try {
      final renderCreate = _library.lookupFunction<
          _MpvRenderContextCreateNative, _MpvRenderContextCreateDart>(
        'mpv_render_context_create',
      );
      _mpvRenderSetUpdateCb ??= _library.lookupFunction<
          _MpvRenderContextSetUpdateCallbackNative,
          _MpvRenderContextSetUpdateCallbackDart>(
        'mpv_render_context_set_update_callback',
      );
      _mpvRenderUpdate ??= _library.lookupFunction<
          _MpvRenderContextUpdateNative, _MpvRenderContextUpdateDart>(
        'mpv_render_context_update',
      );
      _mpvRenderRender ??= _library.lookupFunction<
          _MpvRenderContextRenderNative, _MpvRenderContextRenderDart>(
        'mpv_render_context_render',
      );
      _mpvRenderFree ??= _library.lookupFunction<
          _MpvRenderContextFreeNative, _MpvRenderContextFreeDart>(
        'mpv_render_context_free',
      );

      final ctxOut = using((arena) {
        final outPtr = arena<Pointer<Void>>();
        final apiStr = 'sw'.toNativeUtf8(allocator: arena);
        final params = arena<_MpvRenderParamNative>(2);
        params[0].type = _renderParamApiType;
        params[0].data = apiStr.cast<Void>();
        params[1].type = _renderParamInvalid;
        params[1].data = nullptr;
        final rc = renderCreate(outPtr, _handle, params);
        return rc >= 0 ? outPtr.value : nullptr;
      });
      if (ctxOut == nullptr) return false;

      _renderCtx = ctxOut;
      _ensureSwPixelBuffer(safeW, safeH);
      _renderWakeupCallable?.close();
      _renderWakeupCallable = NativeCallable<_MpvWakeupNative>.listener(
        _onRenderFrameUpdate,
      );
      _mpvRenderSetUpdateCb!(
        _renderCtx,
        _renderWakeupCallable!.nativeFunction,
        nullptr,
      );
      return true;
    } catch (_) {
      releaseSoftwareRenderer();
      return false;
    }
  }

  void _onRenderFrameUpdate(Pointer<Void> _) {
    if (_disposed || _renderCtx == nullptr || _renderUpdatesController.isClosed) {
      return;
    }
    _renderUpdatesController.add(null);
  }

  Pointer<Uint8> _ensureSwPixelBuffer(int width, int height) {
    final safeW = LibMpvSoftwareFrameSource.alignDimension(width);
    final safeH = LibMpvSoftwareFrameSource.alignDimension(height);
    final needed = safeW * safeH * 4 + 64;
    final current = _swPixelRawBuffer;
    if (current != null &&
        current != nullptr &&
        _swPixelBufferCapacity >= needed) {
      final alignedAddr = (current.address + 63) & ~63;
      return Pointer<Uint8>.fromAddress(alignedAddr);
    }
    if (current != null && current != nullptr) {
      calloc.free(current);
      _swPixelRawBuffer = null;
    }
    final allocated = calloc<Uint8>(needed);
    _swPixelRawBuffer = allocated;
    _swPixelBufferCapacity = needed;
    final alignedAddr = (allocated.address + 63) & ~63;
    return Pointer<Uint8>.fromAddress(alignedAddr);
  }

  @override
  bool pollSoftwareFrameReady() {
    if (_disposed || _renderCtx == nullptr || _mpvRenderUpdate == null) {
      return false;
    }
    final flags = _mpvRenderUpdate!(_renderCtx);
    return (flags & _renderUpdateFrame) != 0;
  }

  @override
  Uint8List? renderSoftwareFrameBmp({int width = 192, int height = 108}) {
    if (_disposed || _renderCtx == nullptr || _mpvRenderRender == null) {
      return null;
    }
    if (width <= 0 || height <= 0) return null;
    final safeW = LibMpvSoftwareFrameSource.alignDimension(width);
    final safeH = LibMpvSoftwareFrameSource.alignDimension(height);

    final alignedBuf = _ensureSwPixelBuffer(safeW, safeH);
    final strideBytes = safeW * 4;
    final rc = using((arena) {
      final sizeArr = arena<Int32>(2);
      sizeArr[0] = safeW;
      sizeArr[1] = safeH;
      final fmtStr = 'rgb0'.toNativeUtf8(allocator: arena);
      final stridePtr = arena<Size>();
      stridePtr.value = strideBytes;
      final blockPtr = arena<Int32>();
      blockPtr.value = 0;

      final params = arena<_MpvRenderParamNative>(6);
      params[0].type = _renderParamSwSize;
      params[0].data = sizeArr.cast<Void>();
      params[1].type = _renderParamSwFormat;
      params[1].data = fmtStr.cast<Void>();
      params[2].type = _renderParamSwStride;
      params[2].data = stridePtr.cast<Void>();
      params[3].type = _renderParamSwPointer;
      params[3].data = alignedBuf.cast<Void>();
      params[4].type = _renderParamBlockForTargetTime;
      params[4].data = blockPtr.cast<Void>();
      params[5].type = _renderParamInvalid;
      params[5].data = nullptr;
      return _mpvRenderRender!(_renderCtx, params);
    });
    if (rc < 0) return null;

    // 直接基于原生对齐像素视图编码目标 24-bit BMP，省去冗余整帧中间拷贝。
    return encodeRgb0ToBmp(
      alignedBuf.asTypedList(safeW * safeH * 4),
      safeW,
      safeH,
    );
  }

  @override
  void releaseSoftwareRenderer() {
    final ctx = _renderCtx;
    _renderCtx = nullptr;
    if (ctx != nullptr) {
      try {
        _mpvRenderSetUpdateCb?.call(ctx, nullptr, nullptr);
      } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.libmpv_ffi', error: error);
    }
      try {
        _mpvRenderFree?.call(ctx);
      } catch (error) {
      developer.log('可恢复异常已记录', name: 'konata.libmpv_ffi', error: error);
    }
    }
    _renderWakeupCallable?.close();
    _renderWakeupCallable = null;
    final rawBuf = _swPixelRawBuffer;
    _swPixelRawBuffer = null;
    _swPixelBufferCapacity = 0;
    if (rawBuf != null && rawBuf != nullptr) {
      calloc.free(rawBuf);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // 必须先释放 mpv_render_context 再销毁 mpv_handle，遵循 render.h 生命周期约束
    releaseSoftwareRenderer();
    if (!_renderUpdatesController.isClosed) {
      await _renderUpdatesController.close();
    }

    final ptrAddress = _handle.address;
    if (_initialized && ptrAddress != 0) {
      _mpvSetWakeupCallback(_handle, nullptr, nullptr);
    }
    _wakeupCallable?.close();
    _wakeupCallable = null;
    _handle = nullptr;

    if (!_eventsController.isClosed) {
      await _eventsController.close();
    }

    if (ptrAddress == 0) return;

    final libraryPath = _libraryPath;
    await Isolate.run(() {
      final lib = DynamicLibrary.open(libraryPath);
      final terminateDestroy = lib
          .lookupFunction<_MpvTerminateDestroyNative, _MpvTerminateDestroyDart>(
            'mpv_terminate_destroy',
          );
      terminateDestroy(Pointer<Void>.fromAddress(ptrAddress));
    });
  }

  static String _safeReadUtf8(Pointer<Utf8> ptr) {
    if (ptr == nullptr) return '';
    try {
      return ptr.toDartString();
    } catch (_) {
      final bytes = ptr.cast<Uint8>();
      final buf = <int>[];
      var i = 0;
      while (i < 65536) {
        final b = bytes[i];
        if (b == 0) break;
        buf.add(b);
        i++;
      }
      return String.fromCharCodes(buf);
    }
  }

  static String _asString(Object? value) => value is String ? value : '';
  static bool _asBool(Object? value) => value is bool ? value : false;
  static int? _asInt(Object? value) => value is int
      ? value
      : (value is double ? value.round() : null);
  static double? _asDouble(Object? value) => value is double
      ? value
      : (value is int ? value.toDouble() : null);
}
