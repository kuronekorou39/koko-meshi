import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_settings_service.dart';

/// 現在の本文フォント。設定画面で変えるとテーマが作り直されてアプリ全体に反映される。
/// 永続化は [AppSettings.setFont] が担当し、この Provider は表示用の現在値を持つ。
final appFontProvider = StateProvider<AppFont>((ref) => AppSettings.font);
