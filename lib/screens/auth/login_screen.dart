import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/auth_service.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  bool _isLogin = true;
  bool _loading = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (_isLogin) {
        await AuthService.signIn(
          email: _emailCtrl.text.trim(),
          password: _passwordCtrl.text,
        );
      } else {
        await AuthService.signUp(
          email: _emailCtrl.text.trim(),
          password: _passwordCtrl.text,
          displayName: _nameCtrl.text.trim().isEmpty
              ? null
              : _nameCtrl.text.trim(),
        );
      }

      if (mounted) context.pop();
    } catch (e) {
      final message = _parseError(e.toString());
      setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await AuthService.signInWithGoogle();
      if (response == null) {
        // ユーザーがキャンセルした場合 → 何もしない
      } else if (mounted) {
        context.pop();
      }
    } catch (e, st) {
      debugPrint('[Auth] Google Sign-In error: $e');
      debugPrint('[Auth] Stack trace: $st');
      setState(() => _error = _parseError(e.toString()));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _parseError(String error) {
    if (error.contains('Invalid login credentials')) {
      return 'メールアドレスまたはパスワードが間違っています';
    }
    if (error.contains('User already registered')) {
      return 'このメールアドレスは既に登録されています';
    }
    if (error.contains('Password should be at least')) {
      return 'パスワードは6文字以上で入力してください';
    }
    if (error.contains('Unable to validate email')) {
      return 'メールアドレスの形式が正しくありません';
    }
    if (error.contains('Email not confirmed')) {
      return 'メールアドレスの確認が必要です。メールを確認してください';
    }
    if (error.contains('AuthRetryableFetchException') ||
        error.contains('SocketException') ||
        error.contains('ClientException')) {
      return 'ネットワークエラーです。接続を確認してもう一度お試しください';
    }
    if (error.contains('500') || error.contains('Internal Server Error')) {
      return 'サーバーエラーが発生しました。しばらく後にお試しください';
    }
    if (error.contains('Email rate limit exceeded')) {
      return '送信制限に達しました。しばらく後にお試しください';
    }
    if (error.contains('Signup is disabled')) {
      return '現在新規登録は無効になっています';
    }
    return 'エラーが発生しました。もう一度お試しください';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isLogin ? 'ログイン' : 'アカウント作成'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // アイコン
                Icon(
                  Icons.restaurant_menu,
                  size: 64,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 8),
                Text(
                  'ココメシ',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _isLogin
                      ? 'ログインしてクラウドに同期'
                      : 'アカウントを作成して始めましょう',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[600]),
                ),
                const SizedBox(height: 32),

                // エラー表示
                if (_error != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: Colors.red[700], size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(color: Colors.red[700], fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),

                // 表示名（サインアップのみ）
                if (!_isLogin) ...[
                  TextFormField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '表示名',
                      hintText: '例: たろう',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),
                ],

                // メールアドレス
                TextFormField(
                  controller: _emailCtrl,
                  decoration: const InputDecoration(
                    labelText: 'メールアドレス',
                    hintText: 'example@mail.com',
                    prefixIcon: Icon(Icons.email_outlined),
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'メールアドレスを入力してください';
                    }
                    if (!value.contains('@') || !value.contains('.')) {
                      return '正しいメールアドレスを入力してください';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // パスワード
                TextFormField(
                  controller: _passwordCtrl,
                  decoration: InputDecoration(
                    labelText: 'パスワード',
                    hintText: '6文字以上',
                    prefixIcon: const Icon(Icons.lock_outlined),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                      onPressed: () {
                        setState(() => _obscurePassword = !_obscurePassword);
                      },
                    ),
                  ),
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'パスワードを入力してください';
                    }
                    if (value.length < 6) {
                      return 'パスワードは6文字以上で入力してください';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 24),

                // 送信ボタン
                FilledButton(
                  onPressed: _loading ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _isLogin ? 'ログイン' : 'アカウント作成',
                          style: const TextStyle(fontSize: 16),
                        ),
                ),
                const SizedBox(height: 20),

                // 区切り線
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text('または', style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 20),

                // Googleログイン
                OutlinedButton.icon(
                  onPressed: _loading ? null : _signInWithGoogle,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    side: BorderSide(color: Colors.grey[300]!),
                  ),
                  icon: Image.asset(
                    'assets/google_logo.png',
                    width: 20,
                    height: 20,
                    errorBuilder: (_, _, _) => const Icon(Icons.g_mobiledata, size: 24),
                  ),
                  label: const Text(
                    'Googleアカウントで続ける',
                    style: TextStyle(fontSize: 15),
                  ),
                ),
                const SizedBox(height: 16),

                // 切り替え
                TextButton(
                  onPressed: _loading
                      ? null
                      : () {
                          setState(() {
                            _isLogin = !_isLogin;
                            _error = null;
                          });
                        },
                  child: Text(
                    _isLogin
                        ? 'アカウントをお持ちでない方はこちら'
                        : '既にアカウントをお持ちの方はこちら',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
