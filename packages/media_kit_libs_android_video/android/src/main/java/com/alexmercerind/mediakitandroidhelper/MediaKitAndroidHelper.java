// media_kit Android 原生辅助桥接模块（MIT 许可）。
package com.alexmercerind.mediakitandroidhelper;

import android.net.Uri;
import android.content.Context;
import androidx.annotation.Keep;

import java.io.FileNotFoundException;

@Keep
public class MediaKitAndroidHelper {
    static {
        System.loadLibrary("mediakitandroidhelper");
    }

    // 保存应用级 Context 引用，供 openFileDescriptor 解析 content:// 句柄。
    private static Context applicationContext = null;

    public static native long newGlobalObjectRef(Object obj);

    public static native void deleteGlobalObjectRef(long ref);

    public static native String copyAssetToFilesDir(String assetName);

    private static native void setApplicationContextNative(Context context);

    public static void setApplicationContextJava(Context context) {
        applicationContext = context;
        setApplicationContextNative(context);
    }

    public static native int openFileDescriptorNative(String uri);

    public static int openFileDescriptorJava(String uri) {
        try {
            final Uri object = Uri.parse(uri);
            return applicationContext.getContentResolver().openFileDescriptor(object, "r").detachFd();
        } catch (Throwable e) {
            e.printStackTrace();
            return -1;
        }
    }
}
