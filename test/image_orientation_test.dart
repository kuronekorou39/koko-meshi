import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:koko_meshi/services/gemma_ondevice_service.dart';

/// スマホの写真は縦持ちでも画素は横向きで保存され、向きはEXIFの Orientation に
/// しか書かれていない(手元のPixelの写真は Orientation=6)。解析に渡す画像で
/// これを焼き込み忘れると、モデルには90°倒れた写真が渡る。表示側は回転を
/// 適用するので画面では正しく見えてしまい、気づけない。
///
/// 実際にこの取り違えで料理名が大きく外れていたので、テストで固定する。

/// 横長(w>h)の画像に Orientation を付けたJPEGを作る
Uint8List jpegWithOrientation(int orientation, {int w = 400, int h = 200}) {
  final image = img.Image(width: w, height: h);
  // 左半分と右半分を塗り分ける。回転すれば上下の分割に変わるので、
  // 縦横の入れ替えだけでなく向きの判定にも使える
  img.fill(image, color: img.ColorRgb8(200, 40, 40));
  img.fillRect(image,
      x1: 0, y1: 0, x2: w ~/ 2, y2: h - 1, color: img.ColorRgb8(40, 40, 200));
  image.exif.imageIfd.orientation = orientation;
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  group('解析に渡す画像', () {
    test('Orientation=6(90°回転が必要)なら縦横が入れ替わる', () {
      final out = GemmaOnDeviceService.resizeForModel(jpegWithOrientation(6));
      final decoded = img.decodeImage(out)!;
      expect(decoded.width, 200, reason: '横400が縦になる');
      expect(decoded.height, 400);
    });

    test('Orientation=8(270°回転が必要)でも縦横が入れ替わる', () {
      final out = GemmaOnDeviceService.resizeForModel(jpegWithOrientation(8));
      final decoded = img.decodeImage(out)!;
      expect(decoded.width, 200);
      expect(decoded.height, 400);
    });

    test('Orientation=1(そのまま)は縦横を変えない', () {
      final out = GemmaOnDeviceService.resizeForModel(jpegWithOrientation(1));
      final decoded = img.decodeImage(out)!;
      expect(decoded.width, 400);
      expect(decoded.height, 200);
    });

    test('Orientation=3(180°回転)は縦横は変わらない', () {
      final out = GemmaOnDeviceService.resizeForModel(jpegWithOrientation(3));
      final decoded = img.decodeImage(out)!;
      expect(decoded.width, 400);
      expect(decoded.height, 200);
    });

    test('180°回転では中身が実際に反転する(寸法だけでは分からないため)', () {
      // 元は左が青。180°回すと左が赤になる
      final out = GemmaOnDeviceService.resizeForModel(jpegWithOrientation(3));
      final decoded = img.decodeImage(out)!;
      final left = decoded.getPixel(10, decoded.height ~/ 2);
      expect(left.r, greaterThan(left.b), reason: '左が赤へ入れ替わっている');
    });

    test('長辺は768pxに収める', () {
      final out = GemmaOnDeviceService.resizeForModel(
        jpegWithOrientation(1, w: 4000, h: 3000),
      );
      final decoded = img.decodeImage(out)!;
      expect(decoded.width, 768);
      expect(decoded.height, 576);
    });

    test('回転を要する大きな写真も、回転してから768pxに収める', () {
      // 4000x3000 + Orientation=6 → 3000x4000 → 576x768
      final out = GemmaOnDeviceService.resizeForModel(
        jpegWithOrientation(6, w: 4000, h: 3000),
      );
      final decoded = img.decodeImage(out)!;
      expect(decoded.width, 576);
      expect(decoded.height, 768);
    });

    test('768px以下なら拡大しない', () {
      final out = GemmaOnDeviceService.resizeForModel(
        jpegWithOrientation(1, w: 300, h: 200),
      );
      final decoded = img.decodeImage(out)!;
      expect(decoded.width, 300);
      expect(decoded.height, 200);
    });

    test('画像として読めないバイト列はそのまま返す(落とさない)', () {
      final garbage = Uint8List.fromList([1, 2, 3, 4, 5]);
      expect(GemmaOnDeviceService.resizeForModel(garbage), garbage);
    });
  });
}
