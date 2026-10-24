plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.dragnet.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.dragnet.app"
        minSdk = 24
        // targetSdk 29：PoC 免 foregroundServiceType/通知合规要求；正式端（M4）再升
        targetSdk = 29
        versionCode = 1
        versionName = "0.1-poc"
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    sourceSets {
        getByName("main") {
            // 内核 .so 由 scripts/build-android.sh 产出
            jniLibs.srcDir(file("../../build/android"))
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

// 零第三方依赖：内核 .so 已由 Go 侧构建
dependencies {}
