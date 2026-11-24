part of 'embedded_mpv_session.dart';

/// `EmbeddedMpvSession` 硬件表面热重绑、Windows D3D11 缩放与双模原画截图扩展。
extension EmbeddedMpvSessionSurface on EmbeddedMpvSession {
  /// 经统一播放内核互斥申请唯一原生 `LibMpvClient`（禁止在会话层私自实例化 `FfiLibMpvClient`）。
  Future<LibMpvClient> _acquireManagedNativeClient() async {
    if (nativeClientAcquirer != null) {
      final acquired = await nativeClientAcquirer!(
        onEvicted: () async {
          await _eventSub?.cancel();
          _eventSub = null;
          await _desktopSurfaceChangeSub?.cancel();
          _desktopSurfaceChangeSub = null;
          final surfaceSessionId = _desktopSurfaceSessionId;
          final wasGpuNextUnderlay = _usingGpuNextUnderlay;
          if (surfaceSessionId != null &&
              surfaceSessionId > 0 &&
              desktopSurfaceBridge != null) {
            if (wasGpuNextUnderlay) {
              // vo=gpu-next 持有底层子窗口，先隐藏视口并解绑 wid，待引擎销毁 libmpv 后再清理子窗口。
              await desktopSurfaceBridge!.setViewportRect(
                sessionId: surfaceSessionId,
                leftPx: 0,
                topPx: 0,
                rightPx: 0,
                bottomPx: 0,
                visible: false,
              );
            } else {
              // vo=libmpv 的 C++ 渲染上下文绑定在 mpv_handle 上，必须在 mpv_terminate_destroy 前释放，
              // 否则 libmpv 会触发致命断言导致 ucrtbase.dll 0xc0000409 闪退。
              _desktopSurfaceSessionId = null;
              _setTextureId(null);
              _setUnderlayActive(false);
              await desktopSurfaceBridge!.disposeSession(surfaceSessionId);
            }
          }
          final active = _client;
          _client = null;
          if (active != null && !active.isDisposed && active.isInitialized) {
            if (wasGpuNextUnderlay || _useAndroidSurfaceSession) {
              active.setPropertyString('vo', 'null');
              active.setPropertyString('wid', '0');
            }
          }
        },
      );
      onNativeClientBound?.call(acquired);
      return acquired;
    }
    if (clientFactory != null) {
      final created = clientFactory!();
      onNativeClientBound?.call(created);
      return created;
    }
    throw StateError(
      'EmbeddedMpvSession 必须经 UnifiedPlaybackEngine（nativeClientAcquirer）或测试 clientFactory 申请唯一 LibMpvClient',
    );
  }

  /// 初始化底层 `libmpv` 实例并挂接桌面 10-bit/HDR 底层直通（`vo=gpu-next` / 分层交换链）或兼容纹理回退。
  Future<({LibMpvClient client, PlaybackQualityConfig effectiveConfig})>
  _initializeMpvClientAndDesktopBackend({
    required EmbeddedVideoLoadRequest request,
    required PlaybackQualityConfig qualityConfig,
    required Directory mpvDir,
    required Directory workPhotoDir,
    Directory? gpuShaderCacheDir,
    Directory? iccCacheDir,
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
        PlaybackLogHelper.record(logStore, 
          'mpv-desktop-render',
          'gpu_next 底层子窗口创建失败，自动回落至 10-bit 底层合成交换链：$e',
        );
        effectiveConfig = qualityConfig.copyWith(
          outputPipelineMode: VideoOutputPipelineMode.layered10Bit,
        );
      }
    }

