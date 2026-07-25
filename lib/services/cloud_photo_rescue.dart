import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/local_database.dart';
import '../models/meal_photo.dart';
import 'photo_service.dart';

/// クラウド写真取り込みの結果。
class CloudRescueResult {
  const CloudRescueResult({
    required this.rescued,
    required this.failed,
    required this.alreadyLocal,
  });

  /// 取り込めた枚数
  final int rescued;

  /// クラウドにあるが取得できなかった枚数
  final int failed;

  /// もともとローカルに実体があった枚数(対象外)
  final int alreadyLocal;
}

/// クラウド(旧同期先)にしか実体が無い写真を、この端末へ取り込む。
///
/// アカウント/同期機能の廃止に伴い、クラウドURL(originalUrl)経由でしか
/// 表示できていなかった過去写真を、ローカルに落として自己完結させる。
/// URLが生きているうちに1回実行すればよい。
class CloudPhotoRescue {
  CloudPhotoRescue._();

  /// まだ取り込めていない(クラウドURLはあるがローカル実体が無い)写真の数。
  /// 0なら取り込み機能をUIに出す必要がない。
  static Future<int> pendingCount() async {
    final all = await LocalDatabase.getAllMealPhotos();
    var count = 0;
    for (final photo in all) {
      if (_hasLocalFile(photo)) continue;
      if ((photo.originalUrl ?? '').isNotEmpty) count++;
    }
    return count;
  }

  static Future<CloudRescueResult> rescueAll({
    void Function(int done, int total)? onProgress,
  }) async {
    final all = await LocalDatabase.getAllMealPhotos();

    final targets = <MealPhoto>[];
    var alreadyLocal = 0;
    for (final photo in all) {
      if (_hasLocalFile(photo)) {
        alreadyLocal++;
        continue;
      }
      if ((photo.originalUrl ?? '').isNotEmpty) targets.add(photo);
    }

    var rescued = 0;
    var failed = 0;
    for (var i = 0; i < targets.length; i++) {
      try {
        if (await _rescueOne(targets[i])) {
          rescued++;
        } else {
          failed++;
        }
      } catch (e) {
        debugPrint('[Rescue] ${targets[i].id} failed: $e');
        failed++;
      }
      onProgress?.call(i + 1, targets.length);
    }

    return CloudRescueResult(
      rescued: rescued,
      failed: failed,
      alreadyLocal: alreadyLocal,
    );
  }

  static bool _hasLocalFile(MealPhoto photo) {
    if (File(photo.localPath).existsSync()) return true;
    final orig = photo.originalLocalPath;
    return orig != null && File(orig).existsSync();
  }

  static Future<bool> _rescueOne(MealPhoto photo) async {
    final resp = await http.get(Uri.parse(photo.originalUrl!));
    if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return false;

    final tmpDir = await getTemporaryDirectory();
    final ext = _extFor(photo.originalUrl!, resp.headers['content-type']);
    final tmpPath = p.join(tmpDir.path, 'rescue_${photo.id}$ext');
    await File(tmpPath).writeAsBytes(resp.bodyBytes);

    final localPath = await PhotoService.saveToLocalFromPath(tmpPath);
    try {
      await File(tmpPath).delete();
    } catch (_) {}
    final thumb = await PhotoService.generateThumbnail(localPath);

    await LocalDatabase.updateMealPhoto(photo.copyWith(
      localPath: localPath,
      originalLocalPath: localPath,
      thumbnailUrl: thumb,
    ));
    return true;
  }

  static String _extFor(String url, String? contentType) {
    final urlExt = p.extension(Uri.parse(url).path);
    if (urlExt.isNotEmpty && urlExt.length <= 5) return urlExt;
    final ct = contentType ?? '';
    if (ct.contains('png')) return '.png';
    if (ct.contains('webp')) return '.webp';
    return '.jpg';
  }
}
