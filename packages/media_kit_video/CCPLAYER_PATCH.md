# CCPlayer local patch

Source: media_kit_video 2.0.1 from pub.dev, https://github.com/media-kit/media-kit.
Upstream MIT license is retained in LICENSE. Only runtime sources and package metadata are vendored; examples and generated build outputs are omitted.

Changes to `lib/media_kit_video_controls/src/controls/material.dart`:

- Add optional `seekDurationLabel` formatter to MaterialVideoControlsThemeData, its constructor and copyWith.
- Both double-tap seek indicators use MaterialSeekDurationLabel with the formatter. The fallback remains the upstream English text.
- Keep duration text at 12px and single line; let it occupy its intrinsic width with horizontal scrolling under a narrow constraint.

Gesture regions, repeated-tap accumulation, 400ms submission timers and seeking callbacks remain upstream code. CCPlayer supplies ARB text in both normal and fullscreen themes. No pub cache files are modified.

The current unverified player extension also adds optional seekBarOverlayBuilder to desktop/mobile theme constructors and copyWith, invoked inside the seekbar's unclipped Stack. It supplies duration, hover/drag fraction and available width for chapter markers and preview. Existing pointer/seek handlers are retained. Final regression and native preview validation are pending; see docs/PLAYER_FEATURES.md in the application root.

Regression: `test/seek_indicator_test.dart` covers English, Hans, Hant, 10/20/120 second labels, copyWith retention, narrow width and 2x text scaling. Native device gesture/fullscreen validation remains pending.

## 2026-11-06 decode and selected Windows library

- Explicit decode policy preserves the emulator software safeguard, supports software/automatic choices, and reads custom initial hwdec before controller initialization. Rejected options fall back to software; arbitrary unknown backend names accepted by mpv rely on mpv runtime fallback.
- Windows Dart controller passes NativeLibrary.path; video_output resolves its seven libmpv calls from that already-loaded module, per output. This prevents passing an enhanced-library handle to the default linked DLL. Deferred context disposal captures its own free function. No texture format or ANGLE configuration change.
- Regression: default Windows original matrix 14 passed; enhanced matrix initially crashed and passed 14 after same-module binding. New final default rerun and Android outcomes are recorded in application docs/BDRIP-PLAYBACK-VALIDATION.md.

Material 与 MaterialDesktop 的进度条主题增加 seekWhileDragging（默认 true）。CCPlayer 对 WebDAV 关闭它，拖动时仍更新滑块与预览，松手按最终坐标提交一次精确定位。回归入口为 integration_test/webdav_network_probe.dart 的 DAV_LATENCY 用例。

2026-11-07：两端均先绘制进度条和缓冲色带，再绘制忽略触摸的章节层，最后绘制拖动手柄。章节零点、非零章节和片尾以轨道实际尺寸居中，回归见 test/player_features_test.dart。Android 控件在确认单击时切换可见性；滑动继承已有的水平定位和右侧音量手势。取消手势时丢弃待定位的偏移，下次纵向调整音量先读取播放器当前音量。若上游支持相同的覆盖层顺序和手势语义，可移除对应补丁。

Windows 的暂停画面在输出尺寸改变时也请求重新分配和渲染；验证见 docs/verification/release-windows-paused-fullscreen-20261107.jsonl。升级前以暂停的同一 PTS 再次比较窗口及全屏字幕画布。
