plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
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
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
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

// Missing credentials must fail even when AGP would otherwise produce an unsigned APK.
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
