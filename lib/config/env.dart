import 'package:flutter_dotenv/flutter_dotenv.dart';

/// .env から環境変数を取得
class Env {
  Env._();

  static String get googleMapsApiKey =>
      dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '';

  static String get googleOAuthClientId =>
      dotenv.env['GOOGLE_OAUTH_CLIENT_ID'] ?? '';

  static String get supabaseUrl =>
      dotenv.env['SUPABASE_URL'] ??
      dotenv.env['NEXT_PUBLIC_SUPABASE_URL'] ?? '';

  static String get supabaseAnonKey =>
      dotenv.env['SUPABASE_ANON_KEY'] ??
      dotenv.env['NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY'] ?? '';
}
