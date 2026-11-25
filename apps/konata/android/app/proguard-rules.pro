# Konata v3 Android R8 代码压缩与混淆保留规则

# 保留注解显式声明的类与成员
-keep @androidx.annotation.Keep class * { *; }
-keepclassmembers class * {
    @androidx.annotation.Keep <fields>;
    @androidx.annotation.Keep <methods>;
}

# 保留所有原生 JNI 入口方法签名
-keepclasseswithmembernames class * {
    native <methods>;
}

# 保留 Konata 原生宿主活动、视频底层表面、前台媒体服务与文档提供器
-keep class com.anime.konata.** { *; }

# 保留 Flutter 引擎嵌入层与自动注册插件类
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }

# 保留 media_kit JNI 回调及 AndroidUnderlaySurfaceHost 反射访问的原生桥接类
-keep class com.alexmercerind.mediakitandroidhelper.** { *; }
-keep class com.alexmercerind.media_kit_libs_android_video.** { *; }

# 保留 flutter_secure_storage 与底层加密库反射入口
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class com.google.crypto.tink.** { *; }

# 保留文件选择器与系统桥接插件
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
