import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';

class AuthService {
  AuthService._();

  static bool get isSupabaseConfigured =>
      Env.supabaseUrl.isNotEmpty && Env.supabaseAnonKey.isNotEmpty;

  static SupabaseClient? get _client {
    if (!isSupabaseConfigured) return null;
    return Supabase.instance.client;
  }

  static User? get currentUser => _client?.auth.currentUser;
  static bool get isLoggedIn => currentUser != null;

  static Stream<AuthState> get authStateChanges {
    if (_client == null) return const Stream.empty();
    return _client!.auth.onAuthStateChange;
  }

  /// メールアドレスでサインアップ
  static Future<AuthResponse> signUp({
    required String email,
    required String password,
    String? displayName,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Supabaseが設定されていません');

    final response = await client.auth.signUp(
      email: email,
      password: password,
      data: displayName != null ? {'display_name': displayName} : null,
    );

    // プロフィールテーブルにも保存
    if (response.user != null) {
      await _upsertProfile(response.user!, displayName);
    }

    return response;
  }

  /// メールアドレスでログイン
  static Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Supabaseが設定されていません');

    return client.auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  /// Googleアカウントでログイン
  /// ユーザーがキャンセルした場合はnullを返す
  static Future<AuthResponse?> signInWithGoogle() async {
    final client = _client;
    if (client == null) throw Exception('Supabaseが設定されていません');

    final webClientId = Env.googleOAuthClientId;
    if (webClientId.isEmpty) {
      throw Exception('GOOGLE_OAUTH_CLIENT_ID が設定されていません');
    }

    final gsi = GoogleSignIn.instance;
    await gsi.initialize(serverClientId: webClientId);

    final GoogleSignInAccount account;
    try {
      account = await gsi.authenticate();
    } on GoogleSignInException catch (e) {
      debugPrint('[Auth] Google Sign-In exception: $e');
      // ユーザーキャンセルはnullを返す
      return null;
    }

    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw Exception('Google IDトークンの取得に失敗しました');
    }

    final response = await client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
    );

    if (response.user != null) {
      await _upsertProfile(
        response.user!,
        account.displayName,
      );
    }

    return response;
  }

  /// ログアウト
  static Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    await _client?.auth.signOut();
  }

  /// プロフィール取得
  static Future<Map<String, dynamic>?> getProfile() async {
    final user = currentUser;
    if (user == null || _client == null) return null;

    try {
      final data = await _client!
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();
      return data;
    } catch (e) {
      debugPrint('[Auth] Failed to get profile: $e');
      return null;
    }
  }

  /// 表示名を更新
  static Future<void> updateDisplayName(String name) async {
    final user = currentUser;
    if (user == null || _client == null) return;

    await _client!.from('profiles').upsert({
      'id': user.id,
      'display_name': name,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  /// プロフィールをupsert
  static Future<void> _upsertProfile(User user, String? displayName) async {
    if (_client == null) return;
    try {
      await _client!.from('profiles').upsert({
        'id': user.id,
        'display_name': displayName ?? user.email?.split('@').first ?? '',
        'email': user.email,
        'updated_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('[Auth] Failed to upsert profile: $e');
    }
  }
}
