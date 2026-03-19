import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/auth_service.dart';
import '../services/sync_service.dart';

/// 現在の認証状態を監視
final authStateProvider = StreamProvider<User?>((ref) {
  if (!AuthService.isSupabaseConfigured) {
    return const Stream.empty();
  }

  // 初期値として現在のユーザーを流す
  final controller = StreamController<User?>();
  controller.add(AuthService.currentUser);

  final subscription = AuthService.authStateChanges.listen((state) {
    controller.add(state.session?.user);
  });

  ref.onDispose(() {
    subscription.cancel();
    controller.close();
  });

  return controller.stream;
});

/// ログイン中かどうか（匿名ユーザーは除外）
final isLoggedInProvider = Provider<bool>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return false;
  // 匿名ユーザーはログインしていないとみなす
  if (user.isAnonymous) return false;
  if (user.email == null || user.email!.isEmpty) return false;
  return true;
});

/// ユーザープロフィール
final userProfileProvider = FutureProvider<Map<String, dynamic>?>((ref) {
  ref.watch(authStateProvider);
  return AuthService.getProfile();
});

/// 手動同期のトリガー
final syncProvider = FutureProvider<SyncResult>((ref) async {
  final isLoggedIn = ref.watch(isLoggedInProvider);
  if (!isLoggedIn) return SyncResult.notLoggedIn();
  return SyncService.syncAll();
});
