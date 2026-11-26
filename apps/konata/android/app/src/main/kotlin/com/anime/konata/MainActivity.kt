package com.anime.konata

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioMixerAttributes
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.MediaStore
import android.util.Rational
import android.view.PixelCopy
import android.view.ScrollCaptureCallback
import android.view.ScrollCaptureSession
import android.view.WindowManager
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.function.Consumer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/// Android 主活动宿主：承载硬件视频表面、音频焦点、窗口亮度/全屏控制及原生画中画生命周期。
class MainActivity : FlutterActivity() {
    companion object {
        private const val ACTION_PIP_CONTROL = "com.anime.konata.ACTION_PIP_CONTROL"
        private const val EXTRA_PIP_COMMAND = "pip_command"
        private const val REQ_PREV = 7101
        private const val REQ_TOGGLE = 7102
        private const val REQ_NEXT = 7103
    }

    private var playbackFullscreen = false
    private var previousBarsBehavior = 0
    private var visibleBars = 0
    private var originalCutoutMode: Int? = null
    private var audioFocusChannel: MethodChannel? = null
    private var audioRouteChannel: MethodChannel? = null
    private var mediaSessionChannel: MethodChannel? = null
    private var pipChannel: MethodChannel? = null
    private var scrollCaptureChannel: MethodChannel? = null
    private var underlaySurfaceHost: AndroidUnderlaySurfaceHost? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var pipReceiverRegistered = false
    private var noisyReceiverRegistered = false
    private var audioDeviceCallbackRegistered = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var lazyIoExecutor: ExecutorService? = null

    private fun ioExecutor(): ExecutorService {
        return lazyIoExecutor ?: Executors.newSingleThreadExecutor().also { lazyIoExecutor = it }
    }

    private var pipEligible = false
    private var pipIsPlaying = false
    private var pipCanPrevious = false
    private var pipCanNext = false
    private var pipAspectNumerator = 16
    private var pipAspectDenominator = 9
    private var pipSourceRect: Rect? = null
    private var inPipState = false
    private var lastPipExitMillis = 0L

    private var scrollHasTarget = false
    private var scrollTargetRect = Rect()

