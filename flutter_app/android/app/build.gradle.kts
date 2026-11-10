plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.march.dragnet_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.march.dragnet_app"
        // 2026-11-11 M6-A：targetSdk 29 与冷启动 Dart isolate flaky 失败强相关
        // （探针 36 全过 / 本壳 29 三连挂，证据见 PROGRESS M6-A）——升 36 对齐模板。
        // 注意：34+ 需 VpnService 前台服务合规（FOREGROUND_SERVICE 权限与
        // foregroundServiceType），启动拦截链路验证时一并补齐。
        minSdk = 24
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    sourceSets {
        // 内核 .so 由 scripts/build-android.sh 产出（仓库根 build/android/<abi>/）
        getByName("main") {
            jniLibs.srcDir(file("../../../build/android"))
        }
    }

    packaging {
        jniLibs {
            // M6-A：AGP 9.1 下 abiFilters 未过滤引擎 AAR 的 armeabi-v7a
            // libflutter（33MB 纯浪费，本工程无 v7a Go .so，v7a 设备本就不可用）
            excludes += setOf("lib/armeabi-v7a/**")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
