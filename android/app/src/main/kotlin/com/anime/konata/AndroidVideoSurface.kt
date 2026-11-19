package com.anime.konata

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.Outline
import android.graphics.PixelFormat
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.Gravity
import android.view.PixelCopy
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlin.math.abs
import kotlin.math.max

/// Android 根窗口底层（Underlay）原画视频表面宿主。
///
/// 将原生 `SurfaceView` 直接挂载于 `Activity` 根容器最底层（位于透明 `FlutterSurfaceView` 之下），
/// 彻底消除 `PlatformView` 跨线程同步掉帧与 Z-Order 竞态，使全部 Flutter 弹窗、侧栏与下拉菜单物理天然覆盖在实时视频小窗之上。
class AndroidUnderlaySurfaceHost(
    private val activity: Activity,
    messenger: BinaryMessenger
) : SurfaceHolder.Callback {
    companion object {
        const val CHANNEL_NAME = "ccplayer/android_underlay_surface"
    }

    private var surfaceView: SurfaceView? = null
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val main = Handler(Looper.getMainLooper())
    private val references = mutableListOf<Long>()
    private var current = 0L
    private var width = 0
    private var height = 0
    private var format = PixelFormat.UNKNOWN
    private var copying = false
    private var attachedToRoot = false
    private var displayListenerRegistered = false
    private var disposed = false
    private var lastLeft = Int.MIN_VALUE
    private var lastTop = Int.MIN_VALUE
    private var lastWidth = -1
    private var lastHeight = -1
    private var lastRadiusPx = -1f
    private var displays: DisplayManager? = null
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(id: Int) = Unit
        override fun onDisplayRemoved(id: Int) = refreshDisplay()
        override fun onDisplayChanged(id: Int) = refreshDisplay()
    }
    private var lastHdrPeak = -1
    private val helperClass by lazy {
        Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper")
    }
    private val retain by lazy {
        helperClass.getDeclaredMethod("newGlobalObjectRef", Any::class.java).apply {
            isAccessible = true
        }
    }
    private val release by lazy {
        helperClass.getDeclaredMethod("deleteGlobalObjectRef", Long::class.javaPrimitiveType).apply {
            isAccessible = true
        }
    }

    init {
        // 严格惰性初始化：空载浏览期不创建 SurfaceView、不加载 mediakitandroidhelper 原生库、不注册显示监听。
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val v = ensureAttachedToRoot()
                    val args = call.arguments as? Map<*, *>
                    if (v != null && args != null) {
                        applyRectFromArgs(v, args)
                    }
                    if (v != null && v.visibility != View.VISIBLE) {
                        v.visibility = View.VISIBLE
                    }
                    result.success(if (current == 0L) null else state())
                }
                "setRect" -> {
                    val v = ensureAttachedToRoot()
                    val args = call.arguments as? Map<*, *>
                    if (v != null && args != null) {
                        applyRectFromArgs(v, args)
                        if (v.visibility != View.VISIBLE) {
                            v.visibility = View.VISIBLE
                        }
                    }
                    result.success(null)
                }
                "hide" -> {
                    hideView()
                    result.success(null)
                }
                "current" -> result.success(if (current == 0L) null else state())
                "capturePrecision" -> capture(
                    result,
                    false,
                    call.argument<Boolean>("pq") == true,
                    call.argument<Boolean>("packed10") == true
                )
                "captureFrame" -> capture(
                    result,
                    true,
                    call.argument<Boolean>("pq") == true,
                    call.argument<Boolean>("packed10") == true
                )
                "release" -> {
                    val reference = (call.arguments as? Number)?.toLong()
                    if (reference != null) {
                        if (references.remove(reference)) {
                            release.invoke(null, reference)
                        }
                    } else {
                        releaseAllReferences()
                    }
                    result.success(null)
                }
                "releaseAll" -> {
                    hideView()
                    releaseAllReferences()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun ensureAttachedToRoot(): SurfaceView? {
        if (disposed) return null
        val existing = surfaceView
        if (existing != null && attachedToRoot) return existing
        val contentRoot = activity.findViewById<ViewGroup>(android.R.id.content) ?: return null
        val created = existing ?: SurfaceView(activity).also { sv ->
            // 严格保持默认窗口底层 Z 序，位于 `BackgroundMode.transparent` 的上层 Flutter 画布之后。
            sv.setZOrderOnTop(false)
            sv.setZOrderMediaOverlay(false)
            sv.visibility = View.GONE
            sv.holder.addCallback(this)
            surfaceView = sv
        }
        if (!displayListenerRegistered) {
            val dm = displays ?: (activity.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).also {
                displays = it
            }
            dm.registerDisplayListener(displayListener, main)
            displayListenerRegistered = true
        }
        if (!attachedToRoot) {
            val lp = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
                Gravity.TOP or Gravity.START
            )
            contentRoot.addView(created, 0, lp)
            attachedToRoot = true
        }
        return created
    }

    private fun applyRectFromArgs(view: SurfaceView, args: Map<*, *>) {
        val leftPx = (args["leftPx"] as? Number)?.toInt() ?: 0
        val topPx = (args["topPx"] as? Number)?.toInt() ?: 0
        val rightPx = (args["rightPx"] as? Number)?.toInt() ?: 0
        val bottomPx = (args["bottomPx"] as? Number)?.toInt() ?: 0
        val radiusPx = ((args["radiusPx"] as? Number)?.toFloat() ?: 0f).coerceAtLeast(0f)

        val targetW = max(1, rightPx - leftPx)
        val targetH = max(1, bottomPx - topPx)
        if (leftPx != lastLeft || topPx != lastTop || targetW != lastWidth || targetH != lastHeight) {
            lastLeft = leftPx
            lastTop = topPx
            lastWidth = targetW
            lastHeight = targetH
            val lp = (view.layoutParams as? FrameLayout.LayoutParams)
                ?: FrameLayout.LayoutParams(targetW, targetH, Gravity.TOP or Gravity.START)
            lp.width = targetW
            lp.height = targetH
            lp.leftMargin = leftPx
            lp.topMargin = topPx
            lp.gravity = Gravity.TOP or Gravity.START
            view.layoutParams = lp
        }

        if (abs(radiusPx - lastRadiusPx) > 0.25f) {
            lastRadiusPx = radiusPx
            if (radiusPx > 0.5f) {
                view.outlineProvider = object : ViewOutlineProvider() {
                    override fun getOutline(target: View, outline: Outline) {
                        outline.setRoundRect(0, 0, target.width, target.height, radiusPx)
                    }
                }
                view.clipToOutline = true
            } else {
                view.clipToOutline = false
                view.outlineProvider = ViewOutlineProvider.BACKGROUND
            }
            view.invalidateOutline()
        }
    }

    private fun hideView() {
        val view = surfaceView
        if (view != null) {
            if (view.visibility != View.GONE) {
                view.visibility = View.GONE
            }
            view.clipToOutline = false
        }
        lastLeft = Int.MIN_VALUE
        lastTop = Int.MIN_VALUE
        lastWidth = -1
        lastHeight = -1
        lastRadiusPx = -1f
    }

    private fun releaseAllReferences() {
        if (references.isNotEmpty()) {
            references.forEach { release.invoke(null, it) }
            references.clear()
        }
        current = 0L
    }

    private fun hdrPeak(): Int {
        val display = surfaceView?.display ?: activity.window?.decorView?.display
        val caps = display?.hdrCapabilities ?: return 0
        if (!caps.supportedHdrTypes.contains(Display.HdrCapabilities.HDR_TYPE_HDR10)) return 0
        val peak = caps.desiredMaxLuminance
        // 未识别或无效峰值数据时回落至标准 SDR 渲染路径。
        return if (peak.isFinite() && peak in 100f..10000f) peak.toInt() else 0
    }

    private fun refreshDisplay() {
        if (disposed || current == 0L) return
        val peak = hdrPeak()
        if (peak != lastHdrPeak) {
            channel.invokeMethod("changed", state())
        }
    }

    private fun state(): Map<String, Any> {
        lastHdrPeak = hdrPeak()
        val displayId = surfaceView?.display?.displayId ?: activity.window?.decorView?.display?.displayId ?: -1
        return mapOf(
            "wid" to current,
            "width" to width,
            "height" to height,
            "holderFormat" to format,
            "references" to references.size,
            "hdrPeak" to lastHdrPeak,
            "displayId" to displayId
        )
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        if (disposed) return
        current = retain.invoke(null, holder.surface) as Long
        references.add(current)
        val frame = holder.surfaceFrame
        if (frame.width() > 0 && frame.height() > 0) {
            this.width = frame.width()
            this.height = frame.height()
            channel.invokeMethod("changed", state())
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        if (disposed) return
        this.format = format
        this.width = width
        this.height = height
        if (current == 0L) {
            current = retain.invoke(null, holder.surface) as Long
            references.add(current)
        }
        channel.invokeMethod("changed", state())
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        current = 0L
        channel.invokeMethod("lost", null)
    }

    /// 随宿主引擎清理同步拆卸底层表面、注销回调并释放残留 JNI 引用。
    fun destroy() {
        if (disposed) return
        disposed = true
        if (displayListenerRegistered) {
            displays?.unregisterDisplayListener(displayListener)
            displayListenerRegistered = false
        }
        val view = surfaceView
        if (view != null) {
            view.holder.removeCallback(this)
            hideView()
            (view.parent as? ViewGroup)?.removeView(view)
            surfaceView = null
        }
        attachedToRoot = false
        releaseAllReferences()
        channel.setMethodCallHandler(null)
    }

    private fun capture(result: MethodChannel.Result, fullFrame: Boolean, pq: Boolean, packed10: Boolean) {
        val view = surfaceView
        if (disposed || copying || view == null || current == 0L || width !in 1..8192 || height <= 0 ||
            width.toLong() * height > 16777216
        ) {
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
        val space = if (pq) {
            ColorSpace.get(ColorSpace.Named.BT2020_PQ)
        } else {
            ColorSpace.get(ColorSpace.Named.SRGB)
        }
        val bitmap = Bitmap.createBitmap(
            width,
            if (fullFrame) height else 1,
            if (packed10) Bitmap.Config.RGBA_1010102 else Bitmap.Config.RGBA_F16,
            true,
            space
        )
        val region = if (fullFrame) {
            Rect(0, 0, width, height)
        } else {
            Rect(0, height / 2, width, height / 2 + 1)
        }
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
                    result.success(
                        state() + mapOf(
                            "readback" to (if (packed10) "RGBA_1010102" else "RGBA_F16"),
                            "colorSpace" to space.name,
                            "rowSha256" to hash,
                            "redLevels" to levels[0].size,
                            "greenLevels" to levels[1].size,
                            "blueLevels" to levels[2].size
                        ) + if (fullFrame) {
                            mapOf("pixels" to bytes.array(), "rowBytes" to bitmap.rowBytes)
                        } else {
                            emptyMap<String, Any>()
                        }
                    )
                }
            } finally {
                bitmap.recycle()
                copying = false
            }
        }, main)
    }
}
