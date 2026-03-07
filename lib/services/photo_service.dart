import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../config/constants.dart';

class PhotoService {
  static final _picker = ImagePicker();
  static const _uuid = Uuid();

  /// カメラで撮影
  static Future<XFile?> takePhoto() async {
    return _picker.pickImage(source: ImageSource.camera);
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