    var client = await _acquireManagedNativeClient();
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
      gpuShaderCacheDir: gpuShaderCacheDir,
      iccCacheDir: iccCacheDir,
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
      PlaybackLogHelper.record(logStore, 
        'mpv-desktop-render',
        'vo=gpu-next 初始化失败 (${client.errorString(initRc)})，回落至 vo=libmpv',
      );
      if (nativeClientReleaser != null) {
        await nativeClientReleaser!(client);
      } else {
        await client.dispose();
      }
      await desktopSurfaceBridge!.disposeSession(
        preCreatedGpuNextHandle.sessionId,
      );
      preCreatedGpuNextHandle = null;
      effectiveConfig = qualityConfig.copyWith(
        outputPipelineMode: VideoOutputPipelineMode.layered10Bit,
      );
      client = await _acquireManagedNativeClient();
      _client = client;
      MpvQualityProfile.applyPreInitVideoOptions(
        client,
        config: effectiveConfig,
        mpvConfigDir: mpvDir,
        screenshotDir: workPhotoDir,
        gpuShaderCacheDir: gpuShaderCacheDir,
        iccCacheDir: iccCacheDir,
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
      if (nativeClientReleaser != null) {
        await nativeClientReleaser!(client);
      } else {
        await client.dispose();
      }
      _client = null;
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
      _setTextureId(-1);
      _setUnderlayActive(true);
      _setRenderBackend(preCreatedGpuNextHandle.backend);
      _setAdapterName(preCreatedGpuNextHandle.adapterName);
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
      _setTextureId(handle.textureId);
      _setUnderlayActive(handle.isUnderlayMode);
      _setRenderBackend(handle.backend);
      _setAdapterName(handle.adapterName);
      if (handle.isSoftwareFallback) {
        _usingSoftwareFallback = true;
      }
      _desktopSurfaceChangeSub = desktopSurfaceBridge!.textureChanges.listen((
        event,
      ) {
        if (_disposed || event.sessionId != _desktopSurfaceSessionId) return;
        _setTextureId(event.textureId);
        _setUnderlayActive(event.textureId < 0 && event.backend != 'sw');
        _setRenderBackend(event.backend);
        _setAdapterName(event.adapterName);
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
    if (_disposed || id == null || bridge == null || !_isWindows) {
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
    if (_disposed || id == null || bridge == null || !_isWindows) {
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
    final targetFile = await PlaybackStoragePaths.allocateWorkScreenshotFile(
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
      if (targetFile.existsSync() && targetFile.lengthSync() > 0) {
        ready = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
    if (!ready && !targetFile.existsSync()) {
      return null;
    }

    final useAndroidGallery =
        _isAndroid ||
        androidMediaStorePublisher != null ||
        mediaStorePublisher != null;
    if (useAndroidGallery) {
      final displayName = p.basename(targetFile.path);
      try {
        final uri = androidMediaStorePublisher != null
            ? await androidMediaStorePublisher(
                targetFile,
                displayName,
                albumName,
              )
            : await mediaStorePublisher?.saveImageToGallery(
                tempFile: targetFile,
                displayName: displayName,
                albumName: albumName,
              );
        if (uri != null && uri.isNotEmpty) {
          return ScreenshotCaptureResult(
            mode: mode,
            displayLabel: '系统相册 / Pictures/$albumName/$displayName',
            galleryUri: uri,
          );
        }
      } catch (e) {
        PlaybackLogHelper.record(logStore, 
          'screenshot-mediastore',
          'MediaStore publish failed: $e',
          isError: true,
        );
      } finally {
        try {
          if (targetFile.existsSync()) {
            await targetFile.delete();
          }
        } catch (e) {
          PlaybackLogHelper.record(logStore, 
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
    final photosRoot = await storageRoot.resolvePhotosDirPath();
    final safeTag = PlaybackStoragePaths.encodeWorkIdTag(workId);
    return Directory(p.join(photosRoot, 'work [$safeTag]'));
  }

  /// 关闭会话前立即同步静音暂停并解绑底层硬件表面，消除退页残留声音与 Surface 销毁竞态报错。
  void silenceAndDetachForClose() {
    _closingSilenced = true;
    ++_loadGeneration;
    _firstFrameWatchdogTimer?.cancel();
    _firstFrameWatchdogTimer = null;
    final client = _client;
    if (_disposed ||
        client == null ||
        client.isDisposed ||
        !client.isInitialized) {
      return;
    }
    client.setPropertyFlag('pause', true);
    client.setPropertyFlag('mute', true);
    if (_useAndroidSurfaceSession || _usingGpuNextUnderlay) {
      client.setPropertyString('vo', 'null');
      client.setPropertyString('wid', '0');
      _boundAndroidWid = 0;
      _boundAndroidWidth = 0;
      _boundAndroidHeight = 0;
      _boundAndroidHdrPeak = -1;
    }
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
    AndroidVideoSurfacePort ctrl,
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

  void _bindAndroidSurfaceController(AndroidVideoSurfacePort ctrl) {
    _androidSurface = ctrl;
    unawaited(_androidSurfaceSub?.cancel());
    _androidSurfaceSub = ctrl.surfaceChanges.listen((AndroidSurfaceDescriptor? next) {
      if (_disposed || _client == null || _client!.isDisposed) return;
      unawaited(_enqueueAndroidSurfaceUpdate(next, sourceCtrl: ctrl));
    });
  }

  Future<void> _enqueueAndroidSurfaceUpdate(
    AndroidSurfaceDescriptor? desc, {
    AndroidVideoSurfacePort? sourceCtrl,
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
      PlaybackLogHelper.record(logStore, 'mpv-surface', 'Android 表面更新任务异常：$e', isError: true);
    });
    return op;
  }

  Future<void> _applyAndroidSurfaceUpdate(
    AndroidSurfaceDescriptor? desc, {
    AndroidVideoSurfacePort? sourceCtrl,
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
    _setRenderBackend(_activeAndroidVo);
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

  void _applyAspectModeToClient(LibMpvClient client, VideoAspectMode mode) {
    switch (mode) {
      case VideoAspectMode.auto:
        client.setPropertyFlag('keepaspect', true);
        client.setPropertyDouble('panscan', 0.0);
        client.setPropertyString('video-aspect-override', '-1');
      case VideoAspectMode.cover:
        client.setPropertyFlag('keepaspect', true);
        client.setPropertyDouble('panscan', 1.0);
        client.setPropertyString('video-aspect-override', '-1');
      case VideoAspectMode.stretch:
        client.setPropertyFlag('keepaspect', false);
        client.setPropertyDouble('panscan', 0.0);
        client.setPropertyString('video-aspect-override', '-1');
      case VideoAspectMode.ratio16x9:
        client.setPropertyFlag('keepaspect', true);
        client.setPropertyDouble('panscan', 0.0);
        client.setPropertyString('video-aspect-override', '16:9');
      case VideoAspectMode.ratio4x3:
        client.setPropertyFlag('keepaspect', true);
        client.setPropertyDouble('panscan', 0.0);
        client.setPropertyString('video-aspect-override', '4:3');
    }
  }

  /// 装载前依据已解析的结构化视频编码/位深预判硬件解码安全性，避免对已知 Hi10P / HEVC Rext 启动无效 MediaCodec。
  void _applyPreLoadHwdecPolicy(LibMpvClient client, MediaVariantRecord variant) {
    if (!_hwdecWasEnabled || _closingSilenced) return;
    final platform = _useAndroidSurfaceSession
        ? HwdecPlatformKind.android
        : (_isWindows
              ? HwdecPlatformKind.windows
              : HwdecPlatformKind.other);
    final decision = HwdecSafetyPolicy.evaluateVariantMetadata(
      platform: platform,
      videoCodec: variant.videoCodec,
      bitDepth: variant.bitDepth,
    );
    if (!decision.allowHardwareDecode) {
      _hwdecFallbackAttempted = true;
      _usingSoftwareFallback = true;
      _setHwdecWithAndroidVoGuard(client, 'no', threads: '0');
      PlaybackLogHelper.record(logStore, 
        'mpv-hwdec-guard',
        'preload rule=${decision.matchedRule} codec=${variant.videoCodec} bitDepth=${variant.bitDepth} -> hwdec=no',
      );
      onHwdecChanged?.call('no');
      if (decision.reason != null) {
        onNotice?.call(decision.reason!);
      }
      return;
    }
    if (_usingSoftwareFallback) {
      _usingSoftwareFallback = false;
      final restored = MpvQualityProfile.resolveHwdecValue(
        config: _lastQualityConfig,
        isWindows: _isWindows,
        isAndroid: _useAndroidSurfaceSession,
        desktopDelegate: desktopProfileDelegate,
      );
      _setHwdecWithAndroidVoGuard(client, restored);
    }
  }

  /// Android 表面挂载态切换 `hwdec` 时先暂停并置空 `vo=null`，待解码器属性落定后再恢复原画输出，
  /// 避免 MediaCodec 与 `AImageReader` 同步栅栏交叉卸载触发 `-30001` 超时或 `fdsan` 崩溃。
  void _setHwdecWithAndroidVoGuard(
    LibMpvClient client,
    String targetHwdec, {
    String? threads,
  }) {
    final hadBoundSurface =
        _useAndroidSurfaceSession && _boundAndroidWid > 0 && _videoTrackEnabled;
    final wasPaused = hadBoundSurface
        ? (client.getPropertyFlag('pause') ?? false)
        : false;
    if (hadBoundSurface) {
      client.setPropertyFlag('pause', true);
      client.setPropertyString('vo', 'null');
    }
    client.setPropertyString('hwdec', targetHwdec);
    if (threads != null) {
      client.setPropertyString('vd-lavc-threads', threads);
    }
    if (hadBoundSurface && !_closingSilenced) {
      _applyAndroidVo(client);
      client.setPropertyFlag('pause', wasPaused);
    }
  }

  /// 安全执行硬件解码向多线程软解的过渡（支持 `video-reload` 热切与 `loadfile replace` 兜底重载）。
  void _applySoftwareDecodeTransition(
    LibMpvClient client, {
    required bool reloadFile,
  }) {
    final hadBoundSurface =
        _useAndroidSurfaceSession && _boundAndroidWid > 0 && _videoTrackEnabled;
    final wasPaused = client.getPropertyFlag('pause') ?? false;
    if (hadBoundSurface) {
      client.setPropertyFlag('pause', true);
      client.setPropertyString('vo', 'null');
    }
    client.setPropertyString('hwdec', 'no');
    client.setPropertyString('vd-lavc-threads', '0');

    if (reloadFile) {
      final canPreservePos =
          _lastPositionSeconds > 0.5 &&
          (_totalDurationSeconds <= 0 ||
              _lastPositionSeconds < _totalDurationSeconds - 1.0);
      if (canPreservePos) {
        client.setPropertyDouble('start', _lastPositionSeconds);
      } else {
        client.setPropertyString('start', 'none');
      }
      if (hadBoundSurface && !_closingSilenced) {
        _applyAndroidVo(client);
      }
      client.setPropertyFlag('pause', false);
      client.command(['loadfile', _currentMediaTarget, 'replace']);
      return;
    }

    if (_useAndroidSurfaceSession) {
      // 移动端先在 vo=null 静默态重建视频轨以干净销毁伪支持 MediaCodec 实例，再重新挂载原画输出。
      client.command(['video-reload']);
      if (hadBoundSurface && !_closingSilenced) {
        _applyAndroidVo(client);
        client.setPropertyFlag('pause', wasPaused);
      }
    }
  }

  /// 运行中更新画质配置时对 Android 硬软解切换施加 `vo=null` 隔离保护。
  void _applyLiveQualityWithAndroidSurfaceGuard(
    LibMpvClient client, {
    required PlaybackQualityConfig config,
    required List<String> verifiedShaders,
  }) {
    final nextHwdec = MpvQualityProfile.resolveHwdecValue(
      config: config,
      isWindows: _isWindows,
      isAndroid: _useAndroidSurfaceSession,
      desktopDelegate: desktopProfileDelegate,
    );
    final currentHwdec = client.getPropertyString('hwdec') ?? '';
    final needAndroidVoGuard =
        _useAndroidSurfaceSession &&
        _boundAndroidWid > 0 &&
        _videoTrackEnabled &&
        nextHwdec != currentHwdec;
    final wasPaused = needAndroidVoGuard
        ? (client.getPropertyFlag('pause') ?? false)
        : false;
    if (needAndroidVoGuard) {
      client.setPropertyFlag('pause', true);
      client.setPropertyString('vo', 'null');
    }
    MpvQualityProfile.applyLiveQualityUpdate(
      client,
      config: config,
      isHdrSource: _lastDynamicHdrActive ?? false,
      hasSecondarySubtitle: _hasSecondarySubtitle,
      isAndroidOverride: _useAndroidSurfaceSession,
      desktopDelegate: desktopProfileDelegate,
      verifiedShaderPaths: verifiedShaders,
      onExclusiveFallbackNotice: onNotice,
      logStore: logStore,
    );
    if (needAndroidVoGuard && !_disposed && !_closingSilenced && !client.isDisposed) {
      _applyAndroidVo(client);
      client.setPropertyFlag('pause', wasPaused);
    }
  }

  /// 解码层精准拦截 AVC Hi10P / 非 4:2:0 与 HEVC Rext / >10-bit 流，在首帧花屏前自动回落多线程 SIMD 软解。
  void _enforceHwdecSafetyPolicy() {
    final client = _client;
    if (_disposed ||
        _closingSilenced ||
        client == null ||
        client.isDisposed ||
        !_hwdecWasEnabled ||
        _usingSoftwareFallback) {
      return;
    }
    final codec =
        client.getPropertyString('current-tracks/video/codec') ??
        client.getPropertyString('video-format') ??
        client.getPropertyString('video-codec') ??
        '';
    final profile =
        client.getPropertyString('current-tracks/video/codec-profile') ??
        client.getPropertyString('video-params/profile');
    final pixfmt =
        client.getPropertyString('video-params/pixelformat') ??
        client.getPropertyString('video-dec-params/pixelformat');
    final hwPixfmt =
        client.getPropertyString('video-params/hw-pixelformat') ??
        client.getPropertyString('video-dec-params/hw-pixelformat');
    final platform = _useAndroidSurfaceSession
        ? HwdecPlatformKind.android
        : (_isWindows
              ? HwdecPlatformKind.windows
              : HwdecPlatformKind.other);
    final decision = HwdecSafetyPolicy.evaluate(
      platform: platform,
      videoCodec: codec,
      videoProfile: profile,
      pixelFormat: pixfmt,
      hwPixelFormat: hwPixfmt,
    );
    if (decision.allowHardwareDecode) {
      return;
    }
    _hwdecFallbackAttempted = true;
    _usingSoftwareFallback = true;
    _applySoftwareDecodeTransition(client, reloadFile: false);
    PlaybackLogHelper.record(logStore, 
      'mpv-hwdec-guard',
      'rule=${decision.matchedRule} codec=$codec profile=$profile pixfmt=$pixfmt hw=$hwPixfmt -> hwdec=no',
    );
    onHwdecChanged?.call('no');
    if (decision.reason != null) {
      onNotice?.call(decision.reason!);
    }
  }

  /// 按当前视频传输特性动态开关 `hdr-compute-peak` 与共享纹理 FP16 FBO：
  /// 常规 SDR 番剧保持 10-bit FBO 且关闭逐帧峰值计算，遇真 HDR（PQ/HLG）自动无感升档。
  void _syncDynamicHdrPipeline() {
    final client = _client;
    if (_disposed || client == null || client.isDisposed) {
      return;
    }
    final gamma =
        client.getPropertyString('video-params/gamma') ??
        client.getPropertyString('video-out-params/gamma');
    final sigPeak =
        client.getPropertyDouble('video-params/sig-peak') ??
        client.getPropertyDouble('video-out-params/sig-peak');
    final isHdr = MpvQualityProfile.isHdrTransfer(
      gamma: gamma,
      sigPeak: sigPeak,
    );
    if (_lastDynamicHdrActive == isHdr) {
      return;
    }
    _lastDynamicHdrActive = isHdr;

    final setter = MpvSafePropertySetter(logStore: logStore);
    final enablePeak = MpvQualityProfile.shouldEnableHdrComputePeak(
      _lastQualityConfig.preset,
      isHdrSource: isHdr,
    );
    setter.setBool(client, 'hdr-compute-peak', enablePeak);

    final backend = _renderBackendValue;
    final sessionId = _desktopSurfaceSessionId;
    final bridge = desktopSurfaceBridge;
    final isSharedD3D11 = backend == 'd3d11_10bit' || backend == 'd3d11_fp16';
    if (isSharedD3D11 && sessionId != null && sessionId > 0 && bridge != null) {
      setter.setString(client, 'fbo-format', isHdr ? 'rgba16hf' : 'rgb10_a2');
      unawaited(
        bridge.setHdrFboEnabled(sessionId: sessionId, enabled: isHdr).then((
          applied,
        ) {
          if (!_disposed && applied) {
            _setRenderBackend(isHdr ? 'd3d11_fp16' : 'd3d11_10bit');
          }
        }),
      );
    }
  }
}
