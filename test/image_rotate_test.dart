import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 撮影後の回転で使っている copyRotate が、確認画面の RotatedBox と
/// 同じ向きに回るかを確かめる。ここがずれると「見たのと違う向きで保存される」
/// という一番たちの悪い壊れ方をする。
void main() {
  /// 左上だけ白い、向きの分かる画像
  img.Image makeMarked() {
    final image = img.Image(width: 4, height: 2);
    img.fill(image, color: img.ColorRgb8(0, 0, 0));
    image.setPixel(0, 0, img.ColorRgb8(255, 255, 255));
    return image;
  }

  bool isWhite(img.Image im, int x, int y) => im.getPixel(x, y).r > 200;

  test('90度回すと、左上の印が右上へ移り、縦横が入れ替わる', () {
    final rotated = img.copyRotate(makeMarked(), angle: 90);
    expect(rotated.width, 2);
    expect(rotated.height, 4);
    // 時計回りなので (0,0) は右上へ
    expect(isWhite(rotated, rotated.width - 1, 0), isTrue);
  });

  test('180度で対角へ移る', () {
    final rotated = img.copyRotate(makeMarked(), angle: 180);
    expect(rotated.width, 4);
    expect(rotated.height, 2);
    expect(isWhite(rotated, 3, 1), isTrue);
  });

  test('270度で左下へ移る', () {
    final rotated = img.copyRotate(makeMarked(), angle: 270);
    expect(rotated.width, 2);
    expect(rotated.height, 4);
    expect(isWhite(rotated, 0, rotated.height - 1), isTrue);
  });

  test('360度で元に戻る', () {
    final rotated = img.copyRotate(makeMarked(), angle: 360);
    expect(rotated.width, 4);
    expect(rotated.height, 2);
    expect(isWhite(rotated, 0, 0), isTrue);
  });

  test('90度を4回で元に戻る(操作を繰り返しても崩れない)', () {
    var image = makeMarked();
    for (var i = 0; i < 4; i++) {
      image = img.copyRotate(image, angle: 90);
    }
    expect(image.width, 4);
    expect(image.height, 2);
    expect(isWhite(image, 0, 0), isTrue);
  });
}
