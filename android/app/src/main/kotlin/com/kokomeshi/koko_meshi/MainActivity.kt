package com.kokomeshi.koko_meshi

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.zip.ZipFile

class MainActivity : FlutterActivity() {

    private var pendingMediaLocationResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isOnDeviceAiSupported" -> result.success(isOnDeviceAiSupported())
                    "requestMediaLocationPermission" -> requestMediaLocationPermission(result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * ACCESS_MEDIA_LOCATION の実行時リクエスト。
     *
     * Android 10以降、この権限が無いとライブラリの写真はEXIFの位置情報が
     * 削られて渡される(image_picker_android のvendorパッチ側と対になる)。
     * 拒否されても写真の選択自体はできるので、結果は真偽で返すだけにして
     * 呼び出し側では失敗として扱わない。
     */
    private fun requestMediaLocationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(true) // 削られる仕組み自体が無いので原本のまま読める
            return
        }
        if (checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingMediaLocationResult != null) {
            result.success(false) // リクエスト中の多重呼び出し
            return
        }
        pendingMediaLocationResult = result
        requestPermissions(
            arrayOf(Manifest.permission.ACCESS_MEDIA_LOCATION),
            REQUEST_MEDIA_LOCATION,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_MEDIA_LOCATION) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingMediaLocationResult?.success(granted)
            pendingMediaLocationResult = null
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
        private const val REQUEST_MEDIA_LOCATION = 3901
    }
}
