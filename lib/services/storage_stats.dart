import 'dart:io';

import '../database/local_database.dart';
import 'photo_service.dart';

/// 端末に溜まっている記録の量。設定画面で見せる。
///
/// 全部が端末の中にあるアプリなので、どれだけ溜まっているかは本人にしか
/// 分からない。バックアップの大きさの見当にもなる。
class StorageStats {
  const StorageStats({
    required this.mealCount,
    required this.photoCount,
    required this.photoBytes,
  });

  final int mealCount;
  final int photoCount;

  /// 写真とサムネイルの合計(AIモデルは含めない)
  final int photoBytes;

  static Future<StorageStats> load() async {
    final counts = await LocalDatabase.getRecordCounts();

    var bytes = 0;
    for (final dir in await PhotoService.storageDirectories()) {
      await for (final entity in dir.list()) {
        if (entity is File) bytes += (await entity.stat()).size;
      }
    }

    return StorageStats(
      mealCount: counts.meals,
      photoCount: counts.photos,
      photoBytes: bytes,
    );
  }
}

/// バイト数を「850 MB」「3.2 GB」のように読める形にする。
/// 桁が小さいうちは小数を出す(「1 GB」と「1.9 GB」は別物なので)。
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text =
      unit == 0 || value >= 10 ? value.round().toString() : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
