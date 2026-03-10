import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// クラウド写真のローカルキャッシュ管理
class PhotoCacheService {
  PhotoCacheService._();

  /// 写真を表示するためのパスを取得
  /// ローカルにあればそのパス、なければクラウドからダウンロードしてキャッシュ
  static Future<String?> getDisplayPath({
    required String? localPath,
    required String? thumbnailPath,
    required String? originalUrl,
    bool fullQuality = false,
  }) async {
    // 1. ローカルのオリジナルが存在すればそれを返す
    if (localPath != null && File(localPath).existsSync()) {
      return localPath;
    }

    // 2. サムネイルが存在し、フル画質不要ならサムネを返す
    if (!fullQuality && thumbnailPath != null && File(thumbnailPath).existsSync()) {
      return thumbnailPath;
    }

    // 3. クラウドURLがあればダウンロードしてキャッシュ
    if (originalUrl != null && originalUrl.isNotEmpty) {
      return _downloadAndCache(originalUrl);
    }

    // 4. サムネイルをフォールバック
    if (thumbnailPath != null && File(thumbnailPath).existsSync()) {
      return thumbnailPath;
    }

    return null;
  }

  /// URLからダウンロードしてキャッシュディレクトリに保存
  static Future<String?> _downloadAndCache(String url) async {
    try {
      final cacheDir = await _getCacheDir();
      final fileName = url.hashCode.toRadixString(36);
      final cachePath = p.join(cacheDir.path, fileName);

      // キャッシュ済みならそのまま返す
      final cacheFile = File(cachePath);
      if (cacheFile.existsSync()) {
        return cachePath;
      }

      // ダウンロード
      debugPrint('[PhotoCache] Downloading: $url');
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await cacheFile.writeAsBytes(response.bodyBytes);
        return cachePath;
      }

      debugPrint('[PhotoCache] Download failed: ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[PhotoCache] Error: $e');
      return null;
    }
  }

  static Future<Directory> _getCacheDir() async {
    final appDir = await getApplicationCacheDirectory();
    final cacheDir = Directory(p.join(appDir.path, 'photo_cache'));
    if (!cacheDir.existsSync()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }
}
