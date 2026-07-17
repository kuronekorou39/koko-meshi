import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:koko_meshi/screens/editor/photo_edit_core.dart';

void main() {
  group('PhotoEditParams JSON', () {
    test('JSON往復で全フィールドが一致する', () {
      const params = PhotoEditParams(
        rotationDeg: 17.3,
        cropRect: Rect.fromLTWH(10.5, 20.25, 800, 600),
        srcW: 1200,
        srcH: 900,
        filter: PhotoEditFilter(
          preset: 'レトロ',
          brightness: -5,
          contrast: 10,
          saturation: -30,
          temperature: 35,
          vignette: 30,
        ),
      );

      // 文字列エンコードまで通して型が壊れないことを確認
      final encoded = jsonEncode(params.toJson());
      final restored =
          PhotoEditParams.fromJson(jsonDecode(encoded) as Map<String, dynamic>);

      expect(restored, params);
    });

    test('version欠損(旧v1)はnull', () {
      // 旧v1形式(キャンバス比率ベース)にはversionキーがない
      final v1Json = <String, dynamic>{
        'rotation': 0.5,
        'imageScale': 1.2,
        'offsetXRatio': 0.1,
        'offsetYRatio': 0.0,
        'cropLeftRatio': 0.0,
        'cropTopRatio': 0.0,
        'cropWidthRatio': 1.0,
        'cropHeightRatio': 1.0,
      };
      expect(PhotoEditParams.fromJson(v1Json), isNull);
    });

    test('version 1/3/文字列はnull', () {
      Map<String, dynamic> base(Object? version) => {
            'version': version,
            'rotationDeg': 0.0,
            'crop': {'x': 0.0, 'y': 0.0, 'w': 100.0, 'h': 100.0},
            'srcW': 100,
            'srcH': 100,
            'filter': const PhotoEditFilter().toJson(),
          };
      expect(PhotoEditParams.fromJson(base(1)), isNull);
      expect(PhotoEditParams.fromJson(base(3)), isNull);
      expect(PhotoEditParams.fromJson(base('2')), isNull);
      expect(PhotoEditParams.fromJson(base(null)), isNull);
    });

    test('version 2でも必須フィールドが壊れていればnull', () {
      expect(
        PhotoEditParams.fromJson({'version': 2, 'crop': '壊れたデータ'}),
        isNull,
      );
      expect(
        PhotoEditParams.fromJson({
          'version': 2,
          'crop': {'x': 0, 'y': 0, 'w': 100, 'h': 100},
          // srcW/srcH欠損
        }),
        isNull,
      );
    });
  });

  group('isIdentity', () {
    test('回転0・全域crop・フィルターなしは編集なし', () {
      final params = PhotoEditParams.identity(srcW: 1200, srcH: 900);
      expect(params.isIdentity, isTrue);
      // 360度回転も恒等
      expect(params.copyWith(rotationDeg: 360).isIdentity, isTrue);
    });

    test('回転・crop・フィルターのいずれかがあれば編集あり', () {
      final identity = PhotoEditParams.identity(srcW: 1200, srcH: 900);
      expect(identity.copyWith(rotationDeg: 90).isIdentity, isFalse);
      expect(
        identity
            .copyWith(cropRect: const Rect.fromLTWH(10, 10, 1000, 800))
            .isIdentity,
        isFalse,
      );
      expect(
        identity
            .copyWith(filter: const PhotoEditFilter(brightness: 1))
            .isIdentity,
        isFalse,
      );
    });
  });

  group('buildEditColorMatrix', () {
    const identityMatrix = <double>[
      1, 0, 0, 0, 0,
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ];

    test('恒等パラメータで恒等行列になる', () {
      final m = buildEditColorMatrix(const PhotoEditFilter());
      for (int i = 0; i < 20; i++) {
        expect(m[i], closeTo(identityMatrix[i], 1e-12), reason: '要素[$i]');
      }
    });

    test('プリセット「オリジナル」も恒等行列', () {
      expect(kFilterPresets.first.preset, 'オリジナル');
      final m = buildEditColorMatrix(kFilterPresets.first);
      for (int i = 0; i < 20; i++) {
        expect(m[i], closeTo(identityMatrix[i], 1e-12));
      }
    });

    test('明るさ100はRGBオフセット+150', () {
      final m = buildEditColorMatrix(const PhotoEditFilter(brightness: 100));
      expect(m[4], closeTo(150, 1e-9));
      expect(m[9], closeTo(150, 1e-9));
      expect(m[14], closeTo(150, 1e-9));
    });

    test('プリセットは6種', () {
      expect(kFilterPresets, hasLength(6));
      expect(
        kFilterPresets.map((p) => p.preset),
        ['オリジナル', 'おいしい', 'カフェ', '鮮やか', 'ナチュラル', 'レトロ'],
      );
    });
  });

  group('座標写像ラウンドトリップ', () {
    const rotations = <double>[0, 90, -90, 17.3];
    const viewports = <Size>[Size(390, 640), Size(800, 400)];
    const sources = <Size>[Size(4000, 3000), Size(3000, 4000)];
    const frames = <Rect>[
      Rect.fromLTWH(20, 80, 350, 350), // 正方形・中心ずれ
      Rect.fromLTWH(30, 100, 330, 240), // 横長
    ];

    for (final rotation in rotations) {
      for (final viewport in viewports) {
        for (final src in sources) {
          for (final frame in frames) {
            test('回転$rotation度 vp=$viewport src=$src frame=$frame', () {
              final minScale = PhotoEditGeometry.minCoverScale(
                frameRect: frame,
                srcSize: src,
                rotationDeg: rotation,
              );
              final scale = minScale * 1.37;
              final offset = PhotoEditGeometry.clampOffsetToCover(
                viewportSize: viewport,
                frameRect: frame,
                srcSize: src,
                rotationDeg: rotation,
                scale: scale,
                offset: const Offset(37.3, -22.1),
              );

              final crop = PhotoEditGeometry.displayToCropRect(
                viewportSize: viewport,
                frameRect: frame,
                srcSize: src,
                rotationDeg: rotation,
                scale: scale,
                offset: offset,
              );

              final restored = PhotoEditGeometry.cropRectToDisplay(
                viewportSize: viewport,
                frameRect: frame,
                srcSize: src,
                rotationDeg: rotation,
                cropRect: crop,
              );

              // 表示状態の復元誤差 < 0.5px
              expect(restored.scale / scale, closeTo(1.0, 1e-9));
              expect((restored.offset - offset).distance, lessThan(0.5));

              // 復元した表示状態から再写像したcropRectも一致
              final crop2 = PhotoEditGeometry.displayToCropRect(
                viewportSize: viewport,
                frameRect: frame,
                srcSize: src,
                rotationDeg: rotation,
                scale: restored.scale,
                offset: restored.offset,
              );
              expect((crop2.left - crop.left).abs(), lessThan(0.5));
              expect((crop2.top - crop.top).abs(), lessThan(0.5));
              expect((crop2.width - crop.width).abs(), lessThan(0.5));
              expect((crop2.height - crop.height).abs(), lessThan(0.5));
            });
          }
        }
      }
    }

    test('cropRect起点の往復も一致する', () {
      const viewport = Size(390, 640);
      const frame = Rect.fromLTWH(20, 120, 350, 400);
      const src = Size(4000, 3000);
      const rotation = 17.3;
      // 枠と同じアスペクト比のcropRect
      const scale = 0.4;
      final crop = Rect.fromLTWH(
          500, 300, frame.width / scale, frame.height / scale);

      final display = PhotoEditGeometry.cropRectToDisplay(
        viewportSize: viewport,
        frameRect: frame,
        srcSize: src,
        rotationDeg: rotation,
        cropRect: crop,
      );
      final crop2 = PhotoEditGeometry.displayToCropRect(
        viewportSize: viewport,
        frameRect: frame,
        srcSize: src,
        rotationDeg: rotation,
        scale: display.scale,
        offset: display.offset,
      );
      expect((crop2.left - crop.left).abs(), lessThan(0.5));
      expect((crop2.top - crop.top).abs(), lessThan(0.5));
      expect((crop2.width - crop.width).abs(), lessThan(0.5));
      expect((crop2.height - crop.height).abs(), lessThan(0.5));
    });
  });

  group('coverクランプ', () {
    const rotations = <double>[0, 17.3, 33, 90];
    const viewport = Size(390, 640);
    const src = Size(4000, 3000);
    const frame = Rect.fromLTWH(20, 120, 350, 466);
    const wildOffsets = <Offset>[
      Offset.zero,
      Offset(500, -800),
      Offset(-10000, 10000),
      Offset(3.7, 120.1),
    ];

    /// 枠の4隅が元画像領域内にあるか検証
    void expectFrameCovered({
      required double rotationDeg,
      required double scale,
      required Offset offset,
    }) {
      const tolerance = 1e-5;
      final corners = [
        frame.topLeft,
        frame.topRight,
        frame.bottomLeft,
        frame.bottomRight,
      ];
      for (final corner in corners) {
        final p = PhotoEditGeometry.viewToSource(
          point: corner,
          viewportSize: viewport,
          srcSize: src,
          rotationDeg: rotationDeg,
          scale: scale,
          offset: offset,
        );
        expect(p.dx, greaterThanOrEqualTo(-tolerance),
            reason: '角$corner (回転$rotationDeg度)');
        expect(p.dx, lessThanOrEqualTo(src.width + tolerance));
        expect(p.dy, greaterThanOrEqualTo(-tolerance));
        expect(p.dy, lessThanOrEqualTo(src.height + tolerance));
      }
    }

    for (final rotation in rotations) {
      test('回転$rotation度: 最小scaleちょうどでも枠が画像内に収まる', () {
        final minScale = PhotoEditGeometry.minCoverScale(
          frameRect: frame,
          srcSize: src,
          rotationDeg: rotation,
        );
        expect(minScale, greaterThan(0));
        for (final wild in wildOffsets) {
          final clamped = PhotoEditGeometry.clampOffsetToCover(
            viewportSize: viewport,
            frameRect: frame,
            srcSize: src,
            rotationDeg: rotation,
            scale: minScale,
            offset: wild,
          );
          expectFrameCovered(
              rotationDeg: rotation, scale: minScale, offset: clamped);
        }
      });

      test('回転$rotation度: 任意のscale/offsetでもクランプ後は枠がはみ出ない', () {
        final minScale = PhotoEditGeometry.minCoverScale(
          frameRect: frame,
          srcSize: src,
          rotationDeg: rotation,
        );
        for (final factor in const [1.2, 1.5, 3.0]) {
          final scale = minScale * factor;
          for (final wild in wildOffsets) {
            final clamped = PhotoEditGeometry.clampOffsetToCover(
              viewportSize: viewport,
              frameRect: frame,
              srcSize: src,
              rotationDeg: rotation,
              scale: scale,
              offset: wild,
            );
            expectFrameCovered(
                rotationDeg: rotation, scale: scale, offset: clamped);

            // クランプは冪等（既に有効なoffsetは動かさない）
            final clamped2 = PhotoEditGeometry.clampOffsetToCover(
              viewportSize: viewport,
              frameRect: frame,
              srcSize: src,
              rotationDeg: rotation,
              scale: scale,
              offset: clamped,
            );
            expect((clamped2 - clamped).distance, lessThan(1e-6));
          }
        }
      });
    }
  });

  group('bakePhotoEdit', () {
    late Directory tempDir;

    setUpAll(() {
      tempDir = Directory.systemTemp.createTempSync('photo_edit_core_test');
    });

    tearDownAll(() {
      tempDir.deleteSync(recursive: true);
    });

    String writeJpg(String name, img.Image image) {
      final path = '${tempDir.path}${Platform.pathSeparator}$name';
      File(path).writeAsBytesSync(img.encodeJpg(image, quality: 95));
      return path;
    }

    /// 左半分が赤、右半分が青の画像
    img.Image makeHalves(int width, int height) {
      final image = img.Image(width: width, height: height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          if (x < width ~/ 2) {
            image.setPixelRgb(x, y, 255, 0, 0);
          } else {
            image.setPixelRgb(x, y, 0, 0, 255);
          }
        }
      }
      return image;
    }

    img.Image makeFlat(int width, int height, int r, int g, int b) {
      final image = img.Image(width: width, height: height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          image.setPixelRgb(x, y, r, g, b);
        }
      }
      return image;
    }

    test('90度回転: 時計回りで左半分(赤)が上に来る', () {
      final input = writeJpg('rotate_in.jpg', makeHalves(40, 20));
      final output = '${tempDir.path}${Platform.pathSeparator}rotate_out.jpg';
      final result = bakePhotoEdit(PhotoEditBakeRequest(
        inputPath: input,
        outputPath: output,
        params: const PhotoEditParams(
          rotationDeg: 90,
          cropRect: Rect.fromLTWH(0, 0, 20, 40),
          srcW: 40,
          srcH: 20,
        ),
      ));

      expect(result, output);
      final baked = img.decodeImage(File(output).readAsBytesSync())!;
      expect(baked.width, 20);
      expect(baked.height, 40);
      final top = baked.getPixel(10, 5);
      final bottom = baked.getPixel(10, 35);
      expect(top.r, greaterThan(180), reason: '上半分は赤');
      expect(top.b, lessThan(100));
      expect(bottom.b, greaterThan(180), reason: '下半分は青');
      expect(bottom.r, lessThan(100));
    });

    test('cropRectどおりに切り抜かれる', () {
      final input = writeJpg('crop_in.jpg', makeHalves(100, 80));
      final output = '${tempDir.path}${Platform.pathSeparator}crop_out.jpg';
      final result = bakePhotoEdit(PhotoEditBakeRequest(
        inputPath: input,
        outputPath: output,
        params: const PhotoEditParams(
          rotationDeg: 0,
          cropRect: Rect.fromLTWH(60, 20, 30, 40), // 右側(青)のみ
          srcW: 100,
          srcH: 80,
        ),
      ));

      expect(result, output);
      final baked = img.decodeImage(File(output).readAsBytesSync())!;
      expect(baked.width, 30);
      expect(baked.height, 40);
      final center = baked.getPixel(15, 20);
      expect(center.b, greaterThan(180));
      expect(center.r, lessThan(100));
    });

    test('EXIF orientation 6が正規化される', () {
      final image = makeHalves(30, 10);
      image.exif.imageIfd.orientation = 6; // 90度時計回りで正立
      final input = writeJpg('exif_in.jpg', image);
      final output = '${tempDir.path}${Platform.pathSeparator}exif_out.jpg';
      final result = bakePhotoEdit(PhotoEditBakeRequest(
        inputPath: input,
        outputPath: output,
        // EXIF正規化後(10x30)基準の全域crop
        params: const PhotoEditParams(
          rotationDeg: 0,
          cropRect: Rect.fromLTWH(0, 0, 10, 30),
          srcW: 10,
          srcH: 30,
        ),
      ));

      expect(result, output);
      final baked = img.decodeImage(File(output).readAsBytesSync())!;
      expect(baked.width, 10);
      expect(baked.height, 30);
    });

    test('明るさ+100でグレーが白飛びする(行列と同じ数式)', () {
      final input = writeJpg('bright_in.jpg', makeFlat(32, 32, 128, 128, 128));
      final output = '${tempDir.path}${Platform.pathSeparator}bright_out.jpg';
      final result = bakePhotoEdit(PhotoEditBakeRequest(
        inputPath: input,
        outputPath: output,
        params: const PhotoEditParams(
          rotationDeg: 0,
          cropRect: Rect.fromLTWH(0, 0, 32, 32),
          srcW: 32,
          srcH: 32,
          filter: PhotoEditFilter(brightness: 100), // 128 + 150 → 255
        ),
      ));

      expect(result, output);
      final baked = img.decodeImage(File(output).readAsBytesSync())!;
      final center = baked.getPixel(16, 16);
      expect(center.r, greaterThan(250));
      expect(center.g, greaterThan(250));
      expect(center.b, greaterThan(250));
    });

    test('ビネット100で四隅が暗く中央は明るいまま', () {
      final input = writeJpg('vig_in.jpg', makeFlat(64, 64, 255, 255, 255));
      final output = '${tempDir.path}${Platform.pathSeparator}vig_out.jpg';
      final result = bakePhotoEdit(PhotoEditBakeRequest(
        inputPath: input,
        outputPath: output,
        params: const PhotoEditParams(
          rotationDeg: 0,
          cropRect: Rect.fromLTWH(0, 0, 64, 64),
          srcW: 64,
          srcH: 64,
          filter: PhotoEditFilter(vignette: 100),
        ),
      ));

      expect(result, output);
      final baked = img.decodeImage(File(output).readAsBytesSync())!;
      expect(baked.getPixel(32, 32).r, greaterThan(230), reason: '中央');
      expect(baked.getPixel(1, 1).r, lessThan(130), reason: '四隅');
    });

    test('長辺4096px超は縮小される', () {
      final input = writeJpg('resize_in.jpg', makeFlat(4200, 100, 0, 255, 0));
      final output = '${tempDir.path}${Platform.pathSeparator}resize_out.jpg';
      final result = bakePhotoEdit(PhotoEditBakeRequest(
        inputPath: input,
        outputPath: output,
        params: const PhotoEditParams(
          rotationDeg: 0,
          cropRect: Rect.fromLTWH(0, 0, 4200, 100),
          srcW: 4200,
          srcH: 100,
        ),
      ));

      expect(result, output);
      final baked = img.decodeImage(File(output).readAsBytesSync())!;
      expect(baked.width, kBakeMaxDimension);
      expect(baked.height, inInclusiveRange(96, 99));
    });

    test('任意角回転+cropでも境界クランプで落ちない', () {
      final input = writeJpg('free_in.jpg', makeHalves(200, 150));
      final output = '${tempDir.path}${Platform.pathSeparator}free_out.jpg';

      // 表示状態からcropRectを作る(実利用と同じ経路)
      const viewport = Size(390, 640);
      const frame = Rect.fromLTWH(20, 120, 350, 350);
      const src = Size(200, 150);
      const rotation = 17.3;
      final scale = PhotoEditGeometry.minCoverScale(
        frameRect: frame,
        srcSize: src,
        rotationDeg: rotation,
      );
      final offset = PhotoEditGeometry.clampOffsetToCover(
        viewportSize: viewport,
        frameRect: frame,
        srcSize: src,
        rotationDeg: rotation,
        scale: scale,
        offset: Offset.zero,
      );
      final crop = PhotoEditGeometry.displayToCropRect(
        viewportSize: viewport,
        frameRect: frame,
        srcSize: src,
        rotationDeg: rotation,
        scale: scale,
        offset: offset,
      );

      final result = bakePhotoEdit(PhotoEditBakeRequest(
        inputPath: input,
        outputPath: output,
        params: PhotoEditParams(
          rotationDeg: rotation,
          cropRect: crop,
          srcW: 200,
          srcH: 150,
        ),
      ));

      expect(result, output);
      final baked = img.decodeImage(File(output).readAsBytesSync())!;
      // 枠は正方形なのでcrop結果も(丸め誤差1px以内で)正方形
      expect((baked.width - baked.height).abs(), lessThanOrEqualTo(1));
      expect(baked.width, inInclusiveRange(crop.width.floor() - 1, crop.width.ceil() + 1));
    });

    test('存在しない入力パスはnull', () {
      final result = bakePhotoEdit(PhotoEditBakeRequest(
        inputPath: '${tempDir.path}${Platform.pathSeparator}missing.jpg',
        outputPath: '${tempDir.path}${Platform.pathSeparator}never.jpg',
        params: PhotoEditParams.identity(srcW: 10, srcH: 10),
      ));
      expect(result, isNull);
    });
  });
}
