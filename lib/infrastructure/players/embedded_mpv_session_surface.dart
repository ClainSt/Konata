part of 'embedded_mpv_session.dart';

/// `EmbeddedMpvSession` 硬件表面热重绑、Windows D3D11 缩放与双模原画截图扩展。
extension EmbeddedMpvSessionSurface on EmbeddedMpvSession {
  static const MethodChannel _mediaStoreChannel = MethodChannel(
    'ccplayer/media_store',
  );

  /// 初始化底层 `libmpv` 实例并挂接桌面 10-bit/HDR 底层直通（`vo=gpu-next` / 分层交换链）或兼容纹理回退。
  Future<({LibMpvClient client, PlaybackQualityConfig effectiveConfig})>
  _initializeMpvClientAndDesktopBackend({
    required EmbeddedVideoLoadRequest request,
    required PlaybackQualityConfig qualityConfig,
    required Directory mpvDir,
    required Directory workPhotoDir,
    required List<String> verifiedShaders,
    required bool isRemote,
    required bool useDesktopSurface,
  }) async {
    var effectiveConfig = qualityConfig;
    NativeVideoSessionHandle? preCreatedGpuNextHandle;
    final wantDesktopGpuNext =
        useDesktopSurface &&
        desktopSurfaceBridge != null &&
        qualityConfig.outputPipelineMode ==
            VideoOutputPipelineMode.gpuNextUnderlay &&
        qualityConfig.hardwareDecode &&
        qualityConfig.preset != VideoQualityPreset.softwareFallback;

    if (wantDesktopGpuNext) {
      try {
        final handle = await desktopSurfaceBridge!.createSession(
          mpvHandleAddress: 0,
          width: request.initialWidth,
          height: request.initialHeight,
          preferSoftware: false,
          renderBackend: VideoOutputPipelineMode.gpuNextUnderlay.bridgeKey,
        );
        if (handle.nativeWindowHandle > 0 && handle.backend == 'gpu_next') {
          preCreatedGpuNextHandle = handle;
        } else {
          await desktopSurfaceBridge!.disposeSession(handle.sessionId);
          effectiveConfig = qualityConfig.copyWith(
            outputPipelineMode: VideoOutputPipelineMode.layered10Bit,
          );
        }
      } catch (e) {
        logStore?.record(
          'mpv-desktop-render',
          'gpu_next 底层子窗口创建失败，自动回落至 10-bit 底层合成交换链：$e',
        );
        effectiveConfig = qualityConfig.copyWith(
          outputPipelineMode: VideoOutputPipelineMode.layered10Bit,
        );
      }
    }

    var client = clientFactory != null
        ? clientFactory!()
        : FfiLibMpvClient.create();
    _client = client;

    final hwdecValue = MpvQualityProfile.resolveHwdecValue(
      config: effectiveConfig,
      isWindows: useDesktopSurface,
      isAndroid: _useAndroidSurfaceSession,
      desktopDelegate: desktopProfileDelegate,
    );
    _hwdecWasEnabled = hwdecValue != 'no';
    _usingSoftwareFallback = !_hwdecWasEnabled;

    MpvQualityProfile.applyPreInitVideoOptions(
      client,
      config: effectiveConfig,
      mpvConfigDir: mpvDir,
      screenshotDir: workPhotoDir,
      isRemoteStream: isRemote,
      isWindowsOverride: useDesktopSurface,
      isAndroidOverride: _useAndroidSurfaceSession,
      desktopUnderlayHwnd: preCreatedGpuNextHandle?.nativeWindowHandle,
      desktopDelegate: desktopProfileDelegate,
      verifiedShaderPaths: verifiedShaders,
      logStore: logStore,
    );

    var initRc = client.initialize();
    if (initRc < 0 && preCreatedGpuNextHandle != null) {
      // 老旧显卡或驱动无法初始化 vo=gpu-next 时安全销毁并透明回落至 vo=libmpv 管线。
      logStore?.record(
        'mpv-desktop-render',
        'vo=gpu-next 初始化失败 (${client.errorString(initRc)})，回落至 vo=libmpv',
      );
      await client.dispose();
      await desktopSurfaceBridge!.disposeSession(
        preCreatedGpuNextHandle.sessionId,
      );
      preCreatedGpuNextHandle = null;
      effectiveConfig = qualityConfig.copyWith(
        outputPipelineMode: VideoOutputPipelineMode.layered10Bit,
      );
      client = clientFactory != null
          ? clientFactory!()
          : FfiLibMpvClient.create();
      _client = client;
      MpvQualityProfile.applyPreInitVideoOptions(
        client,
        config: effectiveConfig,
        mpvConfigDir: mpvDir,
        screenshotDir: workPhotoDir,
        isRemoteStream: isRemote,
        isWindowsOverride: useDesktopSurface,
        isAndroidOverride: _useAndroidSurfaceSession,
        desktopDelegate: desktopProfileDelegate,
        verifiedShaderPaths: verifiedShaders,
        logStore: logStore,
      );
      initRc = client.initialize();
    }
    if (initRc < 0) {
      if (preCreatedGpuNextHandle != null && desktopSurfaceBridge != null) {
        await desktopSurfaceBridge!.disposeSession(
          preCreatedGpuNextHandle.sessionId,
        );
      }
      throw StateError('内置播放器初始化失败: ${client.errorString(initRc)}');
    }

    client.requestLogMessages('warn');
    _cachedMpvVersion = client.getPropertyString('mpv-version');
    _cachedFfmpegVersion = client.getPropertyString('ffmpeg-version');

    if (preCreatedGpuNextHandle != null) {
      _desktopSurfaceSessionId = preCreatedGpuNextHandle.sessionId;
      _usingGpuNextUnderlay = true;
      _textureId.value = -1;
      _underlayActive.value = true;
      _renderBackend.value = preCreatedGpuNextHandle.backend;
      _adapterName.value = preCreatedGpuNextHandle.adapterName;
    } else if (useDesktopSurface && desktopSurfaceBridge != null) {
      final handle = await desktopSurfaceBridge!.createSession(
        mpvHandleAddress: client.handleAddress,
        width: request.initialWidth,
        height: request.initialHeight,
        preferSoftware:
            !effectiveConfig.hardwareDecode ||
            effectiveConfig.preset == VideoQualityPreset.softwareFallback,
        renderBackend: effectiveConfig.outputPipelineMode.bridgeKey,
      );
      _desktopSurfaceSessionId = handle.sessionId;
      _usingGpuNextUnderlay = false;
      _textureId.value = handle.textureId;
      _underlayActive.value = handle.isUnderlayMode;
      _renderBackend.value = handle.backend;
      _adapterName.value = handle.adapterName;
      if (handle.isSoftwareFallback) {
        _usingSoftwareFallback = true;
      }
      _desktopSurfaceChangeSub = desktopSurfaceBridge!.textureChanges.listen((
        event,
      ) {
        if (_disposed || event.sessionId != _desktopSurfaceSessionId) return;
        _textureId.value = event.textureId;
        _underlayActive.value = event.textureId < 0 && event.backend != 'sw';
        _renderBackend.value = event.backend;
        _adapterName.value = event.adapterName;
        if (event.backend == 'sw') {
          _usingSoftwareFallback = true;
        }
        if (event.reason.isNotEmpty) {
          onNotice?.call(
            event.backend == 'sw'
                ? '图形设备已切换为软件兼容渲染 (${event.reason})'
                : '桌面视频渲染表面已重建',
          );
        }
      });
    }

    return (client: client, effectiveConfig: effectiveConfig);
  }

