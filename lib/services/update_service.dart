import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 新しいバージョンが出ていないか調べる。
///
/// ストア配布ではないので、更新の通知役がいない。利用者は新版が出たことを
/// 知る手段が無いままになる。GitHub Releases の最新タグと自分のバージョンを
/// 比べて、アプリ側から知らせる。
class UpdateService {
  UpdateService._();

  /// 最新リリースの取得元。配布場所を移すときはここを変える
  static const _latestReleaseApi =
      'https://api.github.com/repos/kuronekorou39/koko-meshi/releases/latest';

  /// 調べる間隔。起動のたびに叩くとGitHubのレート制限(未認証60回/時)に
  /// 近づくうえ、更新はそう頻繁には出ない
  static const _checkInterval = Duration(hours: 12);

  static const _timeout = Duration(seconds: 8);

  static const _keyLastChecked = 'update_last_checked';
  static const _keyLatestVersion = 'update_latest_version';
  static const _keyLatestUrl = 'update_latest_url';
  static const _keyDismissed = 'update_dismissed_version';

  /// 前回の結果を含めた、いま出せる更新情報。
  /// 通信せずに読めるので、画面の描画から呼んでよい。
  static Future<AppUpdate?> cached() async {
    final prefs = await SharedPreferences.getInstance();
    final latest = prefs.getString(_keyLatestVersion);
    final url = prefs.getString(_keyLatestUrl);
    if (latest == null || url == null) return null;

    final current = (await PackageInfo.fromPlatform()).version;
    if (!isNewer(latest, current)) return null;

    return AppUpdate(
      version: latest,
      url: url,
      dismissed: prefs.getString(_keyDismissed) == latest,
    );
  }

  /// 必要なら問い合わせて、結果を保存する。
  /// [force] で間隔を無視する(設定画面から手動で確認するとき)。
  static Future<AppUpdate?> check({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();

    if (!force) {
      final last = prefs.getInt(_keyLastChecked);
      if (last != null) {
        final elapsed = DateTime.now().millisecondsSinceEpoch - last;
        if (elapsed < _checkInterval.inMilliseconds) return cached();
      }
    }

    try {
      final response = await http
          .get(
            Uri.parse(_latestReleaseApi),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(_timeout);

      // 失敗しても前回の結果は消さない。通信できないことは更新が無いことでは
      // ないので、黙って前の状態のままにしておく
      if (response.statusCode != 200) {
        debugPrint('[Update] ${response.statusCode}: ${response.body}');
        return cached();
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = data['tag_name'] as String?;
      final url = data['html_url'] as String?;
      if (tag == null || url == null) return cached();

      await prefs.setInt(
        _keyLastChecked,
        DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setString(_keyLatestVersion, normalize(tag));
      await prefs.setString(_keyLatestUrl, url);
      return cached();
    } on TimeoutException {
      return cached();
    } on SocketException {
      return cached();
    } catch (e) {
      debugPrint('[Update] failed: $e');
      return cached();
    }
  }

  /// このバージョンの知らせを閉じる。次の版が出るまで出さない
  static Future<void> dismiss(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDismissed, version);
  }

  /// タグ名からバージョン部分を取り出す。`v0.9.0` → `0.9.0`
  static String normalize(String tag) {
    var s = tag.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    return s;
  }

  /// [candidate] が [current] より新しいか。
  ///
  /// `0.9.0` と `0.10.0` を文字列で比べると 0.9.0 のほうが大きくなるので、
  /// 数値として桁ごとに比べる。数字で始まらない部分(`1.0.0-beta` など)は
  /// 比較の対象にしない
  static bool isNewer(String candidate, String current) {
    final a = _parts(candidate);
    final b = _parts(current);
    for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  static List<int> _parts(String version) => normalize(version)
      .split('.')
      .map((s) => int.tryParse(RegExp(r'^\d+').stringMatch(s) ?? '') ?? 0)
      .toList();
}

/// 出ている新しいバージョン。
class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.url,
    required this.dismissed,
  });

  final String version;

  /// リリースページ。ここからAPKを落としてもらう
  final String url;

  /// 利用者がこのバージョンの知らせを閉じたか
  final bool dismissed;
}
