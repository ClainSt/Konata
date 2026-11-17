plugins {
    id("com.android.application")
    // Flutter Gradle 插件必须在 Android 与 Kotlin Gradle 插件之后应用。
    id("dev.flutter.flutter-gradle-plugin")
}

val publicKeystore = File(System.getProperty("user.home"), ".ccplayer/ccplayer-release.p12")
val publicKeyPassword = providers.environmentVariable("CCPLAYER_SIGNING_PASSWORD")
val scraperPackage = providers.environmentVariable("KONATA_SCRAPER_PACKAGE").orNull == "1"
val isolatedReleaseValidation = scraperPackage ||
    providers.environmentVariable("KONATA_RELEASE_VALIDATION").orNull == "1"

android {
    namespace = "com.anime.konata"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.anime.konata"
        manifestPlaceholders["konataLabel"] = if (scraperPackage) "Konata Scraper Test" else "Konata"
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
            applicationIdSuffix =
                if (System.getenv("CCPLAYER_ISOLATED_VALIDATION") == "1") ".validation" else ".debug"
        }
        getByName("profile") { applicationIdSuffix = ".profile" }
        release {
            if (isolatedReleaseValidation) {
                applicationIdSuffix = if (scraperPackage) ".scrapervalidation" else ".acceptance"
                signingConfig = signingConfigs.getByName("debug")
            } else {
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
