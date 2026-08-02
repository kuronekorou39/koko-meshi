import 'package:flutter/material.dart';

import '../models/meal_photo.dart';
import '../services/app_settings_service.dart';
import '../services/device_capability.dart';
import '../services/gemma_download_manager.dart';
import '../services/gemma_ondevice_service.dart';
import 'photo_scrim.dart';

/// 一覧のカード/タイルに出す「その食事のAI解析の今」。
///
/// 以前は `aiStatus == 'pending'` をまとめて「AIが解析中」とし、スピナーを
/// 回していた。しかし pending は「順番待ち」でしかないため、
/// - AI解析オフ・端末内モデル未DLで永久に始まらない写真まで回り続ける
/// - 逆に本当に解析している最中(processing)は対象外なので表示が消え、
///   カードは終わったように見えるのに詳細を開くと「AI解析中です」
/// という取り違えが起きていた。状態ごとに出し分け、回すのは実際に
/// モデルが動かしている [analyzing] のときだけにする。
enum MealAiState {
  /// 出すものが無い(解析済み・スキップ・写真なし)
  none,

  /// いまモデルがこの食事の写真を解析している(processing)
  analyzing,

  /// 解析対象だが順番待ち(pending)。他の写真の解析やモデルのロード待ち
  queued,

  /// AI解析がオフなので始まらない
  aiOff,

  /// この端末では端末内AIが動かない(32bit端末)
  deviceUnsupported,

  /// 端末内AIモデルが未DLなので始まらない
  modelMissing,

  /// 解析に失敗して結果が出ていない
  failed,

  /// 解析はできたが答えが割れている。利用者に選んでほしい
  needsReview,
}

/// 写真群から表示すべき状態を決める。
///
/// [modelInstalled] は未確認だと null。始まらないと決めつけるのは
/// 確認が取れた(false)ときだけにし、null は順番待ち側に倒す
/// (確認が済めば [ValueListenable] 経由で描き直される)。
MealAiState resolveMealAiState(
  List<MealPhoto> photos, {
  required bool? modelInstalled,
}) {
  final waiting = photos
      .where((p) =>
          !p.skipAi && (p.aiStatus == 'pending' || p.aiStatus == 'processing'))
      .toList();

  if (waiting.isNotEmpty) {
    // 解析が始まらない条件は processing にも効かせる。アプリが解析中に
    // 落とされた写真は processing のまま残るため、ここを見ないと
    // 「モデルが無いのに回り続ける」が再発する
    if (AppSettings.aiMode == AiAnalysisMode.off) return MealAiState.aiOff;
    // モデルを落としても動かないので、未DLより先に伝える
    if (!DeviceCapability.onDeviceAi) return MealAiState.deviceUnsupported;
    if (modelInstalled == false) return MealAiState.modelMissing;
    return waiting.any((p) => p.aiStatus == 'processing')
        ? MealAiState.analyzing
        : MealAiState.queued;
  }

  if (photos.any((p) => p.aiStatus == 'failed')) return MealAiState.failed;
  // 解析は通ったが決めきれなかったもの。急かさないので失敗より後に見る
  if (photos.any((p) => p.needsNameReview)) return MealAiState.needsReview;
  return MealAiState.none;
}

/// AI解析の状態表示が要るか。呼び出し側が余白や区切りを組む前に、
/// [MealAiStatusLine] が何も描かないケースを判別するために使う。
/// これが true なら [resolveMealAiState] は [MealAiState.none] を返さない。
///
/// `unavailable`(写真の実体が失われている)は意図して対象外。利用者に
/// できることが何も無いのに一覧に警告を並べても仕方がないので、一覧では
/// 黙り、詳細画面でだけ事情を説明する。
bool hasMealAiStatus(List<MealPhoto> photos) => photos.any((p) =>
    p.aiStatus == 'failed' ||
    p.needsNameReview ||
    (!p.skipAi && (p.aiStatus == 'pending' || p.aiStatus == 'processing')));

/// 写真の上(スクリム内)に置くAI解析状態の表示。
///
/// 料理名がすでに出ている食事では記号だけを名前の後ろに添える
/// ([showLabel] = false)。複数枚のうち1枚だけ解析が終わった食事で
/// 表示が消えてしまわないようにするため。
class MealAiStatusLine extends StatelessWidget {
  const MealAiStatusLine({
    super.key,
    required this.photos,
    this.showLabel = true,
    this.compact = false,
  });

  final List<MealPhoto> photos;

  /// 文言を出すか(false なら記号のみ)
  final bool showLabel;

  /// グリッドタイル用の一回り小さい表示
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // 全部解析済みなら何も要らない。ここで抜けておくと、関係の無い食事の
    // カードから端末内モデルの状態を購読しにいかずに済む
    if (!hasMealAiStatus(photos)) return const SizedBox.shrink();

    return ValueListenableBuilder<bool?>(
      valueListenable:
          GemmaDownloadManager.instance.installedOf(GemmaModelKind.e2b),
      builder: (context, installed, _) {
        final state = resolveMealAiState(photos, modelInstalled: installed);
        if (state == MealAiState.none) return const SizedBox.shrink();
        return _line(state);
      },
    );
  }

  Widget _line(MealAiState state) {
    final color = state == MealAiState.failed
        ? PhotoScrim.errorTextColor
        : PhotoScrim.mutedTextColor;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _leading(state, color),
        if (showLabel) ...[
          SizedBox(width: compact ? 5 : 8),
          Flexible(
            child: Text(
              _label(state),
              style: TextStyle(
                fontSize: compact ? 11 : 12.5,
                color: color,
                shadows: PhotoScrim.textShadows,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }

  /// 回るのは実際に解析している間だけ。それ以外は静止した記号で表す
  Widget _leading(MealAiState state, Color color) {
    if (state == MealAiState.analyzing) {
      final size = compact ? 9.0 : 10.0;
      return SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
      );
    }
    return Icon(
      _icon(state),
      size: compact ? 11 : 12.5,
      color: color,
      shadows: PhotoScrim.textShadows,
    );
  }

  IconData _icon(MealAiState state) => switch (state) {
        MealAiState.queued => Icons.schedule,
        MealAiState.aiOff => Icons.smart_toy_outlined,
        MealAiState.deviceUnsupported => Icons.phonelink_off,
        MealAiState.modelMissing => Icons.download_for_offline_outlined,
        MealAiState.failed => Icons.error_outline,
        MealAiState.needsReview => Icons.help_outline,
        // analyzing はスピナー、none はここへ来ない
        _ => Icons.smart_toy_outlined,
      };

  String _label(MealAiState state) => switch (state) {
        MealAiState.analyzing => 'AIが解析中',
        MealAiState.queued => 'AI解析の順番待ち',
        MealAiState.aiOff => 'AI解析はオフ',
        MealAiState.deviceUnsupported => 'この端末はAI解析に非対応',
        MealAiState.modelMissing => 'AIモデル未ダウンロード',
        MealAiState.failed => 'AI解析に失敗',
        MealAiState.needsReview => '候補から選べます',
        MealAiState.none => '',
      };
}
