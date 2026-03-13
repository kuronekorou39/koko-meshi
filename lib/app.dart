import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import 'screens/auth/login_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/capture/capture_screen.dart';
import 'screens/detail/meal_detail_screen.dart';
import 'screens/settings/settings_screen.dart';

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/capture',
      builder: (context, state) => CaptureScreen(
        initialPhotos: state.extra as List<XFile>?,
      ),
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
    GoRoute(
      path: '/login',
      builder: (context, state) => const LoginScreen(),
    ),
  ],
);

class KokoMeshiApp extends StatelessWidget {
  const KokoMeshiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'ココメシ',
      theme: ThemeData(
        colorSchemeSeed: Colors.orange,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.orange,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
