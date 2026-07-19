import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../models/meal_type.dart';
import '../theme/app_theme.dart';
import '../theme/meal_type_style.dart';
import 'cached_photo_image.dart';

/// タイムラインの食事カード。
/// 写真を上部フルブリードで主役に置き、情報部は罫線調で一歩引かせる。
/// 余白(外側マージン)は呼び出し側で付ける。
class MealCard extends StatelessWidget {
  final MealLog mealLog;
  final List<MealPhoto> photos;
  final VoidCallback? onTap;

  const MealCard({
    super.key,
    required this.mealLog,
    required this.photos,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);

    final menuNames = photos
        .where((p) => p.displayName != null)
        .map((p) => p.displayName!)
        .join('、');
    final isAnalyzing =
        menuNames.isEmpty && photos.any((p) => p.aiStatus == 'pending');
    final metaText = _buildMetaText();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 写真(フルブリード)
            if (photos.isNotEmpty)
              SizedBox(
                height: 180,
                width: double.infinity,
                child: photos.length == 1
                    ? _photoImage(photos.first)
                    : _buildPhotoCluster(context),
              ),

            // 情報部
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 食事種別チップ + 時刻(未設定のときはチップを出さず時刻のみ)
                  Row(
                    children: [
                      if (mealLog.mealType != MealType.unset)
                        MealTypeChip(mealType: mealLog.mealType),
                      const Spacer(),
                      Text(
                        DateFormat('HH:mm').format(mealLog.eatenAt),
                        style: tokens.numeral.copyWith(
                          fontSize: 12.5,
                          color: tokens.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // メニュー名 / 解析中表示
                  if (menuNames.isNotEmpty)
                    Text(
                      menuNames,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    )
                  else if (isAnalyzing)
                    Row(
                      children: [
                        SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: tokens.textFaint,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'AIが解析中',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: tokens.textFaint,
                          ),
                        ),
                      ],
                    ),

                  // 価格・カロリー
                  if (metaText != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        metaText,
                        style: tokens.numeral.copyWith(
                          fontSize: 13,
                          color: tokens.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「¥1,280 ・ 650kcal」。どちらも無ければ null。
  String? _buildMetaText() {
    final parts = <String>[];
    if (mealLog.totalPrice != null) {
      parts.add('¥${NumberFormat('#,###').format(mealLog.totalPrice)}');
    }
    if (photos.any((p) => p.displayCalories != null)) {
      final total =
          photos.fold<int>(0, (sum, p) => sum + (p.displayCalories ?? 0));
      parts.add('${NumberFormat('#,###').format(total)}kcal');
    }
    return parts.isEmpty ? null : parts.join(' ・ ');
  }

  /// 複数枚: 1枚目を大きく、残りを右側に縦2分割で見せる。
  Widget _buildPhotoCluster(BuildContext context) {
    return Row(
      children: [
        Expanded(flex: 2, child: _photoImage(photos[0])),
        const SizedBox(width: 2),
        Expanded(
          child: photos.length == 2
              ? _photoImage(photos[1])
              : Column(
                  children: [
                    Expanded(child: _photoImage(photos[1])),
                    const SizedBox(height: 2),
                    Expanded(
                      child: photos.length == 3
                          ? _photoImage(photos[2])
                          : _overflowPhoto(context),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  /// 4枚以上のとき、最後のタイルに残り枚数を重ねる。
  Widget _overflowPhoto(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = KokoTokens.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        _photoImage(photos[2]),
        ColoredBox(color: theme.colorScheme.scrim.withValues(alpha: 0.4)),
        Center(
          child: Text(
            '+${photos.length - 3}',
            style: tokens.numeral.copyWith(
              fontSize: 16,
              // 写真スクリム上に重ねるためテーマ非依存の白
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _photoImage(MealPhoto photo) {
    return CachedPhotoImage(
      localPath: photo.localPath,
      thumbnailPath: photo.thumbnailUrl,
      originalUrl: photo.originalUrl,
    );
  }
}
