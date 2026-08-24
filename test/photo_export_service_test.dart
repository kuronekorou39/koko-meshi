import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:koko_meshi/services/photo_export_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// getTemporaryDirectory をテスト用の実ディレクトリに向ける
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final String dir;

  @override
  Future<String?> getTemporaryPath() async => dir;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('export_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  /// EXIFを持たないJPEG(編集で焼き直した写真に相当)
  String makeJpeg() {
    final image = img.Image(width: 8, height: 8);
    img.fill(image, color: img.ColorRgb8(120, 80, 40));
    final path = p.join(tmp.path, 'src.jpg');
    File(path).writeAsBytesSync(img.encodeJpg(image));
    return path;
  }

  final shotAt = DateTime(2026, 8, 15, 13, 25, 7);

  test('位置ありで書き出すと、GPSと日時がEXIFから読める', () async {
    final src = makeJpeg();
    final out = await PhotoExportService.prepareForExport(
      sourcePath: src,
      shotAt: shotAt,
      latitude: 35.515205,
      longitude: 139.687130,
      includeGps: true,
    );

    expect(out, isNot(src), reason: '一時ファイルが作られるはず');
    final exif = img.decodeJpgExif(File(out).readAsBytesSync())!;

    // 度分秒(RATIONAL×3)で入っていること。DOUBLE型だと他のリーダーが読めない
    final lat = exif.gpsIfd.data[0x0002]! as img.IfdValueRational;
    expect(lat.value.length, 3);
    final latDeg = lat.value[0].numerator / lat.value[0].denominator +
        lat.value[1].numerator / lat.value[1].denominator / 60 +
        lat.value[2].numerator / lat.value[2].denominator / 3600;
    expect(latDeg, closeTo(35.515205, 0.00001));

    final lng = exif.gpsIfd.data[0x0004]! as img.IfdValueRational;
    final lngDeg = lng.value[0].numerator / lng.value[0].denominator +
        lng.value[1].numerator / lng.value[1].denominator / 60 +
        lng.value[2].numerator / lng.value[2].denominator / 3600;
    expect(lngDeg, closeTo(139.687130, 0.00001));

    expect(exif.gpsIfd.data[0x0001].toString(), 'N');
    expect(exif.gpsIfd.data[0x0003].toString(), 'E');
    expect(exif.exifIfd.data[0x9003].toString(), '2026:08:15 13:25:07');
  });

  test('南半球・西経は参照方向が反転し、値は絶対値になる', () async {
    final src = makeJpeg();
    final out = await PhotoExportService.prepareForExport(
      sourcePath: src,
      shotAt: shotAt,
      latitude: -33.8688,
      longitude: -70.6693,
      includeGps: true,
    );

    final exif = img.decodeJpgExif(File(out).readAsBytesSync())!;
    expect(exif.gpsIfd.data[0x0001].toString(), 'S');
    expect(exif.gpsIfd.data[0x0003].toString(), 'W');
    final lat = exif.gpsIfd.data[0x0002]! as img.IfdValueRational;
    expect(lat.value[0].numerator / lat.value[0].denominator, 33);
  });

  test('位置なし設定なら、日時だけ入りGPSは空', () async {
    final src = makeJpeg();
    final out = await PhotoExportService.prepareForExport(
      sourcePath: src,
      shotAt: shotAt,
      latitude: 35.5,
      longitude: 139.6,
      includeGps: false,
    );

    final exif = img.decodeJpgExif(File(out).readAsBytesSync())!;
    expect(exif.gpsIfd.data, isEmpty);
    expect(exif.exifIfd.data[0x9003].toString(), '2026:08:15 13:25:07');
  });

  test('位置を持たない記録は、GPSを書かずに日時だけ入る', () async {
    final src = makeJpeg();
    final out = await PhotoExportService.prepareForExport(
      sourcePath: src,
      shotAt: shotAt,
      latitude: null,
      longitude: null,
      includeGps: true,
    );

    final exif = img.decodeJpgExif(File(out).readAsBytesSync())!;
    expect(exif.gpsIfd.data, isEmpty);
    expect(exif.exifIfd.data[0x9003].toString(), '2026:08:15 13:25:07');
  });

  test('JPEG以外は手を加えず元のパスを返す', () async {
    final image = img.Image(width: 4, height: 4);
    final path = p.join(tmp.path, 'src.png');
    File(path).writeAsBytesSync(img.encodePng(image));

    final out = await PhotoExportService.prepareForExport(
      sourcePath: path,
      shotAt: shotAt,
      latitude: 35.5,
      longitude: 139.6,
      includeGps: true,
    );
    expect(out, path);
  });

  test('cleanupは一時ファイルだけを消し、元画像は残す', () async {
    final src = makeJpeg();
    final out = await PhotoExportService.prepareForExport(
      sourcePath: src,
      shotAt: shotAt,
      latitude: 35.5,
      longitude: 139.6,
      includeGps: true,
    );

    await PhotoExportService.cleanup(out, src);
    expect(File(out).existsSync(), isFalse);
    expect(File(src).existsSync(), isTrue);

    // 元パスをそのまま渡したときは消さない
    await PhotoExportService.cleanup(src, src);
    expect(File(src).existsSync(), isTrue);
  });
}
