import 'package:flutter_dotenv/flutter_dotenv.dart';

/// .env から環境変数を取得
class Env {
  Env._();

  /// dotenv未ロード(テスト環境等)でも例外にせず空文字を返す
  static String _get(String key) =>
      dotenv.isInitialized ? (dotenv.env[key] ?? '') : '';

  static String get googleMapsApiKey => _get('GOOGLE_MAPS_API_KEY');

  static String get googleOAuthClientId => _get('GOOGLE_OAUTH_CLIENT_ID');

  static String get supabaseUrl {
    final url = _get('SUPABASE_URL');
    return url.isNotEmpty ? url : _get('NEXT_PUBLIC_SUPABASE_URL');
  }

  static String get supabaseAnonKey {
    final key = _get('SUPABASE_ANON_KEY');
    return key.isNotEmpty
        ? key
        : _get('NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY');
  }
}
