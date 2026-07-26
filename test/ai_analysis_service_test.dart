import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/ai_analysis_service.dart';

void main() {
  group('sanitizeMenuName', () {
    test('変化不要な断定名はそのまま返す', () {
      expect(AiAnalysisService.sanitizeMenuName('味噌ラーメン'), '味噌ラーメン');
    });

    test('「または」以降を除去して1つに断定する', () {
      expect(
        AiAnalysisService.sanitizeMenuName('味噌ラーメンまたは醤油ラーメン'),
        '味噌ラーメン',
      );
    });

    test('「もしくは」以降も除去する', () {
      expect(
        AiAnalysisService.sanitizeMenuName('カルボナーラもしくはペペロンチーノ'),
        'カルボナーラ',
      );
    });

    test('推測表現を含む全角括弧を丸ごと除去する', () {
      expect(
        AiAnalysisService.sanitizeMenuName('カレーライス（おそらくビーフカレー）'),
        'カレーライス',
      );
    });

    test('推測表現を含む半角括弧も除去する', () {
      expect(
        AiAnalysisService.sanitizeMenuName('うどん(たぶんきつねうどん)'),
        'うどん',
      );
    });

    test('断定的な補足の括弧は残す', () {
      expect(
        AiAnalysisService.sanitizeMenuName('唐揚げ定食（大盛り）'),
        '唐揚げ定食（大盛り）',
      );
    });

    test('末尾の読点・前後の空白を除去する', () {
      expect(AiAnalysisService.sanitizeMenuName('  ハンバーグ、 '), 'ハンバーグ');
    });

    test('併記と推測括弧が混在しても断定名だけ残す', () {
      expect(
        AiAnalysisService.sanitizeMenuName('天ぷらそば（おそらく）または月見そば'),
        '天ぷらそば',
      );
    });

    test('整形で全て消える場合は元の文字列(前後空白除去)を返す', () {
      expect(
        AiAnalysisService.sanitizeMenuName(' （おそらくカレー） '),
        '（おそらくカレー）',
      );
    });

    // 以下は実際の記録に残っていた出力。括弧の内側に併記があるため、
    // 「または」で先に切ると括弧が開いたまま残っていた
    group('括弧の内側の併記', () {
      test('全角括弧の中の「または」ごと落とす', () {
        expect(
          AiAnalysisService.sanitizeMenuName('鶏肉とネギの和風パスタ（または麺料理）'),
          '鶏肉とネギの和風パスタ',
        );
      });

      test('半角括弧・前置き空白ありでも落とす', () {
        expect(
          AiAnalysisService.sanitizeMenuName('豚肉蒸し (またはそれに類する肉料理)'),
          '豚肉蒸し',
        );
      });

      test('括弧の外と中の両方に併記があっても先頭の1つに断定する', () {
        expect(
          AiAnalysisService.sanitizeMenuName(
              '和牛のカルパッチョまたはローストビーフのサラダ（または和牛の冷製料理）'),
          '和牛のカルパッチョ',
        );
      });

      test('推測と併記が入れ子でも落とす', () {
        expect(
          AiAnalysisService.sanitizeMenuName('琥珀色の飲み物（おそらくカクテルまたはレモンサワーなど）'),
          '琥珀色の飲み物',
        );
      });
    });

    test('閉じられていない括弧以降を落とす', () {
      expect(AiAnalysisService.sanitizeMenuName('味噌ラーメン（大盛'), '味噌ラーメン');
    });
  });
}
