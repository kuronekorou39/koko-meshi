import 'package:flutter/material.dart';

import '../../models/meal_photo.dart';
import '../../services/ai_analysis_service.dart';
import '../../theme/app_theme.dart';

/// 再解析の指示。[hint] が null ならキーワードなしで再解析する。
class ReanalyzeRequest {
  const ReanalyzeRequest(this.hint);

  final String? hint;
}

/// キーワード付き再解析の確認ダイアログを開く。
/// 実行なら [ReanalyzeRequest]、キャンセル/画面外タップなら null を返す。
Future<ReanalyzeRequest?> showReanalyzeDialog(
  BuildContext context,
  MealPhoto photo,
) {
  return showDialog<ReanalyzeRequest>(
    context: context,
    builder: (_) => _ReanalyzeDialog(photo: photo),
  );
}

/// TextEditingController はこの State が所有する。`await showDialog()` の直後に
/// dispose すると、閉じるアニメーション中の TextField から参照されて
/// 「A TextEditingController was used after being disposed」で落ちる。
/// State.dispose はルートが完全に取り除かれた後に呼ばれるので安全。
class _ReanalyzeDialog extends StatefulWidget {
  const _ReanalyzeDialog({required this.photo});

  final MealPhoto photo;

  @override
  State<_ReanalyzeDialog> createState() => _ReanalyzeDialogState();
}

class _ReanalyzeDialogState extends State<_ReanalyzeDialog> {
  late final TextEditingController _hint;

  @override
  void initState() {
    super.initState();
    _hint = TextEditingController(text: widget.photo.aiHint ?? '');
  }

  @override
  void dispose() {
    _hint.dispose();
    super.dispose();
  }

  void _submit() {
    final hint = _hint.text.trim();
    Navigator.pop(context, ReanalyzeRequest(hint.isEmpty ? null : hint));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);
    final photo = widget.photo;
    final hasCorrections = photo.userCorrectedName != null ||
        photo.userCorrectedPrice != null ||
        photo.userCorrectedCalories != null;

    return AlertDialog(
      // キーボードを出したときに内容がはみ出さないようにする
      scrollable: true,
      title: const Text('AIで再解析'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'この写真をもう一度AIで解析します。うまく認識されないときは、'
            '料理のキーワードを入力すると特定の手がかりになります。',
            style: TextStyle(fontSize: 13.5),
          ),
          const SizedBox(height: 16),
          // 手がかりを複数書けるよう複数行にする。改行で区切った各行は
          // プロンプトへ箇条書きとして渡される
          TextField(
            controller: _hint,
            minLines: 2,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            // 長文を入れるとコンテキスト窓から本来の指示が押し出されて
            // 解析が失敗する
            maxLength: AiAnalysisService.maxHintLength,
            decoration: const InputDecoration(
              labelText: 'キーワード（任意）',
              hintText: '例: ラーメン、豚骨',
              // 複数行のときラベルを上端に合わせる(既定は上下中央)
              alignLabelWithHint: true,
            ),
          ),
          if (hasCorrections)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '手動修正した内容は消えます',
                style: TextStyle(fontSize: 12, color: tokens.textFaint),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('再解析'),
        ),
      ],
    );
  }
}
