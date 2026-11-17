package com.anime.konata

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.PixelFormat
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Build
import android.os.Looper
import android.view.PixelCopy
import android.view.Display
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

/// 原生播放视频表面；仅在播放会话创建后分配底层视图与缓冲。
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
    private val displays = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(id: Int) = Unit
        override fun onDisplayRemoved(id: Int) = refreshDisplay()
        override fun onDisplayChanged(id: Int) = refreshDisplay()
    }
    private var lastHdrPeak = -1
    private val helper = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper")
    private val retain = helper.getDeclaredMethod("newGlobalObjectRef", Any::class.java).apply { isAccessible = true }
    private val release = helper.getDeclaredMethod("deleteGlobalObjectRef", Long::class.javaPrimitiveType).apply { isAccessible = true }

    init {
        view.holder.setFormat(PixelFormat.RGBA_1010102)
        view.holder.addCallback(this)
        displays.registerDisplayListener(displayListener, main)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "current" -> result.success(if (current == 0L) null else state())
                "capturePrecision" -> capture(result, false, call.argument<Boolean>("pq") == true,
                    call.argument<Boolean>("packed10") == true)
                "captureFrame" -> capture(result, true, call.argument<Boolean>("pq") == true,
                    call.argument<Boolean>("packed10") == true)
                "release" -> {
                    val reference = (call.arguments as Number).toLong()
                    if (references.remove(reference)) release.invoke(null, reference)
                    if (closed && disposed && references.isEmpty()) channel.setMethodCallHandler(null)
                    result.success(null)
                }
                "releaseAll" -> {
                    closed = true
                    displays.unregisterDisplayListener(displayListener)
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

    private fun hdrPeak(): Int {
        val caps = view.display?.hdrCapabilities ?: return 0
        if (!caps.supportedHdrTypes.contains(Display.HdrCapabilities.HDR_TYPE_HDR10)) return 0
        val peak = caps.desiredMaxLuminance
        // 未识别或无效峰值数据时回落至标准 SDR 渲染路径。
        return if (peak.isFinite() && peak in 100f..10000f) peak.toInt() else 0
    }

    private fun refreshDisplay() {
        if (closed || disposed || current == 0L) return
        val peak = hdrPeak()
        if (peak != lastHdrPeak) channel.invokeMethod("changed", state())
    }

    private fun state(): Map<String, Any> {
        lastHdrPeak = hdrPeak()
        return mapOf("wid" to current, "width" to width, "height" to height,
            "holderFormat" to format, "references" to references.size,
            "hdrPeak" to lastHdrPeak, "displayId" to (view.display?.displayId ?: -1))
    }

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
        displays.unregisterDisplayListener(displayListener)
        view.holder.removeCallback(this)
        current = 0
        // Dart 侧仅在 mpv 解绑 EGL 后才逐一确认表面引用；即使页面弹出，也保留通道至全部确认完成。
        channel.invokeMethod("lost", null)
        // 丢弃事件可能在 Dart 调用 releaseAll 前释放最后一个引用，因此需维持末次确认通道可达。
        if (closed && references.isEmpty()) channel.setMethodCallHandler(null)
    }

    private fun capture(result: MethodChannel.Result, fullFrame: Boolean, pq: Boolean, packed10: Boolean) {
        if (disposed || copying || current == 0L || width !in 1..8192 || height <= 0 ||
            width.toLong() * height > 16777216) {
            result.error("surface_unavailable", "Native surface is unavailable", null)
            return
        }
        if (pq && Build.VERSION.SDK_INT < 34) {
            result.error("capture_unsupported", "PQ diagnostic readback requires Android 14", null)
            return
        }
        if (packed10 && Build.VERSION.SDK_INT < 33) {
            result.error("capture_unsupported", "RGB10 diagnostic readback requires Android 13", null)
            return
        }
        copying = true
        // 默认仅截取单行扫描样本；全帧回读仅用于显式诊断请求，且缓冲不落盘、不逐帧运行。
        val space = if (pq) ColorSpace.get(ColorSpace.Named.BT2020_PQ)
            else ColorSpace.get(ColorSpace.Named.SRGB)
        val bitmap = Bitmap.createBitmap(width, if (fullFrame) height else 1,
            if (packed10) Bitmap.Config.RGBA_1010102 else Bitmap.Config.RGBA_F16, true, space)
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
                    val levels = List(3) { mutableSetOf<Int>() }
                    repeat(bitmap.width) {
                        if (packed10) {
                            val pixel = bytes.int
                            repeat(3) { component ->
                                levels[component].add((pixel ushr (component * 10)) and 1023)
                            }
                        } else {
                            repeat(3) { component -> levels[component].add(bytes.short.toInt()) }
                            bytes.short
                        }
                    }
                    val hash = MessageDigest.getInstance("SHA-256").digest(bytes.array())
                        .joinToString("") { "%02x".format(it.toInt() and 255) }
                    result.success(state() + mapOf("readback" to
                        (if (packed10) "RGBA_1010102" else "RGBA_F16"), "colorSpace" to space.name,
                        "rowSha256" to hash,
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
