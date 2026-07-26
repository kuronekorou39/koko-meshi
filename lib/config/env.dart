import 'package:flutter_dotenv/flutter_dotenv.dart';

/// .env から環境変数を取得
class Env {
  Env._();

  /// dotenv未ロード(テスト環境等)でも例外にせず空文字を返す
  static String _get(String key) =>
      dotenv.isInitialized ? (dotenv.env[key] ?? '') : '';

  /// 地図表示(Maps SDK)用。AndroidManifest にも同じ値を渡している。
  /// SDK がパッケージ名と署名を自動で送るので、Androidアプリ制限がかけられる
  static String get googleMapsApiKey => _get('GOOGLE_MAPS_API_KEY');

  /// 場所検索(Places API)用。
  ///
  /// 地図用と分けているのは、キーごとに使えるAPIを絞るため。片方が漏れても
  /// もう片方は使えない。未設定なら地図用のキーを使う(キーを分ける前の
  /// 設定でもそのまま動くように)。
  static String get googlePlacesApiKey {
    final key = _get('GOOGLE_PLACES_API_KEY');
    return key.isEmpty ? googleMapsApiKey : key;
  }
}
