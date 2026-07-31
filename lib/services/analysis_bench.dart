import 'dart:io';

import 'package:flutter/foundation.dart';

import '../database/local_database.dart';
import '../models/meal_photo.dart';
import '../models/saved_place.dart';
import 'ai_analysis_service.dart';
import 'gemma_ondevice_service.dart';
import 'photo_cache_service.dart';

/// 解析ベンチ(開発用)。保存済みのAI結果を「変更前」、その場の再解析を「変更後」
/// として突き合わせ、プロンプトや推論パラメータをいじった効果を測る。
///
/// 正解ラベル(ユーザーの手修正)は実際にはほとんど存在しないので、
/// **ラベル無しで測れる指標**を主軸にする:
///   - 併記・推測表現の残存率（断定できているか）
///   - JSONを解釈できなかった率
///   - 価格・カロリーの値の散らばり（同じ丸い数字を使い回していないか）
///   - 1枚あたりの推論時間
/// 手修正が入っている記録があれば、正解との一致も併せて集計する。
///
/// このベンチはDBに一切書き戻さない。書き戻すと「変更前」の基準と
/// ユーザーのデータの両方を壊すため。
///
/// 注意: モデルの生の出力を見るため `analyze()` を直接呼んでおり、
/// [AiAnalysisService] 側のセンシティブ画像の扱い(雰囲気タイトルの生成)は
/// 通らない。センシティブ写真の行に素の描写が出ていても、アプリの実挙動が
/// 変わったわけではない。
class AnalysisBench {
  AnalysisBench._();

  /// 併記・推測表現の検出。断定できていない出力を数えるために使う。
  static final RegExp hedgePattern = RegExp(
    'または|もしくは|おそらく|恐らく|たぶん|多分|かもしれ|思われ|のような|類する',
  );

  /// 原本ファイルが端末に残っているか。クラウド時代に原本を消した記録が
  /// 多数あり、それらは再解析できない。
  static bool hasOriginal(MealPhoto photo) {
    if (File(photo.localPath).existsSync()) return true;
    final orig = photo.originalLocalPath;
    return orig != null && File(orig).existsSync();
  }

  /// 比較対象: 解析済み(=変更前の結果がある) かつ 原本が残っている写真。
  static Future<List<MealPhoto>> targets() async {
    final all = await LocalDatabase.getAllMealPhotos();
    return all
        .where((p) => p.aiStatus == 'completed' && hasOriginal(p))
        .toList();
  }

  /// [photos] を再解析して結果を返す。モデルのロード/解放もここで行う。
  static Future<BenchReport> run(
    List<MealPhoto> photos, {
    PromptVariant variant = PromptVariant.current,
    SamplingVariant sampling = SamplingVariant.current,
    void Function(int done, int total)? onProgress,
  }) async {
    if (AiAnalysisService.isBusy) {
      throw StateError('AI解析の実行中です。終わってから試してください');
    }
    final svc = GemmaOnDeviceService.instance;
    if (!await svc.isInstalled(GemmaModelKind.e2b)) {
      throw StateError('端末内AIモデルが未ダウンロードです');
    }

    // 直前のバッチ解析が仕掛けたアイドル解放タイマーに、実行の途中で
    // モデルを落とされないようにする
    AiAnalysisService.beginModelHold();
    final loadMs = await svc.load(GemmaModelKind.e2b);
    final savedPlaces = await LocalDatabase.getSavedPlaces();
    final cases = <BenchCase>[];

    try {
      for (var i = 0; i < photos.length; i++) {
        cases.add(
            await _runOne(photos[i], svc, savedPlaces, variant, sampling));
        onProgress?.call(i + 1, photos.length);
      }
    } finally {
      AiAnalysisService.endModelHold();
      // ベンチは単発なのでモデルを掴んだままにしない(~3GB)
      await svc.disposeModel();
    }

    return BenchReport(
        loadMs: loadMs, cases: cases, variant: variant, sampling: sampling);
  }

  static Future<BenchCase> _runOne(
    MealPhoto photo,
    GemmaOnDeviceService svc,
    List<SavedPlace> savedPlaces,
    PromptVariant variant,
    SamplingVariant sampling,
  ) async {
    final path = await PhotoCacheService.getOriginalPath(
      localPath: photo.localPath,
      originalUrl: photo.originalUrl,
    );
    if (path == null) {
      return BenchCase(photo: photo, error: '写真ファイルが見つかりません');
    }
    try {
      final bytes = await File(path).readAsBytes();
      final context =
          await AiAnalysisService.buildOnDeviceContext(photo, savedPlaces);
      final res =
          await svc.analyze(bytes,
              context: context, variant: variant, sampling: sampling);
      if (res.parsed == null) {
        return BenchCase(
          photo: photo,
          error: 'JSONを解釈できませんでした',
          parseFailed: true,
          inferenceMs: res.inferenceMs,
        );
      }
      return BenchCase(
        photo: photo,
        name: res.menuName == null
            ? null
            : AiAnalysisService.sanitizeMenuName(res.menuName!),
        price: res.price,
        calories: res.calories,
        genre: res.genre,
        inferenceMs: res.inferenceMs,
      );
    } catch (e) {
      debugPrint('[Bench] ${photo.id} failed: $e');
      return BenchCase(photo: photo, error: e.toString());
    }
  }
}

