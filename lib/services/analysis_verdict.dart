/// 解析結果の確からしさ。
enum AnalysisConfidence {
  /// そのまま登録してよい
  high,

  /// 利用者に選んでもらう
  low,
}

/// 複数回の解析から決めた「答えと候補」。
class AnalysisVerdict {
  const AnalysisVerdict({
    required this.primary,
    required this.candidates,
    required this.confidence,
  });

  /// 採用する料理名
  final String primary;

  /// 選択肢として出す名前(primaryを先頭に含む)。1件なら選ばせる必要は無い
  final List<String> candidates;

  final AnalysisConfidence confidence;

  bool get needsReview => confidence == AnalysisConfidence.low;
}

/// 料理名になっていない言い回し。
///
/// 前半は既存の併記・推測表現(ベンチの hedgePattern と同じ並び)。後半は
/// 実測で出た「断定できていないときの逃げ方」を足したもの:
/// 「青いカップに入った何か」「濃厚なソースがけの黄色い麺料理」など、
/// 色や器で説明して料理名を避ける形。
final RegExp vagueNamePattern = RegExp(
  'または|もしくは|おそらく|恐らく|たぶん|多分|かもしれ|思われ|のような|類する'
  '|何か|なにか|不明|らしきもの|らしいもの'
  '|[白黒赤青黄緑茶]色[いのっ]|黄色い|白い|黒い|赤い|青い|茶色い'
  r'|入った(もの|物)|の(もの|物)$',
);

/// 名前が「料理名として使えない」か
bool isVagueName(String name) => vagueNamePattern.hasMatch(name);

/// 比較用に正規化する。表記の揺れだけの違いを同じ扱いにしたい
String _normalize(String s) => s
    .replaceAll(RegExp(r'[\s　]'), '')
    .replaceAll(RegExp(r'[（）()「」、,。・~〜\-ー]'), '')
    .toLowerCase();

/// 2つの名前がどれくらい重なっているか(0..1)。
///
/// 日本語を単語に割るには形態素解析が要るので、**文字の集合の重なり**で
/// 代用する。「鮭とご飯の定食」と「鮭の塩焼き定食」は鮭・の・定・食を
/// 共有するので近い、と判定できる程度の粗さで足りる。
///
/// Jaccard ではなく Dice を使う。日本語の料理名は共有部分に対して修飾語が
/// 長くなりがちで、Jaccard だと上の例が0.40しか出ず「別の答え」に倒れる
/// (Diceなら0.57)。別物どうし(「グリーンソースのパスタ」と「濃厚な卵スープの
/// 黄色い麺料理」= 0.26)との差も、Diceのほうが開く。
double nameSimilarity(String a, String b) {
  final x = _normalize(a).split('').toSet();
  final y = _normalize(b).split('').toSet();
  if (x.isEmpty || y.isEmpty) return 0;
  final common = x.intersection(y).length;
  return 2 * common / (x.length + y.length);
}

/// これ以上重なっていれば「同じ答え」とみなす。
///
/// 完全一致にすると、実測では18枚中16枚が「揺れた」と判定される
/// (温度0.9で毎回言い回しが変わるため)。ほぼ全部が要確認になって
/// 使い物にならないので、粗く寄せる。
const double _sameAnswerThreshold = 0.45;

/// 解析結果の名前たちから、採用する名前と候補、確からしさを決める。
///
/// [names] は複数回まわした結果(1回だけならそれ1つ)。空やnullは呼ぶ前に
/// 除いておくこと。
///
/// 判定の考え方:
/// - 曖昧な言い回ししか得られなければ、それは「分からなかった」ということ
/// - 何度まわしても近い答えなら、そのまま採用してよい
/// - 答えが割れたなら、モデルは決めきれていない。利用者に選んでもらう
AnalysisVerdict judgeAnalysis(List<String> names) {
  assert(names.isNotEmpty, '呼ぶ前に空を除くこと');

  // 同じ答えをまとめる。先に出たものを代表にする
  final groups = <List<String>>[];
  for (final name in names) {
    final hit = groups.firstWhere(
      (g) => nameSimilarity(g.first, name) >= _sameAnswerThreshold,
      orElse: () => <String>[],
    );
    if (hit.isEmpty) {
      groups.add([name]);
    } else {
      hit.add(name);
    }
  }

  // 多く出た答えを優先し、同数なら曖昧でないほうを先に
  groups.sort((a, b) {
    final byCount = b.length.compareTo(a.length);
    if (byCount != 0) return byCount;
    final aVague = isVagueName(a.first) ? 1 : 0;
    final bVague = isVagueName(b.first) ? 1 : 0;
    return aVague.compareTo(bVague);
  });

  final candidates = [for (final g in groups) _bestOf(g)];
  final primary = candidates.first;

  // 答えが割れた、または採用する名前が曖昧なら選んでもらう
  final confidence = (groups.length > 1 || isVagueName(primary))
      ? AnalysisConfidence.low
      : AnalysisConfidence.high;

  return AnalysisVerdict(
    primary: primary,
    candidates: candidates,
    confidence: confidence,
  );
}

/// 同じ答えの集まりから、代表を1つ選ぶ。
/// 曖昧でないものを優先し、その中では短いもの(余計な修飾が少ない)を採る
String _bestOf(List<String> group) {
  final sorted = [...group]..sort((a, b) {
      final aVague = isVagueName(a) ? 1 : 0;
      final bVague = isVagueName(b) ? 1 : 0;
      if (aVague != bVague) return aVague.compareTo(bVague);
      return a.length.compareTo(b.length);
    });
  return sorted.first;
}
