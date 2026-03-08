import 'package:flutter_dotenv/flutter_dotenv.dart';

/// .env から環境変数を取得
class Env {
  Env._();

  static String get googleMapsApiKey =>
      dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '';
}
