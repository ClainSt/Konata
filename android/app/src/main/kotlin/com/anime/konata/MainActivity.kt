package com.anime.konata

import io.flutter.embedding.android.FlutterActivity
import android.net.Uri
import android.content.pm.ActivityInfo
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
    private var previousBarsBehavior = 0
    private var visibleBars = 0

    private fun setPlaybackFullscreen(enabled: Boolean) {
        val decor = window.decorView
        val controller = WindowCompat.getInsetsController(window, decor)
        val bars = WindowInsetsCompat.Type.systemBars()
        if (enabled) {
            if (previousOrientation == null) {
                previousOrientation = requestedOrientation
                previousBarsBehavior = controller.systemBarsBehavior
                val insets = androidx.core.view.ViewCompat.getRootWindowInsets(decor)
                visibleBars = listOf(WindowInsetsCompat.Type.statusBars(), WindowInsetsCompat.Type.navigationBars())
                    .filter { insets?.isVisible(it) != false }.fold(0, Int::or)
                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            }
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(bars)
        } else {
            val orientation = previousOrientation ?: return
            previousOrientation = null
            requestedOrientation = orientation
            controller.systemBarsBehavior = previousBarsBehavior
            controller.show(visibleBars)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && previousOrientation != null) setPlaybackFullscreen(true)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "ccplayer/playback_window").setMethodCallHandler { call, result ->
            if (call.method == "fullscreen" && call.arguments is Boolean) {
                setPlaybackFullscreen(call.arguments as Boolean)
                result.success(null)
            } else {
                result.notImplemented()
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
