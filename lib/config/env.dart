import 'package:flutter_dotenv/flutter_dotenv.dart';

/// .env から環境変数を取得
class Env {
  Env._();

  static String get googleMapsApiKey =>
      dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '';

  static String get claudeApiKey =>
      dotenv.env['CLAUDE_API_KEY'] ?? '';

  static String get geminiApiKey =>
      dotenv.env['GEMINI_API_KEY'] ?? '';

  /// AI解析に使用するプロバイダー ('gemini' or 'claude')
  static String get aiProvider =>
      dotenv.env['AI_PROVIDER'] ?? 'gemini';
}
