package com.anime.konata

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.util.Rational
import android.view.WindowManager
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.ByteArrayOutputStream
import java.io.IOException
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

    private var previousOrientation: Int? = null
    private var playbackFullscreen = false
    private var previousBarsBehavior = 0
    private var visibleBars = 0
    private var audioFocusChannel: MethodChannel? = null
    private var pipChannel: MethodChannel? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var pipReceiverRegistered = false

    private var pipEligible = false
    private var pipIsPlaying = false
    private var pipCanPrevious = false
    private var pipCanNext = false
    private var pipAspectNumerator = 16
    private var pipAspectDenominator = 9
    private var pipSourceRect: Rect? = null

    private val audioManager by lazy { getSystemService(AUDIO_SERVICE) as AudioManager }
    private val audioFocusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK) {
            // 系统音频焦点被抢占时通知播放控制器立即暂停
            runOnUiThread { audioFocusChannel?.invokeMethod("loss", null) }
        }
    }

    private val pipControlReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION_PIP_CONTROL) return
            val cmd = intent.getStringExtra(EXTRA_PIP_COMMAND) ?: return
            runOnUiThread { pipChannel?.invokeMethod("action", cmd) }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!pipReceiverRegistered) {
            ContextCompat.registerReceiver(
                this,
                pipControlReceiver,
                IntentFilter(ACTION_PIP_CONTROL),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            pipReceiverRegistered = true
        }
    }

    override fun onDestroy() {
        if (pipReceiverRegistered) {
            try {
                unregisterReceiver(pipControlReceiver)
            } catch (_: Exception) {}
            pipReceiverRegistered = false
        }
        super.onDestroy()
    }

    private fun requestPlaybackAudioFocus(): Boolean {
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = audioFocusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
                .setWillPauseWhenDucked(true)
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
        endPlaybackWindow()
        abandonPlaybackAudioFocus()
        audioFocusChannel?.setMethodCallHandler(null)
        audioFocusChannel = null
        pipChannel?.setMethodCallHandler(null)
        pipChannel = null
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
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(bars)
        } else {
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
        previousOrientation?.let { requestedOrientation = it }
        previousOrientation = null
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
        // Android 8 ~ 11 在离开前台时依据实时资格触发画中画（Android 12+ 由 setAutoEnterEnabled 接管）
        if (Build.VERSION.SDK_INT in Build.VERSION_CODES.O..Build.VERSION_CODES.R) {
            if (pipEligible && !isInPictureInPictureMode) {
                try {
                    enterPictureInPictureMode(buildPipParams())
                } catch (_: Exception) {}
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
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
        MethodChannel(messenger, "ccplayer/network", StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue()).setMethodCallHandler { call, result ->
            if (call.method != "proxy") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val uri = java.net.URI(call.arguments as String)
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
                result.success(value)
            } catch (_: Exception) {
                result.error("proxy_unavailable", "Cannot resolve system proxy", null)
            }
        }
        audioFocusChannel = MethodChannel(messenger, "ccplayer/audio_focus").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" -> result.success(requestPlaybackAudioFocus())
                    "abandon" -> { abandonPlaybackAudioFocus(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
        }
        pipChannel = MethodChannel(messenger, "ccplayer/pip").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "syncState" -> {
                        val args = call.arguments as? Map<*, *>
                        if (args != null) {
                            pipEligible = args["eligible"] == true
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
        MethodChannel(messenger, "ccplayer/artwork").setMethodCallHandler { call, result ->
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
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "ccplayer/android_surface", AndroidVideoSurfaceFactory(messenger))
        MethodChannel(messenger, "ccplayer/playback_window").setMethodCallHandler { call, result ->
            when (call.method) {
                "begin" -> {
                    if (previousOrientation == null) {
                        previousOrientation = requestedOrientation
                        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
                    }
                    result.success(null)
                }
                "orientationLocked" -> {
                    val locked = call.arguments as? Boolean
                    if (locked == null) {
                        result.error("playback_inactive", "Playback window is unavailable", null)
                    } else {
                        if (previousOrientation == null) {
                            previousOrientation = requestedOrientation
                        }
                        // 锁定精确当前朝向（含反向横竖屏），解锁后恢复传感器自由旋转
                        requestedOrientation = if (locked) ActivityInfo.SCREEN_ORIENTATION_LOCKED
                            else ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
                        result.success(locked)
                    }
                }
                "setLandscape" -> {
                    val landscape = call.arguments == true
                    if (previousOrientation == null) {
                        previousOrientation = requestedOrientation
                    }
                    requestedOrientation = if (landscape) {
                        ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                    } else {
                        ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
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
        MethodChannel(messenger, "ccplayer/mpv_profile", StandardMethodCodec.INSTANCE,
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
        MethodChannel(messenger, "ccplayer/local_media", StandardMethodCodec.INSTANCE,
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
}
