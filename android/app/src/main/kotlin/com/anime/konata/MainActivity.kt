package com.anime.konata

import io.flutter.embedding.android.FlutterActivity
import android.net.Uri
import android.content.Intent
import android.content.pm.ActivityInfo
import android.media.AudioManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.os.Build
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.ByteArrayOutputStream
import java.io.IOException

class MainActivity : FlutterActivity() {
    private var previousOrientation: Int? = null
    private var playbackFullscreen = false
    private var previousBarsBehavior = 0
    private var visibleBars = 0
    private var audioFocusChannel: MethodChannel? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private val audioManager by lazy { getSystemService(AUDIO_SERVICE) as AudioManager }
    private val audioFocusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK) {
            // Pause spoken video on any interruption. Resume is user initiated.
            runOnUiThread { audioFocusChannel?.invokeMethod("loss", null) }
        }
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
            audioManager.requestAudioFocus(audioFocusListener, AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN)
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

    private fun endPlaybackWindow() {
        setPlaybackFullscreen(false)
        previousOrientation?.let { requestedOrientation = it }
        previousOrientation = null
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && playbackFullscreen) setPlaybackFullscreen(true)
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
                        else -> throw java.io.IOException("Unsupported system proxy")
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
                    if (locked == null || previousOrientation == null) {
                        result.error("playback_inactive", "Playback window is unavailable", null)
                    } else {
                        // LOCKED preserves the exact current orientation, including
                        // reverse portrait/landscape; no device-name heuristics.
                        requestedOrientation = if (locked) ActivityInfo.SCREEN_ORIENTATION_LOCKED
                            else ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
                        result.success(locked)
                    }
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
            } catch (e: Exception) {
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
            } catch (e: Exception) {
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
