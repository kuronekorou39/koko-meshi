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
