import 'package:flutter_dotenv/flutter_dotenv.dart';

/// .env から環境変数を取得
class Env {
  Env._();

  /// dotenv未ロード(テスト環境等)でも例外にせず空文字を返す
  static String _get(String key) =>
      dotenv.isInitialized ? (dotenv.env[key] ?? '') : '';

  static String get googleMapsApiKey => _get('GOOGLE_MAPS_API_KEY');
}
