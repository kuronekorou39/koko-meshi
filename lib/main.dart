import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config/env.dart';
import 'services/app_settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await initializeDateFormatting('ja');

  await AppSettings.init();

  // Supabase初期化（環境変数が設定されている場合のみ）
  if (Env.supabaseUrl.isNotEmpty && Env.supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      anonKey: Env.supabaseAnonKey,
    );

    // 未認証の場合は匿名認証を自動実行（Edge Function利用に必要）
    if (Supabase.instance.client.auth.currentUser == null) {
      try {
        await Supabase.instance.client.auth.signInAnonymously();
      } catch (e) {
        debugPrint('[Auth] Anonymous sign-in failed: $e');
      }
    }
  }

  runApp(
    const ProviderScope(
      child: KokoMeshiApp(),
    ),
  );
}
