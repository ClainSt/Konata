// media_kit Android 原生视频运行时加载插件（MIT 许可）。
package com.alexmercerind.media_kit_libs_android_video;

import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Objects;
import java.io.InputStream;
import java.io.BufferedReader;
import java.util.regex.Pattern;
import java.io.InputStreamReader;
import java.util.zip.GZIPInputStream;

import android.util.Log;
import androidx.annotation.NonNull;
import android.content.res.AssetManager;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

import com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper;

/// Android 视频播放原生库加载入口。
public class MediaKitLibsAndroidVideoPlugin implements FlutterPlugin {
    static {
        // 部分旧版设备上仅靠 Dart 侧 DynamicLibrary.open 可能失败，需预先触发 System.loadLibrary。
        try {
            System.loadLibrary("mpv");
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
        Log.i("media_kit", "package:media_kit_libs_android_video attached.");
        try {
            // 缓存应用上下文，供 MediaKitAndroidHelper 后续读取打包资源与内容描述符。
            MediaKitAndroidHelper.setApplicationContextJava(flutterPluginBinding.getApplicationContext());
            Log.i("media_kit", "Saved application context.");
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        Log.i("media_kit", "package:media_kit_libs_android_video detached.");
    }
}
