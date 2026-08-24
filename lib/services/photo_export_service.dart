import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// カメラロールへ書き出す写真にメタデータを戻す。
///
/// 記録の日時と場所はDBには入っているが、写真ファイル側には残っていない:
/// - 編集した写真は焼き込みで再エンコードするためEXIFが丸ごと落ちる
/// - アプリ内撮影の写真は、カメラ側がGPSを書かないので元から位置が無い
///
/// 書き出したJPEGは端末の外に出ていく(共有・別アプリでの取り込み)ので、
/// 位置を入れるかどうかは呼び出し側の設定で決める。
class PhotoExportService {
  PhotoExportService._();

  /// 書き出し用の一時ファイルを作り、そのパスを返す。
  ///
  /// EXIFを足す必要が無い/足せない場合は [sourcePath] をそのまま返す。
  /// 返り値が [sourcePath] と異なるときは一時ファイルなので、使い終わったら
  /// [cleanup] で消すこと。
  static Future<String> prepareForExport({
    required String sourcePath,
    required DateTime shotAt,
    double? latitude,
    double? longitude,
    required bool includeGps,
  }) async {
    final withGps = includeGps && latitude != null && longitude != null;
    // JPEG以外(HEIC/PNG)はEXIFセグメントを差し替えられない。撮った写真は
    // JPEGなので、ここに来るのは取り込んだ画像くらい
    if (!_isJpeg(sourcePath)) return sourcePath;

    try {
      final bytes = await File(sourcePath).readAsBytes();
      final exif = img.decodeJpgExif(bytes) ?? img.ExifData();

      _setDateTime(exif, shotAt);
      if (withGps) {
        _setGps(exif, latitude, longitude, shotAt);
      } else {
        // 設定がオフなら、元から入っていた位置も落として書き出す
        exif.gpsIfd.data.clear();
      }

      final updated = img.injectJpgExif(bytes, exif);
      if (updated == null) {
        debugPrint('[Export] EXIFを書き込めませんでした。元のまま書き出します');
        return sourcePath;
      }

      // カメラロールにはこのファイル名で並ぶので、撮った日時が分かる名前にする
      final dir = await getTemporaryDirectory();
      final stamp = '${shotAt.year}${_two(shotAt.month)}${_two(shotAt.day)}'
          '_${_two(shotAt.hour)}${_two(shotAt.minute)}${_two(shotAt.second)}';
      final outPath = p.join(dir.path, 'kokomeshi_$stamp.jpg');
      await File(outPath).writeAsBytes(updated);
      return outPath;
    } catch (e) {
      // 書き出し自体は成功させたいので、失敗しても元ファイルで続行する
      debugPrint('[Export] EXIF処理に失敗: $e');
      return sourcePath;
    }
  }

  /// [prepareForExport] が作った一時ファイルを消す。
  static Future<void> cleanup(String preparedPath, String sourcePath) async {
    if (preparedPath == sourcePath) return;
    try {
      await File(preparedPath).delete();
    } catch (_) {
      // 消せなくても実害は無い(一時ディレクトリはOSが整理する)
    }
  }

  static bool _isJpeg(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.jpg' || ext == '.jpeg';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static void _setDateTime(img.ExifData exif, DateTime shotAt) {
    final stamp = '${shotAt.year}:${_two(shotAt.month)}:${_two(shotAt.day)} '
        '${_two(shotAt.hour)}:${_two(shotAt.minute)}:${_two(shotAt.second)}';
    exif.exifIfd.data[0x9003] = img.IfdValueAscii(stamp); // DateTimeOriginal
    exif.exifIfd.data[0x9004] = img.IfdValueAscii(stamp); // DateTimeDigitized
    exif.imageIfd.data[0x0132] = img.IfdValueAscii(stamp); // DateTime
  }

  /// GPSを度分秒(RATIONAL×3)で書く。
  ///
  /// imageパッケージの `setGpsLocation` は度をDOUBLE型で入れるが、これは
  /// EXIFの規格から外れていて、写真アプリや他のEXIFリーダーが読めない。
  static void _setGps(
    img.ExifData exif,
    double latitude,
    double longitude,
    DateTime shotAt,
  ) {
    final gps = exif.gpsIfd;
    gps.data[0x0001] = img.IfdValueAscii(latitude < 0 ? 'S' : 'N');
    gps.data[0x0002] = _dms(latitude.abs());
    gps.data[0x0003] = img.IfdValueAscii(longitude < 0 ? 'W' : 'E');
    gps.data[0x0004] = _dms(longitude.abs());

    // 撮影時刻のUTC表記。写真アプリが地図に出すときの手がかりになる
    final utc = shotAt.toUtc();
    gps.data[0x0007] = _rationals([
      [utc.hour, 1],
      [utc.minute, 1],
      [utc.second, 1],
    ]);
    gps.data[0x001D] =
        img.IfdValueAscii('${utc.year}:${_two(utc.month)}:${_two(utc.day)}');
  }

  /// 十進の度を、度・分・秒の有理数3つに割る
  static img.IfdValueRational _dms(double deg) {
    final d = deg.floor();
    final minFull = (deg - d) * 60;
    final m = minFull.floor();
    // 秒は1/10000秒まで持たせる(≒0.3mm相当。丸めても実用上は影響しない)
    final s = ((minFull - m) * 60 * 10000).round();
    return _rationals([
      [d, 1],
      [m, 1],
      [s, 10000],
    ]);
  }

  /// [分子, 分母] の並びから RATIONAL の値を作る。
  ///
  /// imageパッケージは Rational 型を公開していないので、単値の
  /// IfdValueRational を経由して取り出す。
  static img.IfdValueRational _rationals(List<List<int>> pairs) =>
      img.IfdValueRational.list([
        for (final pair in pairs) img.IfdValueRational(pair[0], pair[1]).value[0],
      ]);
}
