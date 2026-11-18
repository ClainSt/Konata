import java.nio.charset.StandardCharsets
import java.util.Base64

plugins {
    id("com.android.application")
    // Flutter Gradle 插件必须在 Android 与 Kotlin Gradle 插件之后应用。
    id("dev.flutter.flutter-gradle-plugin")
}

/// 解析 Flutter 传入的 Base64 编码 `dart-defines`，提取并校验 `KONATA_LANE` 车道标识。
/// 默认空值或 `main` 返回空字符串以保持正式包名不变；其他合法标识返回小写车道名。
fun resolveKonataLane(): String {
    val rawDefines = project.findProperty("dart-defines")?.toString().orEmpty()
    if (rawDefines.isBlank()) return ""
    val decoder = Base64.getDecoder()
    var resolved = ""
    for (encodedItem in rawDefines.split(',')) {
        val trimmed = encodedItem.trim()
        if (trimmed.isEmpty()) continue
        val decoded = try {
            String(decoder.decode(trimmed), StandardCharsets.UTF_8)
        } catch (_: IllegalArgumentException) {
            continue
        }
        if (decoded.startsWith("KONATA_LANE=")) {
            resolved = decoded.substringAfter("KONATA_LANE=").trim().lowercase()
        }
    }
    if (resolved.isEmpty() || resolved == "main") return ""
    require(Regex("^[a-z][a-z0-9_]{0,31}$").matches(resolved)) {
        "KONATA_LANE 仅允许小写字母开头的字母、数字与下划线（长度不超过 32 位）：$resolved"
    }
    return resolved
}

val konataLane = resolveKonataLane()
val laneIdSuffix = if (konataLane.isEmpty()) "" else ".$konataLane"
val publicKeystore = File(System.getProperty("user.home"), ".ccplayer/ccplayer-release.p12")
val publicKeyPassword = providers.environmentVariable("CCPLAYER_SIGNING_PASSWORD")
val scraperPackage = providers.environmentVariable("KONATA_SCRAPER_PACKAGE").orNull == "1"
val isolatedReleaseValidation = scraperPackage ||
    providers.environmentVariable("KONATA_RELEASE_VALIDATION").orNull == "1"
val defaultAppLabel = when {
    scraperPackage && konataLane.isNotEmpty() -> "Konata Scraper Test (${konataLane.uppercase()})"
    scraperPackage -> "Konata Scraper Test"
    konataLane.isNotEmpty() -> "Konata (${konataLane.uppercase()})"
    else -> "Konata"
}
val debugAppLabel = if (konataLane.isNotEmpty()) {
    "Konata (${konataLane.uppercase()})"
} else {
    "Konata 测试"
}

android {
    namespace = "com.anime.konata"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.anime.konata"
        resValue("string", "konata_app_name", defaultAppLabel)
        manifestPlaceholders["konataLabel"] = "@string/konata_app_name"
        // 以下最小/目标 SDK 与版本号配置按 Flutter 宿主配置自动注入。
        // 相关构建参数遵循 Flutter Gradle 插件规范。
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("publicRelease") {
            storeFile = publicKeystore
            storePassword = publicKeyPassword.orNull
            keyAlias = "ccplayer"
            keyPassword = publicKeyPassword.orNull
        }
    }
    buildTypes {
        debug {
            val debugBaseSuffix =
                if (System.getenv("CCPLAYER_ISOLATED_VALIDATION") == "1") ".validation" else ".debug"
            applicationIdSuffix = "$laneIdSuffix$debugBaseSuffix"
            resValue("string", "konata_app_name", debugAppLabel)
        }
        getByName("profile") {
            applicationIdSuffix = "$laneIdSuffix.profile"
        }
        release {
            if (isolatedReleaseValidation) {
                val validationSuffix = if (scraperPackage) ".scrapervalidation" else ".acceptance"
                applicationIdSuffix = "$laneIdSuffix$validationSuffix"
                signingConfig = signingConfigs.getByName("debug")
            } else {
                if (laneIdSuffix.isNotEmpty()) {
                    applicationIdSuffix = laneIdSuffix
                }
                signingConfig = signingConfigs.getByName("publicRelease")
            }
        }
    }
}

// 缺少正式签名凭据时必须直接阻断构建，避免 AGP 意外产出未签名 APK。
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    doFirst {
        check(isolatedReleaseValidation || (publicKeystore.isFile && !publicKeyPassword.orNull.isNullOrBlank())) {
            "Public release signing requires ~/.ccplayer/ccplayer-release.p12 and CCPLAYER_SIGNING_PASSWORD."
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
