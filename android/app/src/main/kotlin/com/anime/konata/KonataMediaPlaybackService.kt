package com.anime.konata

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import androidx.core.content.ContextCompat
import kotlin.math.max
import kotlin.math.roundToInt

/// 进程内媒体会话状态快照与控制指令分发中心（连接 Flutter 音频控制器与系统前台媒体服务）。
object KonataMediaSessionDispatcher {
    data class Snapshot(
        val active: Boolean = false,
        val title: String = "",
        val artist: String = "",
        val album: String = "",
        val durationMs: Long = 0L,
        val positionMs: Long = 0L,
        val isPlaying: Boolean = false,
        val coverKey: String = "",
        val updatedElapsedRealtimeMs: Long = 0L,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private var currentSnapshot = Snapshot()
    private var cachedCoverKey: String = ""
    private var cachedCoverBitmap: Bitmap? = null

    internal var liveService: KonataMediaPlaybackService? = null
    var onTransportCommand: ((command: String, positionMs: Long?) -> Unit)? = null

    fun current(): Snapshot = currentSnapshot
    fun currentCover(): Bitmap? = cachedCoverBitmap

    /// 接收来自 Dart 音频控制器的状态同步并启动或刷新系统媒体通知服务。
    fun updateFromDart(context: Context, args: Map<*, *>) {
        val title = (args["title"] as? String)?.trim().orEmpty()
        if (title.isEmpty()) {
            stopFromDart(context)
            return
        }
        val artist = (args["artist"] as? String)?.trim().orEmpty()
        val album = (args["album"] as? String)?.trim().orEmpty()
        val durationMs = ((args["durationMs"] as? Number)?.toLong() ?: 0L).coerceAtLeast(0L)
        val positionMs = ((args["positionMs"] as? Number)?.toLong() ?: 0L).coerceAtLeast(0L)
        val isPlaying = args["isPlaying"] == true
        val coverKey = (args["coverKey"] as? String).orEmpty()
        val coverBytes = args["coverBytes"] as? ByteArray

        if (coverKey.isEmpty()) {
            cachedCoverKey = ""
            cachedCoverBitmap = null
        } else if (coverBytes != null && coverBytes.isNotEmpty() && coverKey != cachedCoverKey) {
            decodeScaledArtwork(coverBytes)?.let { decoded ->
                cachedCoverKey = coverKey
                cachedCoverBitmap = decoded
            }
        }

        currentSnapshot = Snapshot(
            active = true,
            title = title,
            artist = artist,
            album = album,
            durationMs = durationMs,
            positionMs = positionMs,
            isPlaying = isPlaying,
            coverKey = coverKey,
            updatedElapsedRealtimeMs = SystemClock.elapsedRealtime(),
        )

        val running = liveService
        if (running != null) {
            running.refreshSessionAndNotification()
            return
        }

        val intent = Intent(context, KonataMediaPlaybackService::class.java)
            .setAction(KonataMediaPlaybackService.ACTION_SYNC)
        try {
            ContextCompat.startForegroundService(context, intent)
        } catch (_: Exception) {
            try {
                context.startService(intent)
            } catch (_: Exception) {}
        }
    }

    /// 停止音频会话并移除系统通知栏媒体卡片。
    fun stopFromDart(context: Context) {
        currentSnapshot = Snapshot(active = false)
        cachedCoverKey = ""
        cachedCoverBitmap = null
        val running = liveService
        if (running != null) {
            running.stopSessionAndService()
        } else {
            try {
                context.stopService(Intent(context, KonataMediaPlaybackService::class.java))
            } catch (_: Exception) {}
        }
    }

    /// 将锁屏、通知栏或蓝牙耳机媒体操作回传至主线程 Dart 通道。
    fun dispatch(command: String, positionMs: Long? = null) {
        mainHandler.post {
            onTransportCommand?.invoke(command, positionMs)
        }
    }

    /// 解码并等比缩放专辑封面至最大边 `512px`，兼顾通知栏高清显示与跨进程 `Binder` 载荷上限。
    private fun decodeScaledArtwork(bytes: ByteArray): Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val srcW = bounds.outWidth
            val srcH = bounds.outHeight
            if (srcW <= 0 || srcH <= 0) return null
            val targetMax = 512
            var sampleSize = 1
            while (max(srcW, srcH) / (sampleSize * 2) >= targetMax) {
                sampleSize *= 2
            }
            val decodeOpts = BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            val raw = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, decodeOpts) ?: return null
            val longest = max(raw.width, raw.height)
            if (longest <= targetMax) {
                raw
            } else {
                val scale = targetMax.toFloat() / longest.toFloat()
                val dstW = (raw.width * scale).roundToInt().coerceAtLeast(1)
                val dstH = (raw.height * scale).roundToInt().coerceAtLeast(1)
                val scaled = Bitmap.createScaledBitmap(raw, dstW, dstH, true)
                if (scaled !== raw) {
                    raw.recycle()
                }
                scaled
            }
        } catch (_: Throwable) {
            null
        }
    }
}

