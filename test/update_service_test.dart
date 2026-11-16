import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/update_service.dart';

void main() {
  group('normalize', () {
    test('タグの先頭のvを落とす', () {
      expect(UpdateService.normalize('v0.9.0'), '0.9.0');
      expect(UpdateService.normalize('V1.2.3'), '1.2.3');
      expect(UpdateService.normalize('0.9.0'), '0.9.0');
    });
  });

  group('isNewer', () {
    test('新しければ true', () {
      expect(UpdateService.isNewer('0.9.0', '0.8.0'), isTrue);
      expect(UpdateService.isNewer('1.0.0', '0.9.9'), isTrue);
      expect(UpdateService.isNewer('0.8.1', '0.8.0'), isTrue);
    });

    test('同じ・古ければ false', () {
      expect(UpdateService.isNewer('0.8.0', '0.8.0'), isFalse);
      expect(UpdateService.isNewer('0.7.9', '0.8.0'), isFalse);
    });

    test('桁ごとに数値で比べる(文字列比較だと 0.9.0 > 0.10.0 になってしまう)', () {
      expect(UpdateService.isNewer('0.10.0', '0.9.0'), isTrue);
      expect(UpdateService.isNewer('0.9.0', '0.10.0'), isFalse);
    });

    test('タグにvが付いていても比べられる', () {
      expect(UpdateService.isNewer('v0.9.0', '0.8.0'), isTrue);
    });

    test('桁数が違っても比べられる', () {
      expect(UpdateService.isNewer('1.0', '0.9.9'), isTrue);
      expect(UpdateService.isNewer('0.8.0.1', '0.8.0'), isTrue);
      expect(UpdateService.isNewer('0.8', '0.8.0'), isFalse);
    });

    test('数字以外が混じっても落ちない', () {
      expect(UpdateService.isNewer('0.9.0-beta', '0.8.0'), isTrue);
      expect(UpdateService.isNewer('こわれたタグ', '0.8.0'), isFalse);
    });
  });

  group('parseManifest', () {
    test('版とAPKの場所を取り出す', () {
      final latest = UpdateService.parseManifest({
        'version': '0.13.1',
        'release_notes': '変更内容',
        'apk_url': 'https://rou39.com/kokomeshi/kokomeshi-v0.13.1.apk',
      });
      expect(latest?.version, '0.13.1');
      expect(latest?.url, endsWith('/kokomeshi-v0.13.1.apk'));
    });

    test('欠けていれば null', () {
      expect(UpdateService.parseManifest({'version': '0.13.1'}), isNull);
      expect(UpdateService.parseManifest({}), isNull);
    });
  });

  group('newerOf', () {
    const stable = (version: '0.13.0', url: 'stable');
    const beta = (version: '0.13.1', url: 'beta');

    test('テスト版のほうが新しければテスト版', () {
      expect(UpdateService.newerOf(stable, beta), beta);
    });

    test('公開版が追いついたら公開版(同じ版なら公開版を優先)', () {
      const caughtUp = (version: '0.13.1', url: 'stable');
      expect(UpdateService.newerOf(caughtUp, beta), caughtUp);
      const ahead = (version: '0.14.0', url: 'stable');
      expect(UpdateService.newerOf(ahead, beta), ahead);
    });

    test('片方が無ければもう片方', () {
      expect(UpdateService.newerOf(null, beta), beta);
      expect(UpdateService.newerOf(stable, null), stable);
      expect(UpdateService.newerOf(null, null), isNull);
    });
  });

  group('parseAppStoreLookup', () {
    test('出ている版とストアのページを取り出す', () {
      final latest = UpdateService.parseAppStoreLookup({
        'resultCount': 1,
        'results': [
          {
            'version': '1.0.1',
            'trackViewUrl': 'https://apps.apple.com/jp/app/id0000000000',
          },
        ],
      });
      expect(latest?.version, '1.0.1');
      expect(latest?.url, startsWith('https://apps.apple.com/'));
    });

    test('公開前(0件)なら null', () {
      expect(
        UpdateService.parseAppStoreLookup({'resultCount': 0, 'results': []}),
        isNull,
      );
    });

    test('形が違っても落ちない', () {
      expect(UpdateService.parseAppStoreLookup({}), isNull);
      expect(UpdateService.parseAppStoreLookup({'results': 'x'}), isNull);
      expect(
        UpdateService.parseAppStoreLookup({
          'results': [
            {'version': 1.0},
          ],
        }),
        isNull,
      );
    });
  });
}
