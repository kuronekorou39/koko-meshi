import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/model_downloader.dart';

/// 2.4GBのDLを実際に走らせるテストは書けないので、再開の判断だけを固定する。
/// ここを間違えるとモデルファイルが静かに壊れる(過去に追記破損で4.85GBの
/// ファイルが「インストール済み」になった実績がある)。
void main() {
  const expected = 2588147712;

  group('planResume', () {
    test('何も無ければ先頭から', () {
      expect(planResume(partBytes: 0, expectedBytes: expected),
          ResumePlan.fresh);
    });

    test('途中まであれば続きから', () {
      expect(planResume(partBytes: 1000, expectedBytes: expected),
          ResumePlan.resume);
    });

    test('ちょうど揃っていれば完了扱い', () {
      expect(planResume(partBytes: expected, expectedBytes: expected),
          ResumePlan.alreadyComplete);
    });

    test('期待より大きいものは信用せず作り直す', () {
      expect(planResume(partBytes: expected + 1, expectedBytes: expected),
          ResumePlan.fresh);
    });

    test('負の値でも落ちずに先頭から', () {
      expect(planResume(partBytes: -1, expectedBytes: expected),
          ResumePlan.fresh);
    });
  });

  group('planWrite', () {
    test('範囲要求して206なら追記する', () {
      expect(
        planWrite(statusCode: HttpStatus.partialContent, requestedRange: true),
        WritePlan.append,
      );
    });

    test('範囲要求したのに200なら作り直す(サーバが範囲を無視した)', () {
      expect(
        planWrite(statusCode: HttpStatus.ok, requestedRange: true),
        WritePlan.truncate,
      );
    });

    test('範囲要求していなければ常に作り直す', () {
      expect(
        planWrite(statusCode: HttpStatus.ok, requestedRange: false),
        WritePlan.truncate,
      );
    });

    test('範囲要求していないのに206が来ても追記しない', () {
      // 要求していない範囲応答は辻褄が合わないので、先頭から書く方が安全
      expect(
        planWrite(statusCode: HttpStatus.partialContent, requestedRange: false),
        WritePlan.truncate,
      );
    });
  });

  group('download', () {
    test('すでに全部落ちている .part は本体にrenameされる', () async {
      final dir = await Directory.systemTemp.createTemp('kokomeshi_dl');
      addTearDown(() => dir.delete(recursive: true));
      final dest = '${dir.path}/model.litertlm';
      final body = List<int>.filled(64, 7);
      await File('$dest.part').writeAsBytes(body);

      final progress = <int>[];
      final result = await ModelDownloader.download(
        // 通信は起きない経路なのでURLは使われない
        url: 'https://example.invalid/model',
        destPath: dest,
        expectedBytes: body.length,
        onProgress: progress.add,
      );

      expect(result, dest);
      expect(await File(dest).length(), body.length);
      expect(await File('$dest.part').exists(), isFalse);
      expect(progress.last, 100);
    });

    test('通信できなければ例外になり、本体は作られない', () async {
      final dir = await Directory.systemTemp.createTemp('kokomeshi_dl');
      addTearDown(() => dir.delete(recursive: true));
      final dest = '${dir.path}/model.litertlm';

      await expectLater(
        ModelDownloader.download(
          url: 'https://kokomeshi.invalid/model',
          destPath: dest,
          expectedBytes: 100,
        ),
        throwsA(isA<Exception>()),
      );
      expect(await File(dest).exists(), isFalse);
    });
  });
}