/// Android 原生媒体播放前台服务：驱动系统 `MediaSession` 与 `MediaStyle` 通知中心/锁屏播控卡片。
class KonataMediaPlaybackService : Service() {
    companion object {
        const val CHANNEL_ID = "konata_media_playback"
        const val NOTIFICATION_ID = 7201
        const val ACTION_SYNC = "com.anime.konata.MEDIA_SYNC"
        const val ACTION_PREV = "com.anime.konata.MEDIA_PREV"
        const val ACTION_TOGGLE = "com.anime.konata.MEDIA_TOGGLE"
        const val ACTION_NEXT = "com.anime.konata.MEDIA_NEXT"
        const val ACTION_STOP = "com.anime.konata.MEDIA_STOP"

        private const val REQ_CONTENT = 7210
        private const val REQ_PREV = 7211
        private const val REQ_TOGGLE = 7212
        private const val REQ_NEXT = 7213
        private const val REQ_STOP = 7214
    }

    private var mediaSession: MediaSession? = null
    private var foregroundStarted = false
    private var lastMetadataSignature: String = ""
    private val notificationManager by lazy {
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    }

    override fun onCreate() {
        super.onCreate()
        KonataMediaSessionDispatcher.liveService = this
        ensureNotificationChannel()
        val session = MediaSession(this, "KonataAudioSession")
        session.setSessionActivity(buildContentPendingIntent())
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() {
                KonataMediaSessionDispatcher.dispatch("play")
            }

            override fun onPause() {
                KonataMediaSessionDispatcher.dispatch("pause")
            }

            override fun onSkipToPrevious() {
                KonataMediaSessionDispatcher.dispatch("previous")
            }

            override fun onSkipToNext() {
                KonataMediaSessionDispatcher.dispatch("next")
            }

            override fun onSeekTo(pos: Long) {
                KonataMediaSessionDispatcher.dispatch("seekTo", pos.coerceAtLeast(0L))
            }

            override fun onStop() {
                KonataMediaSessionDispatcher.dispatch("stop")
            }

            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                val keyEvent: KeyEvent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                }
                if (keyEvent != null &&
                    keyEvent.action == KeyEvent.ACTION_DOWN &&
                    keyEvent.repeatCount == 0 &&
                    (keyEvent.keyCode == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE ||
                        keyEvent.keyCode == KeyEvent.KEYCODE_HEADSETHOOK)
                ) {
                    KonataMediaSessionDispatcher.dispatch("togglePlayPause")
                    return true
                }
                return super.onMediaButtonEvent(mediaButtonIntent)
            }
        })
        session.isActive = true
        mediaSession = session
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PREV -> KonataMediaSessionDispatcher.dispatch("previous")
            ACTION_TOGGLE -> KonataMediaSessionDispatcher.dispatch("togglePlayPause")
            ACTION_NEXT -> KonataMediaSessionDispatcher.dispatch("next")
            ACTION_STOP -> {
                KonataMediaSessionDispatcher.dispatch("stop")
                stopSessionAndService()
                return START_NOT_STICKY
            }
        }
        val snap = KonataMediaSessionDispatcher.current()
        if (!snap.active || snap.title.isEmpty()) {
            stopSessionAndService()
            return START_NOT_STICKY
        }
        refreshSessionAndNotification()
        return START_NOT_STICKY
    }

    /// 同步刷新 `MediaSession` 元数据、可拖拽进度状态与系统通知栏媒体卡片。
    fun refreshSessionAndNotification() {
        val snap = KonataMediaSessionDispatcher.current()
        val session = mediaSession ?: return
        if (!snap.active || snap.title.isEmpty()) {
            stopSessionAndService()
            return
        }
        val coverBitmap = KonataMediaSessionDispatcher.currentCover()
        val metadataSig =
            "${snap.title}|${snap.artist}|${snap.album}|${snap.durationMs}|${snap.coverKey}|${coverBitmap != null}"
        if (metadataSig != lastMetadataSignature) {
            lastMetadataSignature = metadataSig
            val metaBuilder = MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, snap.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, snap.artist)
                .putString(MediaMetadata.METADATA_KEY_ALBUM, snap.album)
                .putLong(
                    MediaMetadata.METADATA_KEY_DURATION,
                    if (snap.durationMs > 0L) snap.durationMs else -1L
                )
            if (coverBitmap != null && !coverBitmap.isRecycled) {
                metaBuilder.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, coverBitmap)
                metaBuilder.putBitmap(MediaMetadata.METADATA_KEY_ART, coverBitmap)
            }
            session.setMetadata(metaBuilder.build())
        }

        val actions = PlaybackState.ACTION_PLAY or
            PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SKIP_TO_PREVIOUS or
            PlaybackState.ACTION_SKIP_TO_NEXT or
            PlaybackState.ACTION_SEEK_TO or
            PlaybackState.ACTION_STOP
        val elapsedDelta = if (snap.isPlaying && snap.updatedElapsedRealtimeMs > 0L) {
            (SystemClock.elapsedRealtime() - snap.updatedElapsedRealtimeMs).coerceAtLeast(0L)
        } else {
            0L
        }
        val rawLivePos = snap.positionMs + elapsedDelta
        val effectivePos = if (snap.durationMs > 0L) {
            rawLivePos.coerceIn(0L, snap.durationMs)
        } else {
            rawLivePos.coerceAtLeast(0L)
        }
        val pbState = PlaybackState.Builder()
            .setActions(actions)
            .setState(
                if (snap.isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                effectivePos,
                if (snap.isPlaying) 1.0f else 0.0f,
                SystemClock.elapsedRealtime()
            )
            .build()
        session.setPlaybackState(pbState)
        if (!session.isActive) {
            session.isActive = true
        }

        val notification = buildMediaNotification(session, snap, coverBitmap)
        if (!foregroundStarted) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                foregroundStarted = true
            } catch (_: Exception) {
                notificationManager.notify(NOTIFICATION_ID, notification)
            }
        } else {
            notificationManager.notify(NOTIFICATION_ID, notification)
        }
    }

    /// 停止前台服务并清理通知与会话。
    fun stopSessionAndService() {
        try {
            mediaSession?.isActive = false
        } catch (_: Exception) {}
        if (foregroundStarted) {
            try {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } catch (_: Exception) {}
            foregroundStarted = false
        }
        try {
            notificationManager.cancel(NOTIFICATION_ID)
        } catch (_: Exception) {}
        stopSelf()
    }

    private fun buildMediaNotification(
        session: MediaSession,
        snap: KonataMediaSessionDispatcher.Snapshot,
        coverBitmap: Bitmap?,
    ): Notification {
        val prevAction = Notification.Action.Builder(
            Icon.createWithResource(this, android.R.drawable.ic_media_previous),
            "上一首",
            buildServiceActionIntent(REQ_PREV, ACTION_PREV)
        ).build()
        val toggleAction = Notification.Action.Builder(
            Icon.createWithResource(
                this,
                if (snap.isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
            ),
            if (snap.isPlaying) "暂停" else "播放",
            buildServiceActionIntent(REQ_TOGGLE, ACTION_TOGGLE)
        ).build()
        val nextAction = Notification.Action.Builder(
            Icon.createWithResource(this, android.R.drawable.ic_media_next),
            "下一首",
            buildServiceActionIntent(REQ_NEXT, ACTION_NEXT)
        ).build()

        val style = Notification.MediaStyle()
            .setMediaSession(session.sessionToken)
            .setShowActionsInCompactView(0, 1, 2)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder
            .setSmallIcon(R.drawable.ic_stat_konata_media)
            .setContentTitle(snap.title)
            .setContentText(snap.artist)
            .setSubText(snap.album.takeIf { it.isNotEmpty() && it != snap.artist })
            .setContentIntent(buildContentPendingIntent())
            .setDeleteIntent(buildServiceActionIntent(REQ_STOP, ACTION_STOP))
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setOngoing(snap.isPlaying)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setStyle(style)
            .addAction(prevAction)
            .addAction(toggleAction)
            .addAction(nextAction)

        if (coverBitmap != null && !coverBitmap.isRecycled) {
            builder.setLargeIcon(coverBitmap)
        }
        return builder.build()
    }

    private fun buildContentPendingIntent(): PendingIntent {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(this, REQ_CONTENT, launchIntent, piFlags)
    }

    private fun buildServiceActionIntent(requestCode: Int, action: String): PendingIntent {
        val intent = Intent(this, KonataMediaPlaybackService::class.java).setAction(action)
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getService(this, requestCode, intent, piFlags)
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val existing = notificationManager.getNotificationChannel(CHANNEL_ID)
        if (existing != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "音频播放控制",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "展示当前播放曲目封面、进度与上下曲快捷控制"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        notificationManager.createNotificationChannel(channel)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSessionAndService()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (KonataMediaSessionDispatcher.liveService === this) {
            KonataMediaSessionDispatcher.liveService = null
        }
        try {
            mediaSession?.isActive = false
            mediaSession?.release()
        } catch (_: Exception) {}
        mediaSession = null
        try {
            notificationManager.cancel(NOTIFICATION_ID)
        } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