/// 1枚ぶんの比較。`photo` 側に「変更前」の保存済み結果が入っている。
class BenchCase {
  const BenchCase({
    required this.photo,
    this.name,
    this.price,
    this.calories,
    this.genre,
    this.inferenceMs = 0,
    this.error,
    this.parseFailed = false,
  });

  final MealPhoto photo;

  /// 今回の再解析の出力(=変更後)
  final String? name;
  final int? price;
  final int? calories;
  final String? genre;
  final int inferenceMs;
  final String? error;
  final bool parseFailed;

  bool get ok => error == null;

  // ─── 変更前(保存済みのAI結果) ───
  String? get beforeName => photo.aiMenuName;
  int? get beforePrice => photo.aiEstimatedPrice;
  int? get beforeCalories => photo.aiEstimatedCalories;
  String? get beforeGenre => photo.aiCuisineGenre;

  bool get nameChanged => beforeName != name;

  bool get beforeHedged =>
      beforeName != null && AnalysisBench.hedgePattern.hasMatch(beforeName!);
  bool get afterHedged =>
      name != null && AnalysisBench.hedgePattern.hasMatch(name!);

  // ─── 正解(ユーザーが直した値。無ければ評価対象外) ───
  String? get truthName => photo.userCorrectedName;
  int? get truthPrice => photo.userCorrectedPrice;
  int? get truthCalories => photo.userCorrectedCalories;
  bool get hasTruth =>
      truthName != null || truthPrice != null || truthCalories != null;

  static String _norm(String s) =>
      s.replaceAll(RegExp(r'[\s　]'), '').toLowerCase();

  bool? get nameMatchesTruth {
    final t = truthName, n = name;
    if (t == null || n == null) return null;
    return _norm(t) == _norm(n);
  }
}

/// ベンチ全体の集計。件数(n)を必ず一緒に見ること。
class BenchReport {
  const BenchReport({
    required this.loadMs,
    required this.cases,
    this.variant = PromptVariant.current,
    this.sampling = SamplingVariant.current,
  });

  final int loadMs;
  final List<BenchCase> cases;

  /// どのプロンプトで走らせたか
  final PromptVariant variant;

  /// どのサンプリングで走らせたか
  final SamplingVariant sampling;

  List<BenchCase> get succeeded => cases.where((c) => c.ok).toList();
  int get parseFailedCount => cases.where((c) => c.parseFailed).length;
  int get errorCount => cases.where((c) => !c.ok && !c.parseFailed).length;
  int get nameChangedCount => succeeded.where((c) => c.nameChanged).length;

  /// 併記・推測が残っている件数(変更前 / 変更後)
  BenchPair get hedged => BenchPair(
        before: cases.where((c) => c.beforeHedged).length,
        after: succeeded.where((c) => c.afterHedged).length,
        total: succeeded.length,
      );

  /// 価格の散らばり(変更前 / 変更後)
  BenchSpread get priceSpread => BenchSpread(
        before: _spread(cases.map((c) => c.beforePrice)),
        after: _spread(succeeded.map((c) => c.price)),
      );

  /// カロリーの散らばり(変更前 / 変更後)
  BenchSpread get caloriesSpread => BenchSpread(
        before: _spread(cases.map((c) => c.beforeCalories)),
        after: _spread(succeeded.map((c) => c.calories)),
      );

  /// 正解ラベルがある記録での料理名一致(あれば)
  BenchPair get truthNameMatch {
    final judged =
        succeeded.map((c) => c.nameMatchesTruth).whereType<bool>().toList();
    return BenchPair(
      before: 0,
      after: judged.where((x) => x).length,
      total: judged.length,
    );
  }

  int get avgInferenceMs {
    final ok = succeeded.where((c) => c.inferenceMs > 0).toList();
    if (ok.isEmpty) return 0;
    return ok.map((c) => c.inferenceMs).reduce((a, b) => a + b) ~/ ok.length;
  }

  /// 0より大きい値だけを対象に「異なる値の数」と「最頻値の占有率」を出す。
  /// 同じ丸い数字を使い回していると、異なる値が少なく最頻値の割合が高くなる。
  static BenchSpreadStat _spread(Iterable<int?> values) {
    final v = values.whereType<int>().where((x) => x > 0).toList();
    if (v.isEmpty) return const BenchSpreadStat(0, 0, 0);
    final counts = <int, int>{};
    for (final x in v) {
      counts[x] = (counts[x] ?? 0) + 1;
    }
    final top = counts.values.reduce((a, b) => a > b ? a : b);
    return BenchSpreadStat(counts.length, v.length, top);
  }
}

/// 変更前後の件数比較
class BenchPair {
  const BenchPair(
      {required this.before, required this.after, required this.total});
  final int before;
  final int after;
  final int total;

  String get label =>
      total == 0 ? '—' : '$before件 → $after件 / $total件';
}

class BenchSpread {
  const BenchSpread({required this.before, required this.after});
  final BenchSpreadStat before;
  final BenchSpreadStat after;

  String get label => '${before.label} → ${after.label}';
}

class BenchSpreadStat {
  const BenchSpreadStat(this.distinct, this.n, this.topCount);
  final int distinct;
  final int n;
  final int topCount;

  /// 「異なる値/件数(最頻値の占有率)」
  String get label => n == 0
      ? '—'
      : '$distinct/$n (最頻${(topCount * 100 / n).round()}%)';
}
