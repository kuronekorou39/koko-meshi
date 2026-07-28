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

        // 32bit(armeabi-v7a)も含める。flutter_gemma (LiteRT-LM/vision) は
        // arm64-v8a 版しか無いので32bit端末でAI解析はできないが、このアプリの
        // 本体は食事の記録で、AIはその補助でしかない。撮影・記録・マップは
        // 問題なく動くので、AI機能だけをアプリ側で落として使えるようにする
        // (対応判定は MainActivity.isOnDeviceAiSupported)。
        ndk {
            abiFilters.addAll(listOf("arm64-v8a", "armeabi-v7a"))
        }
    }

    // x86 系の .so を APK から除く。
    //
    // 上の abiFilters は自前ビルドのネイティブライブラリにしか効かず、
    // プラグインのAARに入っている .so は素通りするので、ここでも落とす。
    // x86_64 はエミュレータ用で実機には要らないのに、Flutter本体の .so が
    // 1ABIあたり20MB強あるため配布物には入れない。
    //
    // ビルド側でも --target-platform android-arm64,android-arm を指定する
    // (指定しないと Flutter 本体の .so が x86_64 の分まで入る)
    packaging {
        jniLibs {
            excludes += listOf("**/armeabi/**", "**/x86/**", "**/x86_64/**")
        }
    }

    buildTypes {
        debug {
            // 開発ビルドは別アプリとして入れる。実利用しているアプリを
            // 開発中のビルドで壊さないため(記録は端末内にしか無い)。
            //
            // 署名は既定のデバッグ鍵のまま。applicationId が違うので衝突せず、
            // リリース鍵を開発機やCIに置く必要も無い。
            //
            // 逆に統合すると、鍵が違うぶん上書きインストールができず
            // (INSTALL_FAILED_UPDATE_INCOMPATIBLE)、入れ替えのたびに
            // アンインストール=記録の消失になる
            applicationIdSuffix = ".dev"
            manifestPlaceholders["appLabel"] = "ココメシ(開発)"
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
