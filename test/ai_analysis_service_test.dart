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
  });
}