    private val audioManager by lazy { getSystemService(AUDIO_SERVICE) as AudioManager }
    private val audioFocusListener = AudioManager.OnAudioFocusChangeListener { change ->
        val eventName = when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> "loss"
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> "lossTransient"
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> "duck"
            AudioManager.AUDIOFOCUS_GAIN -> "gain"
            else -> null
        } ?: return@OnAudioFocusChangeListener
        // 系统音频焦点变更时立即通知播放协调器暂停、压低音量或恢复播放
        runOnUiThread { audioFocusChannel?.invokeMethod("focusChange", eventName) }
    }

    private val pipControlReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION_PIP_CONTROL) return
            val cmd = intent.getStringExtra(EXTRA_PIP_COMMAND) ?: return
            runOnUiThread { pipChannel?.invokeMethod("action", cmd) }
        }
    }

    /// 通道一：监听系统 `ACTION_AUDIO_BECOMING_NOISY` 外设拔出防爆音广播。
    private val becomingNoisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
            runOnUiThread {
                audioRouteChannel?.invokeMethod("outputDeviceRemoved", "becoming_noisy")
            }
        }
    }

    /// 通道二：监听系统 `AudioDeviceCallback` 外接耳机/USB DAC/蓝牙设备插拔事件。
    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            val removedExternal = removedDevices.any { isExternalAudioOutput(it) }
            if (removedExternal) {
                runOnUiThread {
                    audioRouteChannel?.invokeMethod("outputDeviceRemoved", "device_callback_removed")
                }
            }
        }

        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            val external = addedDevices.firstOrNull { isExternalAudioOutput(it) } ?: return
            val fingerprint = "android_${external.type}_${external.id}"
            runOnUiThread {
                audioRouteChannel?.invokeMethod("outputDeviceAdded", fingerprint)
            }
        }
    }

    private fun isExternalAudioOutput(info: AudioDeviceInfo): Boolean {
        if (!info.isSink) return false
        return when (info.type) {
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_HDMI -> true
            else -> false
        }
    }

    override fun getRenderMode(): RenderMode {
        // 显式锁定表面直出模式，消除离屏 TextureView 双拷贝与额外全屏显存占用。
        return RenderMode.surface
    }

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode {
        // 开启透明通道以支撑底层 Underlay 原画表面透出与跨页悬浮视频小窗零拷贝直出。
        return FlutterActivityLaunchConfigs.BackgroundMode.transparent
    }

    override fun onFlutterSurfaceViewCreated(flutterSurfaceView: FlutterSurfaceView) {
        super.onFlutterSurfaceViewCreated(flutterSurfaceView)
        // 显式覆写 Flutter 透明模式默认施加的 setZOrderOnTop(true)：
        // 将 Flutter 表面精确锚定在 MediaOverlay 层（严格位于底层索引 0 视频 SurfaceView 之上，
        // 同时保持在窗口 DecorView 顶层浮层与 PixelCopy.request(window, ...) 体系之内）。
        flutterSurfaceView.setZOrderOnTop(false)
        flutterSurfaceView.setZOrderMediaOverlay(true)
        flutterSurfaceView.holder.setFormat(PixelFormat.TRANSLUCENT)
    }

    /// 识别联发科 / Mali 平台：Flutter 3.50 Release 模式会静默忽略 `ImpellerBackend=opengles` 并强启 Vulkan，
    /// 在联发科 Mali（如 mt6989 + libged）与 libmpv OpenGL ES 并发渲染时会触发 BLASTBufferQueue 耗尽与 fdsan 闪退。
    private fun shouldDisableImpellerForCurrentDevice(): Boolean {
        val hardware = Build.HARDWARE.orEmpty().lowercase()
        val board = Build.BOARD.orEmpty().lowercase()
        val socManufacturer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MANUFACTURER.orEmpty().lowercase()
        } else {
            ""
        }
        val socModel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MODEL.orEmpty().lowercase()
        } else {
            ""
        }
        return hardware.startsWith("mt") ||
            board.startsWith("mt") ||
            socManufacturer.contains("mediatek") ||
            socModel.startsWith("mt")
    }

    override fun getFlutterEngineFlags(): List<String> {
        val flags = super.getFlutterEngineFlags().toMutableList()
        if (shouldDisableImpellerForCurrentDevice()) {
            // 联发科/Mali 机型显式关闭 Impeller，统一落回 OpenGL ES 避免与 libmpv/libged 争抢 Vulkan 栅栏句柄。
            if (flags.none { it.startsWith("--enable-impeller") }) {
                flags.add("--enable-impeller=false")
            }
        } else if (flags.none { it.startsWith("--impeller-backend=") }) {
            flags.add("--impeller-backend=opengles")
        }
        if (flags.none { it.startsWith("--enable-hcpp-and-surface-control") }) {
            flags.add("--enable-hcpp-and-surface-control=false")
        }
        return flags
    }

    private fun ensurePipReceiverRegistered() {
        if (pipReceiverRegistered) return
        ContextCompat.registerReceiver(
            this,
            pipControlReceiver,
            IntentFilter(ACTION_PIP_CONTROL),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        pipReceiverRegistered = true
    }

    private fun ensureAudioRouteMonitoringRegistered() {
        if (!noisyReceiverRegistered) {
            ContextCompat.registerReceiver(
                this,
                becomingNoisyReceiver,
                IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            noisyReceiverRegistered = true
        }
        if (!audioDeviceCallbackRegistered) {
            try {
                audioManager.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)
                audioDeviceCallbackRegistered = true
            } catch (_: Exception) {}
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    override fun onDestroy() {
        if (pipReceiverRegistered) {
            try {
                unregisterReceiver(pipControlReceiver)
            } catch (_: Exception) {}
            pipReceiverRegistered = false
        }
        if (noisyReceiverRegistered) {
            try {
                unregisterReceiver(becomingNoisyReceiver)
            } catch (_: Exception) {}
            noisyReceiverRegistered = false
        }
        if (audioDeviceCallbackRegistered) {
            try {
                audioManager.unregisterAudioDeviceCallback(audioDeviceCallback)
            } catch (_: Exception) {}
            audioDeviceCallbackRegistered = false
        }
        lazyIoExecutor?.shutdownNow()
        lazyIoExecutor = null
        super.onDestroy()
    }

    private fun requestPlaybackAudioFocus(): Boolean {
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = audioFocusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
                .setAcceptsDelayedFocusGain(false)
                .setWillPauseWhenDucked(false)
                .setOnAudioFocusChangeListener(audioFocusListener).build()
                .also { audioFocusRequest = it }
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                audioFocusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
        }
        return granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonPlaybackAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            audioFocusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(audioFocusListener)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                window.decorView.setScrollCaptureCallback(null)
            } catch (_: Exception) {}
        }
        endPlaybackWindow()
        abandonPlaybackAudioFocus()
        KonataMediaSessionDispatcher.onTransportCommand = null
        mediaSessionChannel?.setMethodCallHandler(null)
        mediaSessionChannel = null
        audioFocusChannel?.setMethodCallHandler(null)
        audioFocusChannel = null
        audioRouteChannel?.setMethodCallHandler(null)
        audioRouteChannel = null
        pipChannel?.setMethodCallHandler(null)
        pipChannel = null
        scrollCaptureChannel?.setMethodCallHandler(null)
        scrollCaptureChannel = null
        underlaySurfaceHost?.destroy()
        underlaySurfaceHost = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun setPlaybackFullscreen(enabled: Boolean) {
        val decor = window.decorView
        val controller = WindowCompat.getInsetsController(window, decor)
        val bars = WindowInsetsCompat.Type.systemBars()
        if (enabled) {
            if (!playbackFullscreen) {
                playbackFullscreen = true
                previousBarsBehavior = controller.systemBarsBehavior
                val insets = androidx.core.view.ViewCompat.getRootWindowInsets(decor)
                visibleBars = listOf(WindowInsetsCompat.Type.statusBars(), WindowInsetsCompat.Type.navigationBars())
                    .filter { insets?.isVisible(it) != false }.fold(0, Int::or)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val lp = window.attributes
                if (originalCutoutMode == null) {
                    originalCutoutMode = lp.layoutInDisplayCutoutMode
                }
                if (lp.layoutInDisplayCutoutMode != WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES) {
                    lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                    window.attributes = lp
                }
            }
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(bars)
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val savedCutout = originalCutoutMode
                if (savedCutout != null) {
                    val lp = window.attributes
                    lp.layoutInDisplayCutoutMode = savedCutout
                    window.attributes = lp
                    originalCutoutMode = null
                }
            }
            if (!playbackFullscreen) return
            playbackFullscreen = false
            controller.systemBarsBehavior = previousBarsBehavior
            controller.show(visibleBars)
        }
    }

    private fun setWindowBrightnessOverride(value: Double) {
        val lp = window.attributes
        lp.screenBrightness = if (value < 0.0) {
            WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        } else {
            value.toFloat().coerceIn(0.01f, 1.0f)
        }
        window.attributes = lp
    }

    private fun endPlaybackWindow() {
        setPlaybackFullscreen(false)
        setWindowBrightnessOverride(-1.0)
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun buildPipParams(): PictureInPictureParams {
        val rawRatio = if (pipAspectNumerator > 0 && pipAspectDenominator > 0) {
            pipAspectNumerator.toFloat() / pipAspectDenominator.toFloat()
        } else {
            16f / 9f
        }
        // 严格钳制画中画宽高比在 0.42 ~ 2.39 安全区间内
        val safeRatio = rawRatio.coerceIn(0.42f, 2.39f)
        val rational = Rational((safeRatio * 1000f).roundToInt().coerceIn(420, 2390), 1000)

        val actions = ArrayList<RemoteAction>(3)
        actions.add(
            buildPipRemoteAction(
                requestCode = REQ_PREV,
                iconRes = android.R.drawable.ic_media_previous,
                title = "上一话",
                command = "previous",
                enabled = pipCanPrevious
            )
        )
        actions.add(
            buildPipRemoteAction(
                requestCode = REQ_TOGGLE,
                iconRes = if (pipIsPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                title = if (pipIsPlaying) "暂停" else "播放",
                command = "togglePlayPause",
                enabled = true
            )
        )
        actions.add(
            buildPipRemoteAction(
                requestCode = REQ_NEXT,
                iconRes = android.R.drawable.ic_media_next,
                title = "下一话",
                command = "next",
                enabled = pipCanNext
            )
        )

        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(rational)
            .setActions(actions)

        pipSourceRect?.let { rect ->
            if (rect.width() > 0 && rect.height() > 0) {
                builder.setSourceRectHint(rect)
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipEligible)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun buildPipRemoteAction(
        requestCode: Int,
        iconRes: Int,
        title: String,
        command: String,
        enabled: Boolean
    ): RemoteAction {
        val intent = Intent(ACTION_PIP_CONTROL)
            .setPackage(packageName)
            .putExtra(EXTRA_PIP_COMMAND, command)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pendingIntent = PendingIntent.getBroadcast(this, requestCode, intent, flags)
        val icon = Icon.createWithResource(this, iconRes)
        return RemoteAction(icon, title, title, pendingIntent).apply {
            isEnabled = enabled
        }
    }

    private fun applyLivePipParamsIfSupported() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S || isInPictureInPictureMode) {
            try {
                setPictureInPictureParams(buildPipParams())
            } catch (_: Exception) {}
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // 全版本离开前台时均按实时资格兜底触发系统画中画，兼容三键导航与 HOME 键切后台
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (pipEligible && !isInPictureInPictureMode) {
                try {
                    enterPictureInPictureMode(buildPipParams())
                } catch (_: Exception) {}
            }
        }
    }

    override fun onResume() {
        super.onResume()
        lastPipExitMillis = 0L
    }

    override fun onStop() {
        val exitedPipRecently = inPipState ||
            (lastPipExitMillis > 0L && (System.currentTimeMillis() - lastPipExitMillis) < 1200L)
        if (exitedPipRecently) {
            inPipState = false
            lastPipExitMillis = 0L
            runOnUiThread {
                pipChannel?.invokeMethod("pipDismissed", null)
            }
        }
        super.onStop()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPipState = isInPictureInPictureMode
        lastPipExitMillis = if (isInPictureInPictureMode) 0L else System.currentTimeMillis()
        runOnUiThread {
            pipChannel?.invokeMethod("pipChanged", isInPictureInPictureMode)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && playbackFullscreen && !isInPictureInPictureMode) {
            setPlaybackFullscreen(true)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "konata/network").setMethodCallHandler { call, result ->
            if (call.method == "isMeteredNetwork") {
                try {
                    val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
                    if (cm == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val active = cm.activeNetwork
                    val caps = if (active != null) cm.getNetworkCapabilities(active) else null
                    val isCellular = caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) == true
                    val isMetered = cm.isActiveNetworkMetered || isCellular
                    result.success(isMetered)
                } catch (_: Exception) {
                    result.success(false)
                }
                return@setMethodCallHandler
            }
            if (call.method != "proxy") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val rawUrl = call.arguments as? String
            ioExecutor().execute {
                try {
                    val uri = java.net.URI(rawUrl ?: "")
                    require(uri.scheme == "https" || uri.scheme == "http")
                    val routes = java.net.ProxySelector.getDefault()?.select(uri)
                        ?: listOf(java.net.Proxy.NO_PROXY)
                    val value = routes.map { proxy ->
                        when (proxy.type()) {
                            java.net.Proxy.Type.DIRECT -> "DIRECT"
                            java.net.Proxy.Type.HTTP -> {
                                val address = proxy.address() as java.net.InetSocketAddress
                                val host = address.hostString
                                require(!host.contains(';') && !host.any { it.isWhitespace() })
                                val literal = if (host.contains(':')) "[$host]" else host
                                "PROXY $literal:${address.port}"
                            }
                            else -> throw IOException("Unsupported system proxy")
                        }
                    }.joinToString("; ")
                    require(value.isNotEmpty())
                    runOnUiThread { result.success(value) }
                } catch (_: Exception) {
                    runOnUiThread {
                        result.error("proxy_unavailable", "Cannot resolve system proxy", null)
                    }
                }
            }
        }
        audioFocusChannel = MethodChannel(messenger, "konata/audio_focus").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" -> result.success(requestPlaybackAudioFocus())
                    "abandon" -> { abandonPlaybackAudioFocus(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
        }
        audioRouteChannel = MethodChannel(messenger, "konata/audio_route").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startMonitoring" -> {
                        ensureAudioRouteMonitoringRegistered()
                        result.success(true)
                    }
                    "negotiateBitPerfectUsb" -> {
                        ensureAudioRouteMonitoringRegistered()
                        val sampleRate = (call.argument<Number>("sampleRateHz"))?.toInt() ?: 48000
                        val enable = call.argument<Boolean>("enable") ?: true
                        result.success(negotiateAndroidBitPerfectUsb(sampleRate, enable))
                    }
                    else -> result.notImplemented()
                }
            }
        }
        mediaSessionChannel = MethodChannel(messenger, "konata/media_session").also { channel ->
            KonataMediaSessionDispatcher.onTransportCommand = { command, positionMs ->
                runOnUiThread {
                    val payload = HashMap<String, Any?>(2)
                    payload["command"] = command
                    if (positionMs != null) {
                        payload["positionMs"] = positionMs
                    }
                    channel.invokeMethod("onMediaAction", payload)
                }
            }
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        val args = call.arguments as? Map<*, *>
                        if (args != null) {
                            KonataMediaSessionDispatcher.updateFromDart(applicationContext, args)
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        KonataMediaSessionDispatcher.stopFromDart(applicationContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        pipChannel = MethodChannel(messenger, "konata/pip").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "syncState" -> {
                        val args = call.arguments as? Map<*, *>
                        if (args != null) {
                            pipEligible = args["eligible"] == true
                            if (pipEligible) {
                                ensurePipReceiverRegistered()
                            }
                            pipIsPlaying = args["isPlaying"] == true
                            pipCanPrevious = args["canPrevious"] == true
                            pipCanNext = args["canNext"] == true
                            pipAspectNumerator = (args["aspectNumerator"] as? Number)?.toInt() ?: 16
                            pipAspectDenominator = (args["aspectDenominator"] as? Number)?.toInt() ?: 9
                            val l = (args["left"] as? Number)?.toInt()
                            val t = (args["top"] as? Number)?.toInt()
                            val r = (args["right"] as? Number)?.toInt()
                            val b = (args["bottom"] as? Number)?.toInt()
                            pipSourceRect = if (l != null && t != null && r != null && b != null && r > l && b > t) {
                                Rect(l, t, r, b)
                            } else {
                                null
                            }
                            applyLivePipParamsIfSupported()
                        }
                        result.success(null)
                    }
                    "enter" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !isInPictureInPictureMode) {
                            val entered = try {
                                enterPictureInPictureMode(buildPipParams())
                            } catch (_: Exception) {
                                false
                            }
                            result.success(entered)
                        } else {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(messenger, "konata/artwork").setMethodCallHandler { call, result ->
            if (call.method != "openDirectory") {
                result.notImplemented()
            } else try {
                val uri = DocumentsContract.buildDocumentUri("$packageName.artwork", "artwork")
                val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, Document.MIME_TYPE_DIR)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                try { startActivity(intent) } catch (_: android.content.ActivityNotFoundException) {
                    startActivity(Intent(Intent.ACTION_OPEN_DOCUMENT).setType("image/*")
                        .addCategory(Intent.CATEGORY_OPENABLE)
                        .putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri))
                }
                result.success(null)
            } catch (_: Exception) {
                result.error("artwork_unavailable", "Cannot open artwork directory", null)
            }
        }
        underlaySurfaceHost?.destroy()
        underlaySurfaceHost = AndroidUnderlaySurfaceHost(this, messenger)
        MethodChannel(messenger, "konata/media_store").setMethodCallHandler { call, result ->
            if (call.method != "saveImageToGallery") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val sourcePath = call.argument<String>("sourcePath").orEmpty()
            val displayName = call.argument<String>("displayName").orEmpty()
            val albumName = call.argument<String>("albumName").orEmpty().ifBlank { "Konata" }
            val mimeType = call.argument<String>("mimeType").orEmpty().ifBlank { "image/png" }
            ioExecutor().execute {
                val sourceFile = File(sourcePath)
                try {
                    require(sourceFile.isFile && sourceFile.length() > 0L) {
                        "Screenshot source file unavailable"
                    }
                    val savedUri = publishImageToMediaStore(
                        sourceFile = sourceFile,
                        displayName = displayName.ifBlank { sourceFile.name },
                        albumName = albumName,
                        mimeType = mimeType
                    )
                    runOnUiThread { result.success(savedUri) }
                } catch (e: Exception) {
                    runOnUiThread {
                        result.error("media_store_failed", e.message ?: "Failed to publish image", null)
                    }
                } finally {
                    try {
                        if (sourceFile.exists()) {
                            sourceFile.delete()
                        }
                    } catch (_: Exception) {}
                }
            }
        }
        MethodChannel(messenger, "konata/playback_window").setMethodCallHandler { call, result ->
            when (call.method) {
                "begin" -> {
                    result.success(null)
                }
                "applyWindowMode" -> {
                    val args = call.arguments as? Map<*, *>
                    val landscape = args?.get("landscape") == true
                    val hideBars = args?.get("hideSystemBars") == true
                    setPlaybackFullscreen(hideBars)
                    requestedOrientation = if (landscape) {
                        ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                    } else {
                        ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                    }
                    result.success(null)
                }
                "orientationLocked" -> {
                    val locked = call.arguments as? Boolean
                    if (locked == null) {
                        result.error("playback_inactive", "Playback window is unavailable", null)
                    } else {
                        // 锁定精确当前朝向（含反向横竖屏），解锁后恢复横屏传感器方向
                        requestedOrientation = if (locked) ActivityInfo.SCREEN_ORIENTATION_LOCKED
                            else ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                        result.success(locked)
                    }
                }
                "setLandscape" -> {
                    val landscape = call.arguments == true
                    requestedOrientation = if (landscape) {
                        ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                    } else {
                        ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                    }
                    result.success(null)
                }
                "setBrightness" -> {
                    val v = (call.arguments as? Number)?.toDouble() ?: -1.0
                    setWindowBrightnessOverride(v)
                    result.success(null)
                }
                "fullscreen" -> {
                    setPlaybackFullscreen(call.arguments == true)
                    result.success(null)
                }
                "end" -> { endPlaybackWindow(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        scrollCaptureChannel = MethodChannel(messenger, "konata/scroll_capture").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateScrollTarget" -> {
                        val args = call.arguments as? Map<*, *>
                        val hasTarget = args?.get("hasTarget") == true
                        val left = (args?.get("leftPx") as? Number)?.toInt() ?: 0
                        val top = (args?.get("topPx") as? Number)?.toInt() ?: 0
                        val right = (args?.get("rightPx") as? Number)?.toInt() ?: 0
                        val bottom = (args?.get("bottomPx") as? Number)?.toInt() ?: 0
                        scrollHasTarget = hasTarget && right > left && bottom > top
                        if (scrollHasTarget) {
                            scrollTargetRect.set(left, top, right, bottom)
                        } else {
                            scrollTargetRect.setEmpty()
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            window.decorView.scrollCaptureHint = if (scrollHasTarget) {
                                android.view.View.SCROLL_CAPTURE_HINT_INCLUDE
                            } else {
                                android.view.View.SCROLL_CAPTURE_HINT_AUTO
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            installScrollCaptureCallback()
        }
        MethodChannel(messenger, "konata/mpv_profile", StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue()).setMethodCallHandler { call, result ->
            if (call.method != "read") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val tree = Uri.parse(requireNotNull(call.argument<String>("folder")))
                val limit = requireNotNull(call.argument<Int>("limit"))
                result.success(readProfile(tree, limit))
            } catch (_: Exception) {
                result.error("profile_unavailable", "Cannot read configuration folder", null)
            }
        }
        MethodChannel(messenger, "konata/local_media", StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue()).setMethodCallHandler { call, result ->
            if (call.method != "list" && call.method != "resolve") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val tree = Uri.parse(requireNotNull(call.argument<String>("root")))
                require(contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission })
                val relative = requireNotNull(call.argument<String>("relative"))
                val parts = if (relative.isEmpty()) emptyList() else relative.split('/')
                require(parts.size <= 64 && parts.all { it.isNotEmpty() && it != "." && it != ".." && !it.contains('\\') })
                var id = DocumentsContract.getTreeDocumentId(tree)
                for (part in parts) {
                    val matches = mediaChildren(tree, id).filter { it["name"] == part }
                    if (matches.size != 1) throw IOException("Media path unavailable")
                    id = matches.single()["id"] as String
                }
                if (call.method == "list") result.success(mediaChildren(tree, id))
                else result.success(DocumentsContract.buildDocumentUriUsingTree(tree, id).toString())
            } catch (_: Exception) {
                result.error("local_media_unavailable", "Cannot read granted media folder", null)
            }
        }
    }

    private fun mediaChildren(tree: Uri, parent: String): List<Map<String, Any?>> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent)
        val columns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE)
        return (contentResolver.query(uri, columns, null, null, null)
            ?: throw IOException("Folder unavailable")).use { cursor ->
            val entries = mutableListOf<Map<String, Any?>>()
            while (cursor.moveToNext()) {
                require(entries.size < 100000) { "Directory exceeds listing limit" }
                entries.add(mapOf("id" to cursor.getString(0), "name" to cursor.getString(1),
                    "directory" to (cursor.getString(2) == Document.MIME_TYPE_DIR),
                    "size" to if (cursor.isNull(3)) null else cursor.getLong(3)))
            }
            entries
        }
    }

    private fun readProfile(tree: Uri, limit: Int): Map<String, ByteArray> {
        require(contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission })
        val root = DocumentsContract.getTreeDocumentId(tree)
        val document = DocumentsContract.buildDocumentUriUsingTree(tree, root)
        val exists = contentResolver.query(document, arrayOf(Document.COLUMN_DOCUMENT_ID),
            null, null, null)?.use { it.moveToFirst() } ?: false
        if (!exists) throw IOException("Folder unavailable")
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, root)
        val files = mutableMapOf<String, ByteArray>()
        val columns = arrayOf(Document.COLUMN_DISPLAY_NAME, Document.COLUMN_DOCUMENT_ID)
        val cursor = contentResolver.query(children, columns, null, null, null)
            ?: throw IOException("Folder unavailable")
        cursor.use {
            while (it.moveToNext()) {
                val name = it.getString(0)
                if (name != "mpv.conf" && name != "input.conf") continue
                require(name !in files)
                val uri = DocumentsContract.buildDocumentUriUsingTree(tree, it.getString(1))
                val input = contentResolver.openInputStream(uri) ?: throw IOException(name)
                files[name] = input.use { stream ->
                    val buffer = ByteArray(8192)
                    val output = ByteArrayOutputStream()
                    while (true) {
                        val count = stream.read(buffer)
                        if (count < 0) break
                        require(output.size() + count <= limit)
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
            }
        }
        return files
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun installScrollCaptureCallback() {
        window.decorView.setScrollCaptureCallback(object : ScrollCaptureCallback {
            private var captureWindowRect = Rect()

            override fun onScrollCaptureSearch(
                signal: CancellationSignal,
                onReady: Consumer<Rect>
            ) {
                if (signal.isCanceled || !scrollHasTarget || scrollTargetRect.isEmpty) {
                    onReady.accept(Rect())
                    return
                }
                onReady.accept(Rect(scrollTargetRect))
            }

            override fun onScrollCaptureStart(
                session: ScrollCaptureSession,
                signal: CancellationSignal,
                onReady: Runnable
            ) {
                if (signal.isCanceled) return
                runOnUiThread {
                    val channel = scrollCaptureChannel
                    if (channel == null) {
                        onReady.run()
                        return@runOnUiThread
                    }
                    channel.invokeMethod("beginCapture", null, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            val map = result as? Map<*, *>
                            val left = (map?.get("leftPx") as? Number)?.toInt() ?: scrollTargetRect.left
                            val top = (map?.get("topPx") as? Number)?.toInt() ?: scrollTargetRect.top
                            val right = (map?.get("rightPx") as? Number)?.toInt() ?: scrollTargetRect.right
                            val bottom = (map?.get("bottomPx") as? Number)?.toInt() ?: scrollTargetRect.bottom
                            captureWindowRect = if (right > left && bottom > top) {
                                Rect(left, top, right, bottom)
                            } else {
                                Rect(scrollTargetRect)
                            }
                            onReady.run()
                        }

                        override fun error(code: String, msg: String?, details: Any?) {
                            captureWindowRect = Rect(scrollTargetRect)
                            onReady.run()
                        }

                        override fun notImplemented() {
                            captureWindowRect = Rect(scrollTargetRect)
                            onReady.run()
                        }
                    })
                }
            }

            override fun onScrollCaptureImageRequest(
                session: ScrollCaptureSession,
                signal: CancellationSignal,
                captureArea: Rect,
                onComplete: Consumer<Rect>
            ) {
                if (signal.isCanceled) {
                    onComplete.accept(Rect())
                    return
                }
                runOnUiThread {
                    val channel = scrollCaptureChannel
                    if (channel == null || captureWindowRect.isEmpty) {
                        onComplete.accept(Rect())
                        return@runOnUiThread
                    }
                    val args = mapOf("requestedTopPx" to captureArea.top.toDouble())
                    channel.invokeMethod("scrollToCaptureArea", args, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            if (signal.isCanceled) {
                                onComplete.accept(Rect())
                                return
                            }
                            val map = result as? Map<*, *>
                            if (map?.get("ok") != true) {
                                onComplete.accept(Rect())
                                return
                            }
                            val actualDelta = (map["actualDeltaPx"] as? Number)?.toInt() ?: 0
                            val viewLeft = (map["leftPx"] as? Number)?.toInt() ?: captureWindowRect.left
                            val viewTop = (map["topPx"] as? Number)?.toInt() ?: captureWindowRect.top
                            val viewRight = (map["rightPx"] as? Number)?.toInt() ?: captureWindowRect.right
                            val viewBottom = (map["bottomPx"] as? Number)?.toInt() ?: captureWindowRect.bottom
                            val winHeight = max(0, viewBottom - viewTop)
                            val winWidth = max(0, viewRight - viewLeft)
                            if (winWidth <= 0 || winHeight <= 0) {
                                onComplete.accept(Rect())
                                return
                            }

                            // 将逻辑请求区与当前视口偏移对齐，计算可见裁剪矩形
                            val reqStart = captureArea.top
                            val reqEnd = captureArea.bottom
                            val visStart = max(reqStart, actualDelta)
                            val visEnd = min(reqEnd, actualDelta + winHeight)
                            if (visEnd <= visStart) {
                                onComplete.accept(Rect())
                                return
                            }

                            val localTop = visStart - actualDelta
                            val stripHeight = visEnd - visStart
                            val copyLeft = viewLeft + max(0, captureArea.left)
                            val copyRight = min(viewRight, viewLeft + captureArea.right)
                            val copyWidth = copyRight - copyLeft
                            if (copyWidth <= 0 || stripHeight <= 0) {
                                onComplete.accept(Rect())
                                return
                            }

                            val srcRect = Rect(copyLeft, viewTop + localTop, copyRight, viewTop + localTop + stripHeight)
                            val bitmap = Bitmap.createBitmap(copyWidth, stripHeight, Bitmap.Config.ARGB_8888)
                            try {
                                PixelCopy.request(window, srcRect, bitmap, { copyResult ->
                                    try {
                                        if (copyResult == PixelCopy.SUCCESS && !signal.isCanceled) {
                                            val resultRect = Rect(
                                                captureArea.left,
                                                visStart,
                                                captureArea.left + copyWidth,
                                                visEnd
                                            )
                                            val canvas: Canvas? = try {
                                                session.surface.lockCanvas(null)
                                            } catch (_: Exception) {
                                                try {
                                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                                        session.surface.lockHardwareCanvas()
                                                    } else {
                                                        null
                                                    }
                                                } catch (_: Exception) {
                                                    null
                                                }
                                            }
                                            if (canvas != null) {
                                                try {
                                                    canvas.drawBitmap(bitmap, 0f, 0f, null)
                                                } finally {
                                                    try {
                                                        session.surface.unlockCanvasAndPost(canvas)
                                                    } catch (_: Exception) {}
                                                }
                                                onComplete.accept(resultRect)
                                            } else {
                                                onComplete.accept(Rect())
                                            }
                                        } else {
                                            onComplete.accept(Rect())
                                        }
                                    } finally {
                                        bitmap.recycle()
                                    }
                                }, mainHandler)
                            } catch (_: Exception) {
                                bitmap.recycle()
                                onComplete.accept(Rect())
                            }
                        }

                        override fun error(code: String, msg: String?, details: Any?) {
                            onComplete.accept(Rect())
                        }

                        override fun notImplemented() {
                            onComplete.accept(Rect())
                        }
                    })
                }
            }

            override fun onScrollCaptureEnd(onReady: Runnable) {
                runOnUiThread {
                    val channel = scrollCaptureChannel
                    if (channel == null) {
                        onReady.run()
                        return@runOnUiThread
                    }
                    channel.invokeMethod("endCapture", null, object : MethodChannel.Result {
                        override fun success(result: Any?) = onReady.run()
                        override fun error(code: String, msg: String?, details: Any?) = onReady.run()
                        override fun notImplemented() = onReady.run()
                    })
                }
            }
        })
    }

    /// 通过 `MediaStore` `IS_PENDING` 事务机制原子写入系统相册图片目录，异常时自动回滚待定记录。
    private fun publishImageToMediaStore(
        sourceFile: File,
        displayName: String,
        albumName: String,
        mimeType: String
    ): String {
        val safeAlbum = albumName.replace(Regex("""[\\/:*?"<>|]+"""), "_").trim().ifEmpty { "Konata" }
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, mimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/$safeAlbum"
                )
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("Cannot create MediaStore gallery entry")
        try {
            val out = contentResolver.openOutputStream(uri)
                ?: throw IOException("Cannot open MediaStore output stream")
            out.use { output ->
                FileInputStream(sourceFile).use { input ->
                    input.copyTo(output, bufferSize = 32768)
                }
                output.flush()
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val completeValues = ContentValues().apply {
                    put(MediaStore.Images.Media.IS_PENDING, 0)
                }
                contentResolver.update(uri, completeValues, null, null)
            }
            return uri.toString()
        } catch (e: Exception) {
            try {
                contentResolver.delete(uri, null, null)
            } catch (_: Exception) {}
            throw e
        }
    }

    /// Android 14+ 原生 `MIXER_BEHAVIOR_BIT_PERFECT` USB DAC 混音器逐位直通协商。
    private fun negotiateAndroidBitPerfectUsb(
        preferredSampleRateHz: Int,
        enable: Boolean
    ): Map<String, Any> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return mapOf(
                "supported" to false,
                "engaged" to false,
                "operationSucceeded" to !enable,
                "detail" to "需要 Android 14 (API 34) 及以上系统以支持原生 USB 逐位直通"
            )
        }
        val mediaAttrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val usbDevice = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .firstOrNull {
                it.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                    it.type == AudioDeviceInfo.TYPE_USB_HEADSET
            }
            ?: return mapOf(
                "supported" to false,
                "engaged" to false,
                "operationSucceeded" to !enable,
                "detail" to "当前未连接外接 USB DAC 音频设备"
            )

        if (!enable) {
            val cleared = try {
                audioManager.getPreferredMixerAttributes(mediaAttrs, usbDevice) == null ||
                    audioManager.clearPreferredMixerAttributes(mediaAttrs, usbDevice)
            } catch (error: Exception) {
                android.util.Log.w("KonataAudioRoute", "撤销 USB 混音属性失败：${error.javaClass.simpleName}")
                false
            }
            return mapOf(
                "supported" to true,
                "engaged" to false,
                "operationSucceeded" to cleared,
                "deviceName" to (usbDevice.productName?.toString() ?: "USB DAC"),
                "detail" to if (cleared) "已恢复系统默认混音路由" else "无法确认 USB 直通属性已撤销"
            )
        }

        val supported = try {
            audioManager.getSupportedMixerAttributes(usbDevice)
        } catch (_: Exception) {
            emptyList()
        }
        val bitPerfectList = supported.filter {
            it.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT
        }
        if (bitPerfectList.isEmpty()) {
            return mapOf(
                "supported" to false,
                "engaged" to false,
                "deviceName" to (usbDevice.productName?.toString() ?: "USB DAC"),
                "detail" to "该 USB 设备未向系统宣告 MIXER_BEHAVIOR_BIT_PERFECT 能力"
            )
        }
        val chosen = bitPerfectList.firstOrNull {
            it.format.sampleRate == preferredSampleRateHz
        } ?: bitPerfectList.first()
        val ok = try {
            audioManager.setPreferredMixerAttributes(mediaAttrs, usbDevice, chosen)
        } catch (_: Exception) {
            false
        }
        return mapOf(
            "supported" to true,
            "engaged" to ok,
            "operationSucceeded" to ok,
            "deviceName" to (usbDevice.productName?.toString() ?: "USB DAC"),
            "sampleRateHz" to chosen.format.sampleRate,
            "detail" to if (ok) "已协商 Android 14+ 原生 USB 逐位直通" else "系统拒绝设置逐位混音器属性"
        )
    }
}
