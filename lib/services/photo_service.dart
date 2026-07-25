import 'dart:io';
import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../config/constants.dart';

/// EXIF から取得したメタデータ
class PhotoExifData {
  final DateTime? dateTime;
  final double? latitude;
  final double? longitude;

  const PhotoExifData({this.dateTime, this.latitude, this.longitude});

  bool get hasLocation => latitude != null && longitude != null;
  bool get hasDateTime => dateTime != null;
}

class PhotoService {
  static final _picker = ImagePicker();
  static const _uuid = Uuid();

  /// カメラで撮影（オリジナル画質をそのまま保持）
  static Future<XFile?> takePhoto() async {
    return _picker.pickImage(
      source: ImageSource.camera,
    );
  }

  /// ライブラリから選択（複数可）
  static Future<List<XFile>> pickPhotos() async {
    return _picker.pickMultiImage();
  }

  /// 写真をアプリのローカルディレクトリに保存し、パスを返す
  static Future<String> saveToLocal(XFile file) async {
    final dir = await _getPhotoDir();
    final ext = p.extension(file.path).isEmpty ? '.jpg' : p.extension(file.path);
    final fileName = '${_uuid.v4()}$ext';
    final savedPath = p.join(dir.path, fileName);
    await File(file.path).copy(savedPath);
    return savedPath;
  }

  /// ファイルパスからアプリのローカルディレクトリにコピーして保存
  static Future<String> saveToLocalFromPath(String filePath) async {
    final dir = await _getPhotoDir();
    final ext = p.extension(filePath).isEmpty ? '.jpg' : p.extension(filePath);
    final fileName = '${_uuid.v4()}$ext';
    final savedPath = p.join(dir.path, fileName);
    await File(filePath).copy(savedPath);
    return savedPath;
  }

  /// ローカルのオリジナル写真を削除（サムネは残す）
  static Future<void> deleteOriginal(String localPath) async {
    try {
      final file = File(localPath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('[Photo] Deleted original: $localPath');
      }
    } catch (e) {
      debugPrint('[Photo] Failed to delete original: $e');
    }
  }

  /// サムネイルを生成してローカルに保存し、パスを返す
  static Future<String> generateThumbnail(String originalPath) async {
    final thumbDir = await _getThumbnailDir();
    final fileName = 'thumb_${p.basename(originalPath)}';
    final thumbPath = p.join(thumbDir.path, fileName);

    // 別isolateでリサイズ
    await compute(_resizeImage, _ResizeParams(
      inputPath: originalPath,
      outputPath: thumbPath,
      maxWidth: AppConstants.thumbnailMaxWidth,
    ));

    return thumbPath;
  }

  /// 画像ファイルからEXIFメタデータを読み取る
  static Future<PhotoExifData> readExifData(String filePath) async {
    try {
      final bytes = await File(filePath).readAsBytes();
      final tags = await readExifFromBytes(bytes);
      if (tags.isEmpty) return const PhotoExifData();

      return PhotoExifData(
        dateTime: _parseExifDateTime(tags),
        latitude: _parseExifGpsCoord(tags, 'GPS GPSLatitude', 'GPS GPSLatitudeRef'),
        longitude: _parseExifGpsCoord(tags, 'GPS GPSLongitude', 'GPS GPSLongitudeRef'),
      );
    } catch (e) {
      debugPrint('[Photo] EXIF read error: $e');
      return const PhotoExifData();
    }
  }

  static DateTime? _parseExifDateTime(Map<String, IfdTag> tags) {
    final dateTag = tags['EXIF DateTimeOriginal'] ??
        tags['EXIF DateTimeDigitized'] ??
        tags['Image DateTime'];
    if (dateTag == null) return null;

    try {
      // EXIF format: "2024:03:15 14:30:00"
      final str = dateTag.printable;
      final parts = str.split(' ');
      if (parts.length != 2) return null;
      final datePart = parts[0].replaceAll(':', '-');
      return DateTime.tryParse('${datePart}T${parts[1]}');
    } catch (_) {
      return null;
    }
  }

  static double? _parseExifGpsCoord(
    Map<String, IfdTag> tags,
    String coordKey,
    String refKey,
  ) {
    final coord = tags[coordKey];
    final ref = tags[refKey];
    if (coord == null) return null;

    try {
      final values = coord.values as IfdRatios;
      final degrees = values.ratios[0].numerator / values.ratios[0].denominator;
      final minutes = values.ratios[1].numerator / values.ratios[1].denominator;
      final seconds = values.ratios[2].numerator / values.ratios[2].denominator;
      var result = degrees + minutes / 60.0 + seconds / 3600.0;

      final refStr = ref?.printable ?? '';
      if (refStr == 'S' || refStr == 'W') {
        result = -result;
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  static Future<Directory> _getPhotoDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final photoDir = Directory(p.join(appDir.path, 'photos'));
    if (!await photoDir.exists()) {
      await photoDir.create(recursive: true);
    }
    return photoDir;
  }

  static Future<Directory> _getThumbnailDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final thumbDir = Directory(p.join(appDir.path, 'thumbnails'));
    if (!await thumbDir.exists()) {
      await thumbDir.create(recursive: true);
    }
    return thumbDir;
  }

  static Future<void> _resizeImage(_ResizeParams params) async {
    final bytes = await File(params.inputPath).readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return;

    final resized = img.copyResize(image, width: params.maxWidth);
    final encoded = img.encodeJpg(resized, quality: 80);
    await File(params.outputPath).writeAsBytes(encoded);
  }
}

class _ResizeParams {
  final String inputPath;
  final String outputPath;
  final int maxWidth;

  const _ResizeParams({
    required this.inputPath,
    required this.outputPath,
    required this.maxWidth,
  });
}