  /// 同步更新运行中的桌面端渲染目标分辨率。
  Future<void> resizeDesktopSurfaceTarget(int width, int height) async {
    final id = _desktopSurfaceSessionId;
    final bridge = desktopSurfaceBridge;
    if (_disposed || id == null || bridge == null || !Platform.isWindows) {
      return;
    }
    await bridge.resize(sessionId: id, width: width, height: height);
  }

  /// 同步桌面端底层 10-bit/HDR 渲染宿主的物理像素视口矩形、圆角裁剪与显隐状态。
  Future<void> setWindowsUnderlayViewport({
    required int leftPx,
    required int topPx,
    required int rightPx,
    required int bottomPx,
    double cornerRadiusPx = 0.0,
    bool visible = true,
  }) async {
    final id = _desktopSurfaceSessionId;
    final bridge = desktopSurfaceBridge;
    if (_disposed || id == null || bridge == null || !Platform.isWindows) {
      return;
    }
    await bridge.setViewportRect(
      sessionId: id,
      leftPx: leftPx,
      topPx: topPx,
      rightPx: rightPx,
      bottomPx: bottomPx,
      cornerRadiusPx: cornerRadiusPx,
      visible: visible,
    );
  }

  /// 截取纯净原画 PNG 视频帧（不含 UI/HUD 浮层），保存至作品目录并防重名。
  Future<File?> captureCleanScreenshot({
    required Directory workPhotoDir,
    String? episodeTag,
    ScreenshotCaptureMode mode = ScreenshotCaptureMode.pureVideo,
  }) async {
    final res = await captureScreenshot(
      workPhotoDir: workPhotoDir,
      episodeTag: episodeTag,
      mode: mode,
    );
    return res?.file;
  }

