import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'services/app_settings_service.dart';

/// 同梱フォントは SIL Open Font License 1.1。再配布にあたりライセンス本文を
/// アプリのライセンス画面(showLicensePage)に出す。
void _registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final font in AppFont.values) {
      final family = font.family;
      if (family == null) continue;
      final text =
          await rootBundle.loadString('assets/fonts/$family/OFL.txt');
      yield LicenseEntryWithLineBreaks([family], text);
    }
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await initializeDateFormatting('ja');

  await AppSettings.init();
  _registerFontLicenses();

  runApp(
    const ProviderScope(
      child: KokoMeshiApp(),
    ),
  );
}
