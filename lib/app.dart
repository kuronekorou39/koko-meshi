import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import 'providers/app_settings_providers.dart';
import 'screens/home/home_screen.dart';
import 'screens/capture/capture_screen.dart';
import 'screens/detail/meal_detail_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'theme/app_theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();

final _router = GoRouter(
  navigatorKey: navigatorKey,
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/capture',
      builder: (context, state) {
        final extra = state.extra;
        if (extra is Map<String, dynamic>) {
          return CaptureScreen(
            initialPhotos: extra['photos'] as List<XFile>?,
            fromLibrary: extra['fromLibrary'] as bool? ?? false,
          );
        }
        // 後方互換
        return CaptureScreen(
          initialPhotos: extra as List<XFile>?,
        );
      },
    ),
    GoRoute(
      path: '/meal/:id',
      builder: (context, state) => MealDetailScreen(
        mealLogId: state.pathParameters['id']!,
      ),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
  ],
);

class KokoMeshiApp extends ConsumerWidget {
  const KokoMeshiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fontFamily = ref.watch(appFontProvider).family;
    return MaterialApp.router(
      title: 'ココメシ',
      theme: AppTheme.light(fontFamily),
      darkTheme: AppTheme.dark(fontFamily),
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