  /// 双模原画截图（支持 `video` 纯净帧与 `subtitles` 含字幕帧）：
  /// - 统一通过 FFI 参数数组 `["screenshot-to-file", path, mode]` 调用，零字符串转义风险；
  /// - Android 端通过 `MediaStore` `IS_PENDING` 事务原子写入系统相册并幂等删除临时文件。
  Future<ScreenshotCaptureResult?> captureScreenshot({
    required Directory workPhotoDir,
    String? episodeTag,
    ScreenshotCaptureMode mode = ScreenshotCaptureMode.pureVideo,
    String albumName = 'Konata',
    Future<String?> Function(File tempFile, String displayName, String album)?
    androidMediaStorePublisher,
  }) async {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) return null;
    final targetFile = await storageRoot.allocateWorkScreenshotFile(
      workPhotoDirectory: workPhotoDir,
      timestamp: DateTime.now(),
      episodeTag: episodeTag,
    );
    final rc = client.command([
      'screenshot-to-file',
      targetFile.path,
      mode.mpvFlag,
    ]);
    if (rc < 0) return null;
    var ready = false;
    for (var i = 0; i < 10; i++) {
      if (await targetFile.exists() && await targetFile.length() > 0) {
        ready = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
    if (!ready && !await targetFile.exists()) {
      return null;
    }

    final useAndroidGallery =
        Platform.isAndroid || androidMediaStorePublisher != null;
    if (useAndroidGallery) {
      final displayName = p.basename(targetFile.path);
      try {
        final uri = androidMediaStorePublisher != null
            ? await androidMediaStorePublisher(
                targetFile,
                displayName,
                albumName,
              )
            : await _mediaStoreChannel.invokeMethod<String>(
                'saveImageToGallery',
                <String, Object>{
                  'sourcePath': targetFile.path,
                  'displayName': displayName,
                  'albumName': albumName,
                  'mimeType': 'image/png',
                },
              );
        if (uri != null && uri.isNotEmpty) {
          return ScreenshotCaptureResult(
            mode: mode,
            displayLabel: '系统相册 / Pictures/$albumName/$displayName',
            galleryUri: uri,
          );
        }
      } catch (e) {
        logStore?.record(
          'screenshot-mediastore',
          'MediaStore publish failed: $e',
          isError: true,
        );
      } finally {
        try {
          if (await targetFile.exists()) {
            await targetFile.delete();
          }
        } catch (e) {
          logStore?.record(
            'screenshot-mediastore',
            '删除相册发布临时截图文件失败：$e',
          );
        }
      }
      return null;
    }

    return ScreenshotCaptureResult(
      mode: mode,
      displayLabel: targetFile.path,
      file: targetFile,
    );
  }

  Future<Directory> _resolveScreenshotDir(String workId) async {
    final photosRoot = await storageRoot.photosRootDir();
    final safeTag = StorageRootService.encodeWorkIdTag(workId);
    return Directory(p.join(photosRoot.path, 'work [$safeTag]'));
  }

  /// Android 画中画退出或回前台时按需重绑当前底层 `Surface`（不重建解码器与播放会话）。
  Future<void> rebindCurrentAndroidSurface() async {
    final surf = _androidSurface;
    if (_disposed ||
        !_useAndroidSurfaceSession ||
        !_videoTrackEnabled ||
        surf == null ||
        surf.isDisposed) {
      return;
    }
    final desc = await surf.queryCurrent();
    if (_disposed || desc == null || desc.wid <= 0) return;
    await _enqueueAndroidSurfaceUpdate(desc, sourceCtrl: surf);
  }

  /// Android 运行期间动态接入或热重绑硬件视频表面，避免路由或容器变更后丢帧黑屏。
  Future<void> attachOrRebindAndroidSurface(
    AndroidVideoSurfaceController ctrl,
  ) async {
    if (_disposed || !_useAndroidSurfaceSession || ctrl.isDisposed) return;
    if (identical(_androidSurface, ctrl)) {
      final desc = await ctrl.queryCurrent();
      if (_disposed || desc == null) return;
      await _enqueueAndroidSurfaceUpdate(desc, sourceCtrl: ctrl);
      return;
    }

    await _androidSurfaceSub?.cancel();
    _androidSurfaceSub = null;
    final previous = _androidSurface;
    _bindAndroidSurfaceController(ctrl);

    // 底层 SurfaceView 在整个进程内为单例宿主：热重绑仅分离旧控制器事件流，
    // 严禁调用 releaseAll 误杀新控制器正在使用的同一原生表面句柄与 JNI 全局引用。
    if (previous != null && !previous.isDisposed) {
      await previous.detachWithoutClearingChannel();
    }
    if (_disposed || ctrl.isDisposed) return;

    var desc = await ctrl.queryCurrent();
    if (desc == null || desc.wid <= 0 || desc.width <= 0 || desc.height <= 0) {
      try {
        desc = await ctrl.surfaceChanges
            .where(
              (e) => e != null && e.wid > 0 && e.width > 0 && e.height > 0,
            )
            .cast<AndroidSurfaceDescriptor>()
            .first
            .timeout(const Duration(milliseconds: 2500));
      } on TimeoutException {
        desc = ctrl.current;
      }
    }
    if (_disposed || desc == null) return;
    await _enqueueAndroidSurfaceUpdate(desc, sourceCtrl: ctrl);
  }

  void _bindAndroidSurfaceController(AndroidVideoSurfaceController ctrl) {
    _androidSurface = ctrl;
    unawaited(_androidSurfaceSub?.cancel());
    _androidSurfaceSub = ctrl.surfaceChanges.listen((next) {
      if (_disposed || _client == null || _client!.isDisposed) return;
      unawaited(_enqueueAndroidSurfaceUpdate(next, sourceCtrl: ctrl));
    });
  }

  Future<void> _enqueueAndroidSurfaceUpdate(
    AndroidSurfaceDescriptor? desc, {
    AndroidVideoSurfaceController? sourceCtrl,
    bool forceRebind = false,
  }) {
    final op = _androidSurfaceSerial.then((_) async {
      await _applyAndroidSurfaceUpdate(
        desc,
        sourceCtrl: sourceCtrl,
        forceRebind: forceRebind,
      );
    });
    _androidSurfaceSerial = op.catchError((Object e, StackTrace _) {
      logStore?.record('mpv-surface', 'Android 表面更新任务异常：$e', isError: true);
    });
    return op;
  }

  Future<void> _applyAndroidSurfaceUpdate(
    AndroidSurfaceDescriptor? desc, {
    AndroidVideoSurfaceController? sourceCtrl,
    bool forceRebind = false,
  }) async {
    final client = _client;
    if (_disposed ||
        client == null ||
        client.isDisposed ||
        !client.isInitialized) {
      return;
    }

    final nextWid = desc?.wid ?? 0;
    final width = desc?.width ?? 0;
    final height = desc?.height ?? 0;
    final hdrPeak = (desc?.hdrPeak ?? 0).round();

    if (nextWid != 0 && (width <= 0 || height <= 0)) {
      return;
    }

    // 同一 Surface 仅像素尺寸变化时原地更新 android-surface-size，避免重开 VO 打断硬解
    if (!forceRebind &&
        nextWid != 0 &&
        nextWid == _boundAndroidWid &&
        hdrPeak == _boundAndroidHdrPeak) {
      if (width != _boundAndroidWidth || height != _boundAndroidHeight) {
        client.setPropertyString('android-surface-size', '${width}x$height');
        _boundAndroidWidth = width;
        _boundAndroidHeight = height;
      }
      if (_videoTrackEnabled &&
          client.getPropertyString('vo') != _activeAndroidVo) {
        _applyAndroidVo(client);
      }
      return;
    }

    // 更换或卸载 Surface 前必须先置空 vo=null 与 wid=0 安全释放旧 EGLSurface
    final previousWid = _boundAndroidWid;
    client.setPropertyString('vo', 'null');
    client.setPropertyString('wid', '0');
    _boundAndroidWid = 0;
    _boundAndroidWidth = 0;
    _boundAndroidHeight = 0;
    _boundAndroidHdrPeak = -1;

    if (previousWid != 0 && previousWid != nextWid) {
      await (sourceCtrl ?? _androidSurface)?.releaseReference(previousWid);
      if (_disposed || client.isDisposed || !client.isInitialized) return;
    }

    if (nextWid <= 0) {
      return;
    }

    client.setPropertyString('android-hdr-peak', '$hdrPeak');
    client.setPropertyString('android-surface-size', '${width}x$height');
    client.setPropertyString('wid', '$nextWid');
    _boundAndroidWid = nextWid;
    _boundAndroidWidth = width;
    _boundAndroidHeight = height;
    _boundAndroidHdrPeak = hdrPeak;

    if (_videoTrackEnabled) {
      _applyAndroidVo(client);
      final vid = client.getPropertyString('vid');
      if (vid == 'no') {
        client.setPropertyString('vid', _savedVidBeforeDisable ?? 'auto');
      }
      if (client.getPropertyFlag('pause') ?? false) {
        client.command(['seek', '0', 'relative', 'exact']);
      }
    }
  }

  /// 优先挂载 `vo=gpu-next`（libplacebo 杜比视界/动态 HDR 管线），若底层驱动受限则平滑回落至 `vo=gpu`。
  void _applyAndroidVo(LibMpvClient client) {
    final rc = client.setPropertyString(
      'vo',
      MpvQualityProfile.androidVideoDriver,
    );
    if (rc >= 0) {
      _activeAndroidVo = MpvQualityProfile.androidVideoDriver;
    } else {
      client.setPropertyString('vo', MpvQualityProfile.androidLegacyVideoDriver);
      _activeAndroidVo = MpvQualityProfile.androidLegacyVideoDriver;
    }
    _renderBackend.value = _activeAndroidVo;
  }

  void _scheduleFirstFrameWatchdog({
    Duration delay = const Duration(milliseconds: 2500),
  }) {
    _firstFrameWatchdogTimer?.cancel();
    final gen = _loadGeneration;
    _firstFrameWatchdogTimer = Timer(
      delay,
      () => unawaited(_verifyFirstFrameRenderedOrRecover(gen)),
    );
  }

  Future<void> _verifyFirstFrameRenderedOrRecover(int generation) async {
    final client = _client;
    if (_disposed ||
        generation != _loadGeneration ||
        !_videoTrackEnabled ||
        _hasRestartedFirstFrame ||
        client == null ||
        client.isDisposed ||
        !client.isInitialized) {
      return;
    }
    // 像素表面句柄有效但解码器持续未产出首帧像素格式，说明硬件解码器卡死，直接切软解。
    if (_boundAndroidWid > 0 &&
        !_hasDecodedVideoFrame() &&
        !_hwdecFallbackAttempted &&
        _hwdecWasEnabled) {
      _triggerSoftwareDecodeFallback();
      return;
    }
    if (!_firstFrameWatchdogReboundOnce) {
      _firstFrameWatchdogReboundOnce = true;
      final surf = _androidSurface;
      if (surf != null && !surf.isDisposed) {
        final desc = await surf.queryCurrent();
        if (desc != null &&
            desc.wid > 0 &&
            desc.width > 0 &&
            desc.height > 0 &&
            !_disposed &&
            generation == _loadGeneration) {
          await _enqueueAndroidSurfaceUpdate(
            desc,
            sourceCtrl: surf,
            forceRebind: true,
          );
          _scheduleFirstFrameWatchdog();
          return;
        }
      }
    }
    if (!_hwdecFallbackAttempted && _hwdecWasEnabled) {
      _triggerSoftwareDecodeFallback();
    }
  }
}
