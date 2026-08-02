import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/analysis_verdict.dart';

/// 判定に使う例は、すべて実機のベンチで実際に出た文言。
/// 想像で作った例だと、現実の外れ方から離れた判定になる。

void main() {
  group('曖昧な名前の検出', () {
    test('色や器で説明して料理名を避けたものは曖昧', () {
      // 実測: 温度0.9/低温のどちらでも出た
      for (final name in [
        '濃厚なソースがけの黄色い麺料理',
        '濃厚な卵スープの黄色い麺料理',
        'カルビービッグBAGの袋菓子と青いカップに入った何か',
        'カルビービッグバッグと青いカップの食べ物',
      ]) {
        expect(isVagueName(name), isTrue, reason: name);
      }
    });

    test('従来の併記・推測表現も曖昧', () {
      for (final name in ['味噌ラーメンまたは醤油ラーメン', 'おそらくカレー', 'パスタのような麺']) {
        expect(isVagueName(name), isTrue, reason: name);
      }
    });

    test('ちゃんとした料理名は曖昧ではない', () {
      for (final name in [
        '味噌ラーメン',
        'グリーンソースのトマトとキュウリのパスタ',
        'フライドチキンとご飯セット',
        '鮭の塩焼き定食',
        '明太高菜ご飯とチキン南蛮弁当',
      ]) {
        expect(isVagueName(name), isFalse, reason: name);
      }
    });
  });

  group('名前の近さ', () {
    test('言い回しが違うだけの答えは近いと判定する', () {
      // 実測: 同じ弁当の写真で3回まわして出た名前
      expect(nameSimilarity('鮭とご飯の定食', '鮭の塩焼き定食'), greaterThan(0.45));
    });

    test('別物は近くない', () {
      expect(
        nameSimilarity('グリーンソースのパスタ', '濃厚な卵スープの黄色い麺料理'),
        lessThan(0.45),
      );
    });

    test('完全一致は1', () {
      expect(nameSimilarity('味噌ラーメン', '味噌ラーメン'), 1.0);
    });

    test('空白や記号の違いは無視する', () {
      expect(nameSimilarity('味噌ラーメン', '味噌 ラーメン'), 1.0);
      expect(nameSimilarity('唐揚げ定食', '唐揚げ（定食）'), 1.0);
    });
  });

  group('判定', () {
    test('1回だけで、はっきりした名前なら自信あり', () {
      final v = judgeAnalysis(['味噌ラーメン']);
      expect(v.confidence, AnalysisConfidence.high);
      expect(v.primary, '味噌ラーメン');
      expect(v.candidates, ['味噌ラーメン']);
      expect(v.needsReview, isFalse);
    });

    test('1回でも曖昧な名前なら選んでもらう', () {
      final v = judgeAnalysis(['濃厚なソースがけの黄色い麺料理']);
      expect(v.confidence, AnalysisConfidence.low);
      expect(v.needsReview, isTrue);
    });

    test('何度まわしても近い答えなら自信あり', () {
      final v = judgeAnalysis(['鮭とご飯の定食', '鮭の塩焼き定食', '鮭の塩焼きと卵焼きの定食']);
      expect(v.confidence, AnalysisConfidence.high);
      expect(v.candidates.length, 1, reason: '同じ答えとしてまとまる');
    });

    test('答えが割れたら選んでもらう', () {
      final v = judgeAnalysis(['グリーンソースのパスタ', '濃厚な卵スープの黄色い麺料理']);
      expect(v.confidence, AnalysisConfidence.low);
      expect(v.candidates.length, 2);
    });

    test('多く出た答えを主候補にする', () {
      final v = judgeAnalysis(['唐揚げ弁当', '天ぷらそば', '唐揚げ定食']);
      expect(v.primary, contains('唐揚げ'));
      expect(v.candidates.first, contains('唐揚げ'));
    });

    test('同数なら曖昧でないほうを主候補にする', () {
      final v = judgeAnalysis(['黄色い麺料理', 'ナポリタン']);
      expect(v.primary, 'ナポリタン');
      expect(v.confidence, AnalysisConfidence.low, reason: '割れているので確認は要る');
    });

    test('同じ答えの中では短い言い方を採る', () {
      final v = judgeAnalysis(['鮭の塩焼きと卵焼きの定食', '鮭の塩焼き定食']);
      expect(v.primary, '鮭の塩焼き定食');
    });

    test('候補には主候補が必ず先頭で入る', () {
      final v = judgeAnalysis(['ナポリタン', '唐揚げ弁当', '味噌ラーメン']);
      expect(v.candidates.first, v.primary);
      expect(v.candidates.length, 3);
    });

    test('全部が曖昧でも、答えが揃っていれば候補は1つ', () {
      final v = judgeAnalysis(['黄色い麺料理', '黄色い麺料理']);
      expect(v.candidates.length, 1);
      expect(v.confidence, AnalysisConfidence.low, reason: '曖昧なので確認は要る');
    });
  });

  group('実測の並びで通す', () {
    test('ベンチで出た3条件の答えは割れたと判定される', () {
      // 同じパスタの写真から出た3つ
      final v = judgeAnalysis([
        'アボカドとトマトのペストパスタ',
        'グリーンソースのパスタ',
        'グリーンソースのトマトとキュウリのパスタ',
      ]);
      expect(v.needsReview, isTrue);
      expect(v.candidates.length, greaterThan(1));
    });
  });
}
