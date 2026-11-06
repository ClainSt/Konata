# 优化前体积与性能基线

2026-11-06，基于 main 的 2f743e7 加当时全部未提交内容，版本 1.0.0+1。先后用 Flutter Release --analyze-size 构建 windows x64 和 android-arm64（--split-per-abi）。ZIP 统一用 .NET ZipFile.CreateFromDirectory；大小单位为字节。原有交付 ZIP 的压缩参数不同，不参与差值。

## Windows x64

包 38,436,219；成员展开合计 90,265,385；SHA-256 为 349a7bee7803c383e3b1acc7fc5bfc1c9c954dc7940bfc6999c01a735b694187。

| 文件或分组 | 展开 | 压缩数据 |
|---|---:|---:|
| libmpv-2.dll | 29,764,622 | 12,877,042 |
| flutter_windows.dll | 21,284,864 | 9,114,526 |
| data/app.so | 12,698,512 | 4,975,249 |
| libGLESv2.dll | 7,414,088 | 2,882,440 |
| d3dcompiler_47.dll | 4,891,080 | 2,186,677 |
| vk_swiftshader.dll | 4,808,008 | 1,952,382 |
| data/flutter_assets/packages/hugeicons/lib/fonts/hugeicons-stroke-rounded.ttf | 2,132,640 | 1,045,931 |
| sqlite3.dll | 1,709,056 | 961,459 |
| data/flutter_assets/fonts/MaterialIcons-Regular.otf | 1,645,184 | 563,595 |
| vulkan-1.dll | 872,776 | 362,280 |
| data/icudtl.dat | 862,304 | 464,843 |
| libEGL.dll | 472,904 | 223,208 |
| data/flutter_assets/packages/media_kit/assets/web/hls1.4.10.js | 374,690 | 112,070 |
| data/flutter_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf | 257,628 | 117,482 |
| zlib.dll | 203,264 | 78,082 |
| CCPlayer.exe | 181,248 | 146,881 |
| media_kit_video_plugin.dll | 155,136 | 67,116 |
| window_manager_plugin.dll | 130,560 | 57,950 |
| screen_retriever_windows_plugin.dll | 119,296 | 51,715 |
| data/flutter_assets/NOTICES.Z | 116,514 | 115,336 |
| url_launcher_windows_plugin.dll | 98,304 | 41,361 |
| data/flutter_assets/shaders/ink_sparkle.frag | 21,856 | 5,345 |
| data/flutter_assets/shaders/stretch_effect.frag | 17,624 | 3,542 |
| media_kit_libs_windows_video_plugin.dll | 12,800 | 5,576 |
| data/flutter_assets/assets/brand/tmdb-logo.png | 7,549 | 7,540 |
| data/flutter_assets/assets/brand/github-white.png | 6,223 | 6,228 |
| data/flutter_assets/assets/brand/github-black.png | 5,437 | 5,442 |
| data/flutter_assets/AssetManifest.bin | 558 | 181 |
| data/flutter_assets/FontManifest.json | 337 | 150 |
| native_assets.json | 192 | 149 |
| data/flutter_assets/NativeAssetsManifest.json | 131 | 111 |

## Android arm64-v8a

包 39,941,733；成员展开合计 42,039,414；SHA-256 为 55085db02d08ae41e2d448432a1472c9b8ec5c5d74a3371eef0e35cae12dc77d。

| 文件或分组 | 展开 | 压缩数据 |
|---|---:|---:|
| lib/arm64-v8a/libmpv.so | 12,369,680 | 12,369,680 |
| lib/arm64-v8a/libflutter.so | 11,581,856 | 11,581,856 |
| lib/arm64-v8a/libapp.so | 11,207,568 | 11,207,568 |
| assets/flutter_assets/packages/hugeicons/lib/fonts/hugeicons-stroke-rounded.ttf | 2,132,640 | 1,039,673 |
| lib/arm64-v8a/libsqlite3.so | 1,732,360 | 1,732,360 |
| 其他 Android 资源、DEX、清单和签名 | 1,668,167 | 1,000,057 |
| lib/arm64-v8a/libmediakitandroidhelper.so | 386,696 | 386,696 |
| assets/flutter_assets/packages/media_kit/assets/web/hls1.4.10.js | 374,690 | 110,796 |
| assets/flutter_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf | 257,628 | 115,944 |
| lib/arm64-v8a/libdartjni.so | 131,400 | 131,400 |
| assets/flutter_assets/NOTICES.Z | 116,514 | 115,244 |
| assets/flutter_assets/shaders/ink_sparkle.frag | 21,856 | 5,275 |
| assets/flutter_assets/shaders/stretch_effect.frag | 17,624 | 3,499 |
| assets/flutter_assets/fonts/MaterialIcons-Regular.otf | 12,712 | 7,867 |
| lib/arm64-v8a/libdatastore_shared_counter.so | 7,784 | 7,784 |
| assets/flutter_assets/assets/brand/tmdb-logo.png | 7,549 | 7,549 |
| assets/flutter_assets/assets/brand/github-white.png | 6,223 | 6,223 |
| assets/flutter_assets/assets/brand/github-black.png | 5,437 | 5,437 |
| assets/flutter_assets/AssetManifest.bin | 558 | 181 |
| assets/flutter_assets/FontManifest.json | 337 | 150 |
| assets/flutter_assets/NativeAssetsManifest.json | 135 | 111 |

Windows 解压文件逻辑长度等于 ZIP 成员展开合计。Android 2407FRK8EC 安装正式基线 APK 后，通过 StorageStats 服务查询得到代码 42,882,560、数据 401,408（含缓存 204,800），合计 43,283,968 字节。APK 的展开合计与设备实际分配采用不同口径。

## 资源归属

libmpv 已集成 FFmpeg，发布物没有可单独计量的 FFmpeg 文件。Windows EGL/GLES、D3D 编译器、Vulkan 与 SwiftShader 属渲染路径；逐文件哈希未发现完全重复的文件。两端均未发现打包的常规中日英文字体或字幕字体集合。MaterialIcons 用于应用控件，另外两套图标字体无源码消费者。两个 GitHub 图像对应明暗主题，TMDB 图像用于署名。ICU 是 Flutter 文本运行数据。样片及附件字体仅在开发目录。

## 启动与内存

Windows Release 依次启动三个新进程。WaitForInputIdle 为 310、209、236 ms；再等待 3 秒后工作集分别为 112,766,976、112,832,512、161,861,632 字节。输入队列就绪早于或晚于 Flutter 首帧均有可能；后两次为文件缓存可能已热的新进程，未清空系统文件缓存。

Android 正式包首次启动 am start -W 报 COLD，TotalTime 697 ms。返回桌面后恢复任务 WaitTime 49 ms，系统将其标为 UNKNOWN，非再次冷启动。首次进入后约 3 秒 dumpsys meminfo 的 PSS 200,113 KiB、RSS 365,093 KiB。均为单台设备观测。

此前同工作区的 Windows/真机 4K 正式页长测 RSS 峰值分别为 831,295,488 / 944,148,480 字节，属于历史 Debug 证据。优化前未取得按片源、解码后端配对的持续负载、GPU、功耗及播放结束内存，不能据此量化性能收益。缓存策略与验收范围见另外三份报告。
