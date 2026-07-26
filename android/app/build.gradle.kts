plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// .env からAPIキーを読み込む
val envFile = rootProject.file("../.env")
val envMap = mutableMapOf<String, String>()
if (envFile.exists()) {
    envFile.readLines().forEach { line ->
        val trimmed = line.trim()
        if (trimmed.isNotEmpty() && !trimmed.startsWith("#") && trimmed.contains("=")) {
            val (key, value) = trimmed.split("=", limit = 2)
            envMap[key.trim()] = value.trim()
        }
    }
}

// key.properties 読み込み（リリース署名用）
val keyPropertiesFile = rootProject.file("key.properties")
val keyMap = mutableMapOf<String, String>()
if (keyPropertiesFile.exists()) {
    keyPropertiesFile.readLines().forEach { line ->
        val trimmed = line.trim()
        if (trimmed.isNotEmpty() && !trimmed.startsWith("#") && trimmed.contains("=")) {
            val (key, value) = trimmed.split("=", limit = 2)
            keyMap[key.trim()] = value.trim()
        }
    }
}

android {
    namespace = "com.kokomeshi.koko_meshi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    signingConfigs {
        create("release") {
            storeFile = file(keyMap["storeFile"] ?: "kokomeshi-release.keystore")
            storePassword = keyMap["storePassword"] ?: ""
            keyAlias = keyMap["keyAlias"] ?: "kokomeshi"
            keyPassword = keyMap["keyPassword"] ?: ""
        }
    }

    defaultConfig {
        applicationId = "com.kokomeshi.koko_meshi"
        // flutter_gemma (LiteRT-LM) は minSdk 24 以上が必要
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // .env から Google Maps APIキーを注入
        manifestPlaceholders["GOOGLE_MAPS_API_KEY"] = envMap["GOOGLE_MAPS_API_KEY"] ?: ""
        manifestPlaceholders["appLabel"] = "ココメシ"

        // flutter_gemma (LiteRT-LM/vision) は arm64-v8a のみ対応
        ndk {
            abiFilters.add("arm64-v8a")
        }
    }

    buildTypes {
        debug {
            // リリース版と同じ applicationId・同じ署名にして、開発ビルドを
            // そのまま上書きインストールできるようにする（記録が消えない）。
            //
            // 以前は .poc サフィックスで別アプリにしていた。バックアップと
            // 復元(BackupService)が入って、まっさらから戻せるようになったので統合した。
            //
            // 署名まで揃えないと、同じ applicationId で鍵だけ違う状態になり
            // INSTALL_FAILED_UPDATE_INCOMPATIBLE でアンインストールが必要になる。
            // key.properties が無い環境（クリーンなクローン・CI）では既定の
            // デバッグ署名に落ちる
            signingConfig = if (keyPropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        release {
            signingConfig = if (keyPropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}
