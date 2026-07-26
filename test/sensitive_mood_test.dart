import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/models/sensitive_mood.dart';

void main() {
  group('SensitiveMood', () {
    test('比率の合計が totalWeight と一致する', () {
      final sum = SensitiveMood.values
          .map((m) => m.weight)
          .reduce((a, b) => a + b);
      expect(sum, SensitiveMood.totalWeight);
    });

    test('比率どおりの境界で切り替わる', () {
      // 興奮ツッコミ35 / 食いしん坊35 / 恥じらい14 / てんぱり14 / 詩人2
      expect(SensitiveMood.forRoll(0), SensitiveMood.excited);
      expect(SensitiveMood.forRoll(34), SensitiveMood.excited);
      expect(SensitiveMood.forRoll(35), SensitiveMood.foodie);
      expect(SensitiveMood.forRoll(69), SensitiveMood.foodie);
      expect(SensitiveMood.forRoll(70), SensitiveMood.shy);
      expect(SensitiveMood.forRoll(83), SensitiveMood.shy);
      expect(SensitiveMood.forRoll(84), SensitiveMood.panicked);
      expect(SensitiveMood.forRoll(97), SensitiveMood.panicked);
      expect(SensitiveMood.forRoll(98), SensitiveMood.poetic);
      expect(SensitiveMood.forRoll(99), SensitiveMood.poetic);
    });

    test('各値がちょうど weight ぶんの目に割り当てられている', () {
      final counts = <SensitiveMood, int>{};
      for (var roll = 0; roll < SensitiveMood.totalWeight; roll++) {
        final mood = SensitiveMood.forRoll(roll);
        counts[mood] = (counts[mood] ?? 0) + 1;
      }
      for (final mood in SensitiveMood.values) {
        expect(counts[mood], mood.weight, reason: mood.label);
      }
    });

    test('同じ写真IDなら毎回同じ雰囲気になる', () {
      const id = '0012ecf5-c519-40f6-a1d0-faa6c682311e';
      final first = SensitiveMood.forPhotoId(id);
      for (var i = 0; i < 20; i++) {
        expect(SensitiveMood.forPhotoId(id), first);
      }
    });

    test('指示とfallbackが空でない', () {
      for (final mood in SensitiveMood.values) {
        expect(mood.instruction, isNotEmpty, reason: mood.label);
        expect(mood.fallback, isNotEmpty, reason: mood.label);
      }
    });
  });
}
