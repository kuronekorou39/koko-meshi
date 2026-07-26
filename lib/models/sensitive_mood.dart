import 'dart:math';

/// センシティブ写真に付けるタイトルの「雰囲気」。
///
/// タイトルの文言そのものはモデルが写真を踏まえて生成する(モデルの結果を尊重)。
/// ここで決めるのは口調・方向性だけ。
///
/// 指示は「どんな話し方か」ではなく「どんな役の人が、写っているものを
/// どの枠に押し込むか」で書くこと。話し方だけを指定すると、モデルは無難な語
/// (「サプライズ」等)に逃げて口調の差が出ない。実際に見比べて、枠を与えた
/// ものだけが writing として成立していた。
///
/// [fallback] はモデルがタイトル生成を拒否したときに使う単独の文言。
/// 拒否時は写真の描写も取れていないことが多いため、内容には触れず雰囲気だけを出す。
///
/// これはユーザーには見せない裏の仕掛けなので、設定画面には出していない。
enum SensitiveMood {
  excited(
    '興奮ツッコミ',
    '見てはいけないものを見てしまった人が、思わず本音を大声で叫んでしまう口調'
        '（「エッチ！！」のようなノリ）',
    'って、エッチ！！',
    35,
  ),
  foodie(
    '食いしん坊',
    '何を見ても食べ物に見える食いしん坊が、あくまで料理として大真面目に評価してしまう口調',
    '本日の一皿…カロリー計測不能',
    35,
  ),
  shy(
    '恥じらい',
    '恥ずかしくてどもりながら小声になってしまう口調',
    'こ、これは…お見せできません…///',
    14,
  ),
  panicked(
    'てんぱり',
    '真面目な記録係が、想定外のものを突きつけられて完全に取り乱し、'
        '手が震えたまま独り言を漏らす口調',
    'え、えっと、これ記録していいやつ！？',
    14,
  ),
  poetic(
    '詩人',
    '歌人が、写っているものを季節の情景に見立てて一首詠むように詠嘆する口調',
    '言葉にするは、無粋なりけり',
    2,
  );

  const SensitiveMood(this.label, this.instruction, this.fallback, this.weight);

  final String label;
  final String instruction;
  final String fallback;

  /// 出現比率(%)。全体の合計が [totalWeight] になるようにすること。
  final int weight;

  /// 比率の合計。ここを崩すと選択が偏るので、テストで担保している。
  static const int totalWeight = 100;

  /// 0以上 [totalWeight] 未満の値から雰囲気を1つ選ぶ(比率に従う)。
  static SensitiveMood forRoll(int roll) {
    var remaining = roll;
    for (final mood in values) {
      remaining -= mood.weight;
      if (remaining < 0) return mood;
    }
    return values.last;
  }

  /// 比率に従って1つ引く。解析のたびに引き直すので、同じ写真を再解析すると
  /// 別の口調になることがある(それを狙っている)。
  static SensitiveMood random([Random? rng]) =>
      forRoll((rng ?? _rng).nextInt(totalWeight));

  static final Random _rng = Random();
}
