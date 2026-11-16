import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/storage_stats.dart';

void main() {
  group('formatBytes', () {
    test('1024未満はバイトのまま', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('10未満は小数1桁まで出す', () {
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes((3.2 * 1024 * 1024 * 1024).round()), '3.2 GB');
    });

    test('10以上は整数に丸める', () {
      expect(formatBytes(850 * 1024 * 1024), '850 MB');
      expect(formatBytes(12 * 1024 * 1024 * 1024), '12 GB');
    });
  });
}
