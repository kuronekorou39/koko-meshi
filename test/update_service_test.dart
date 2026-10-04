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

  group('parseGithubRelease', () {
    test('タグとリリースページを取り出す', () {
      final latest = UpdateService.parseGithubRelease({
        'tag_name': 'v0.12.0',
        'html_url': 'https://github.com/kuronekorou39/koko-meshi/releases/tag/v0.12.0',
      });
      expect(latest?.version, 'v0.12.0');
      expect(latest?.url, contains('/releases/tag/v0.12.0'));
    });

    test('欠けていれば null', () {
      expect(UpdateService.parseGithubRelease({'tag_name': 'v0.12.0'}), isNull);
      expect(UpdateService.parseGithubRelease({}), isNull);
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
