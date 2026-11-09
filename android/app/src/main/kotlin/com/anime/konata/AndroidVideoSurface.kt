package com.anime.konata

import android.content.Context
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/** Native playback surface. No view or buffer exists until playback creates it. */
class AndroidVideoSurfaceFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        AndroidVideoSurface(context, viewId, messenger)
}

private class AndroidVideoSurface(context: Context, id: Int, messenger: BinaryMessenger) :
    PlatformView, SurfaceHolder.Callback {
    private val view = SurfaceView(context)
    private val channel = MethodChannel(messenger, "ccplayer/android_surface/$id")
    private val main = Handler(Looper.getMainLooper())
    private val references = mutableListOf<Long>()
    private var current = 0L
    private var width = 0
    private var height = 0
    private var format = PixelFormat.UNKNOWN
    private var copying = false
    private var disposed = false
    private var closed = false
    private val helper = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper")
    private val retain = helper.getDeclaredMethod("newGlobalObjectRef", Any::class.java).apply { isAccessible = true }
    private val release = helper.getDeclaredMethod("deleteGlobalObjectRef", Long::class.javaPrimitiveType).apply { isAccessible = true }

    init {
        view.holder.setFormat(PixelFormat.RGBA_1010102)
        view.holder.addCallback(this)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "current" -> result.success(if (current == 0L) null else state())
                "capturePrecision" -> capture(result, false)
                "captureFrame" -> capture(result, true)
                "release" -> {
                    val reference = (call.arguments as Number).toLong()
                    if (references.remove(reference)) release.invoke(null, reference)
                    if (disposed && references.isEmpty()) channel.setMethodCallHandler(null)
                    result.success(null)
                }
                "releaseAll" -> {
                    closed = true
                    references.forEach { release.invoke(null, it) }
                    references.clear()
                    current = 0L
                    if (disposed) channel.setMethodCallHandler(null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun state(): Map<String, Any> = mapOf("wid" to current, "width" to width,
        "height" to height, "holderFormat" to format, "references" to references.size)

    override fun getView(): View = view
    override fun surfaceCreated(holder: SurfaceHolder) {
        if (closed || disposed) return
        current = retain.invoke(null, holder.surface) as Long
        references.add(current)
    }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        if (closed || disposed) return
        this.format = format
        this.width = width
        this.height = height
        channel.invokeMethod("changed", state())
    }
    override fun surfaceDestroyed(holder: SurfaceHolder) {
        current = 0
        channel.invokeMethod("lost", null)
    }
    override fun dispose() {
        disposed = true
        view.holder.removeCallback(this)
        current = 0
        // Dart acknowledges each reference only after mpv has detached EGL.
        // Keep the channel until those acknowledgements arrive, including pop.
        channel.invokeMethod("lost", null)
        if (references.isEmpty()) channel.setMethodCallHandler(null)
    }

    private fun capture(result: MethodChannel.Result, fullFrame: Boolean) {
        if (disposed || copying || current == 0L || width !in 1..8192 || height <= 0 ||
            width.toLong() * height > 16777216) {
            result.error("surface_unavailable", "Native surface is unavailable", null)
            return
        }
        copying = true
        // Normally read one bounded row; full-frame readback is an explicit
        // diagnostic request. These buffers never persist or run per frame.
        val bitmap = Bitmap.createBitmap(width, if (fullFrame) height else 1, Bitmap.Config.RGBA_F16)
        val region = if (fullFrame) Rect(0, 0, width, height)
            else Rect(0, height / 2, width, height / 2 + 1)
        PixelCopy.request(view, region, bitmap, { status ->
            try {
                if (status != PixelCopy.SUCCESS) {
                    result.error("surface_copy_failed", "PixelCopy status $status", null)
                } else {
                    val bytes = ByteBuffer.allocate(bitmap.byteCount).order(ByteOrder.LITTLE_ENDIAN)
                    bitmap.copyPixelsToBuffer(bytes)
                    bytes.rewind()
                    val levels = List(3) { mutableSetOf<Short>() }
                    repeat(bitmap.width) {
                        repeat(3) { component -> levels[component].add(bytes.short) }
                        bytes.short
                    }
                    val hash = MessageDigest.getInstance("SHA-256").digest(bytes.array())
                        .joinToString("") { "%02x".format(it.toInt() and 255) }
                    result.success(state() + mapOf("readback" to "RGBA_F16", "rowSha256" to hash,
                        "redLevels" to levels[0].size, "greenLevels" to levels[1].size,
                        "blueLevels" to levels[2].size) +
                        if (fullFrame) mapOf("pixels" to bytes.array(), "rowBytes" to bitmap.rowBytes)
                        else emptyMap<String, Any>())
                }
            } finally {
                bitmap.recycle()
                copying = false
            }
        }, main)
    }
}
