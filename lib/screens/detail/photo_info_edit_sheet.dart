import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/meal_photo.dart';
import '../../theme/app_theme.dart';

/// 編集シートの結果。null のフィールドは「ユーザー修正なし(AIの推定値に戻す)」。
class PhotoInfoEdit {
  const PhotoInfoEdit({this.name, this.price, this.calories});

  final String? name;
  final int? price;
  final int? calories;
}

/// メニュー情報(名前/価格/カロリー)の編集シートを開く。
/// 保存されたら [PhotoInfoEdit]、キャンセル/スワイプで閉じたら null を返す。
Future<PhotoInfoEdit?> showPhotoInfoEditSheet(
  BuildContext context,
  MealPhoto photo,
) {
  return showModalBottomSheet<PhotoInfoEdit>(
    context: context,
    // キーボードを出すと高さが変わるので上限を外す
    isScrollControlled: true,
    builder: (_) => _PhotoInfoEditSheet(photo: photo),
  );
}

/// 入力欄をボトムシートにしているのは、キーボードを出したときに
/// AlertDialogだと入力欄が隠れる/はみ出すため。
///
/// TextEditingController はこの State が所有する。`await showDialog()` の
/// 直後に dispose すると、閉じるアニメーション中の TextField から参照されて
/// 「A TextEditingController was used after being disposed」で落ちる。
/// State.dispose はルートが完全に取り除かれた後に呼ばれるので安全。
class _PhotoInfoEditSheet extends StatefulWidget {
  const _PhotoInfoEditSheet({required this.photo});

  final MealPhoto photo;

  @override
  State<_PhotoInfoEditSheet> createState() => _PhotoInfoEditSheetState();
}

class _PhotoInfoEditSheetState extends State<_PhotoInfoEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _price;
  late final TextEditingController _calories;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.photo.displayName ?? '');
    _price = TextEditingController(
      text: widget.photo.displayPrice?.toString() ?? '',
    );
    _calories = TextEditingController(
      text: widget.photo.displayCalories?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _calories.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    Navigator.pop(
      context,
      PhotoInfoEdit(
        name: name.isEmpty ? null : name,
        price: int.tryParse(_price.text.trim()),
        calories: int.tryParse(_calories.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);

    return Padding(
      // キーボードの高さぶん持ち上げて入力欄を隠さない
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'メニュー情報を編集',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                '空欄にするとAIの推定値に戻ります。',
                style: TextStyle(fontSize: 12, color: tokens.textMuted),
              ),
              const SizedBox(height: 20),
              // AIのタイトルは長くなりがちなので折り返して見せる。
              // 1行だと横スクロールになって全体を読めない
              TextField(
                controller: _name,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'メニュー名',
                  hintText: '例: 味噌ラーメン',
                  // 複数行のときラベルを上端に合わせる(既定は上下中央)
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _price,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: tokens.numeral.copyWith(fontSize: 16),
                      decoration: const InputDecoration(
                        labelText: '価格',
                        prefixText: '¥ ',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _calories,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: tokens.numeral.copyWith(fontSize: 16),
                      onSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(
                        labelText: 'カロリー',
                        suffixText: 'kcal',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('キャンセル'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _submit,
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
