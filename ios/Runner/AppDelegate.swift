import Flutter
import GoogleMaps
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    provideGoogleMapsApiKey()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerDeviceChannel(engineBridge.pluginRegistry)
  }

  /// 端末の素性(機種識別子・物理メモリ)をFlutter側へ渡す。
  ///
  /// 端末内AIが動くかどうかは実質メモリ量で決まる(Gemma 4 E2B は2.4GBあり、
  /// iOSはアプリ1つが使えるメモリを端末のRAMから割った上限で切る)。ところが
  /// 実機から回収できるのはアプリ内の「AIの記録」だけで、そこに端末の情報が
  /// 無いため「モデルのロードに失敗」の理由が端末なのか実装なのか分けられ
  /// なかった。Androidの同名チャネルは32bit判定に使っており、こちらは
  /// deviceSummary だけを実装する。
  private func registerDeviceChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "KokoMeshiDevice") else { return }
    let channel = FlutterMethodChannel(
      name: "com.kokomeshi.koko_meshi/device",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "deviceSummary":
        result(Self.deviceSummary())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 例: `iPhone14,5 / RAM 4.0GB`。
  /// 機種名(iPhone 13 等)への変換表は持たない。識別子のままでも調べれば
  /// 分かるし、表は端末が出るたび古くなる
  private static func deviceSummary() -> String {
    var info = utsname()
    uname(&info)
    let machine = withUnsafeBytes(of: &info.machine) { raw in
      String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
    let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    return String(format: "%@ / RAM %.1fGB", machine, ramGB)
  }

  /// 地図SDKにAPIキーを渡す。
  ///
  /// キーは .env から Env.xcconfig 経由で Info.plist に埋まっている(生成は Podfile)。
  /// Androidは AndroidManifest の meta-data でSDKが勝手に読むが、iOSは自分で
  /// 呼ぶ必要があり、しかも最初の地図を作るより前でなければならない。
  ///
  /// キーが無くても呼ばずに進む。地図だけが出ない状態になるが、記録や一覧は
  /// そのまま使えるので、ここで落とすより起動させたほうが良い。
  private func provideGoogleMapsApiKey() {
    let key = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_MAPS_API_KEY") as? String
    guard let key, !key.isEmpty else {
      NSLog("[Maps] APIキーが未設定のため地図は表示されません(.env の GOOGLE_MAPS_API_KEY を確認)")
      return
    }
    GMSServices.provideAPIKey(key)
  }
}
