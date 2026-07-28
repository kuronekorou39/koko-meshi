package com.kokomeshi.koko_meshi

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.zip.ZipFile

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isOnDeviceAiSupported" -> result.success(isOnDeviceAiSupported())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 端末内AI(LiteRT-LM)がこの端末で動くか。
     *
     * LiteRT-LM は arm64-v8a 版しか配布されていないので、32bit端末には
     * そもそも .so が入らない。APKには両ABIを入れて32bit端末でもアプリ自体は
     * 使えるようにしてあるため、AI機能だけをここで落とす。
     *
     * 判定はAPKの中身を直接見る。理由が2つある:
     * - nativeLibraryDir のファイル存在では見られない。リリースビルドは
     *   extractNativeLibs=false で .so を展開せずAPKから直接ロードするため、
     *   あのディレクトリは空になる(arm64端末まで非対応と判定してしまう)
     * - ABI名(SUPPORTED_ABIS)だけでも足りない。64bit端末は32bitのABIも
     *   「対応」と申告するので、arm64のライブラリを含まないAPKを入れられた
     *   場合に、無いライブラリを在ると判断してしまう
     *
     * 判定できなかった場合は true(従来どおり動かす)に倒す。ここで false に
     * するとAIを黙って殺すことになるので、実際のロード失敗に任せるほうが安全。
     *
     * 注意: flutter_gemma_litertlm 側でライブラリ名が変わったらここも直すこと。
     */
    private fun isOnDeviceAiSupported(): Boolean {
        // 端末が優先するABI。Androidが実際に採用するのもこれ
        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: return true
        val entry = "lib/$abi/$LITERT_LM_LIB"

        // base.apk と、あれば分割APK(AABにした場合)を順に見る
        val apks = buildList {
            add(applicationInfo.sourceDir)
            applicationInfo.splitSourceDirs?.let { addAll(it) }
        }
        return try {
            apks.any { path ->
                ZipFile(path).use { it.getEntry(entry) != null }
            }
        } catch (e: Exception) {
            true
        }
    }

    companion object {
        private const val CHANNEL = "com.kokomeshi.koko_meshi/device"
        private const val LITERT_LM_LIB = "libLiteRtLm.so"
    }
}
