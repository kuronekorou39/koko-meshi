import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../theme/app_theme.dart';
import '../theme/meal_type_style.dart';
import 'cached_photo_image.dart';

/// グリッド表示用タイル: 写真 + メニュー名 + 種別アイコンつき日時。
/// 写真側をExpandedにしてあり、フォントスケール拡大時は写真が縮んで
/// テキストは切れない。余白(タイル間)は呼び出し側のグリッドで付ける。
class MealGridTile extends StatelessWidget {
  final MealLog mealLog;
  final List<MealPhoto> photos;
  final VoidCallback? onTap;

  const MealGridTile({
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

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 写真(残り高さいっぱい)
            Expanded(
              child: Container(
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: tokens.hairline, width: 0.8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _buildPhoto(tokens),
                ),
              ),
            ),
            const SizedBox(height: 6),
            if (menuNames.isNotEmpty) ...[
              Text(
                menuNames,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
            ],
            // 種別 + 日時(常に表示)
            Row(
              children: [
                Icon(
                  mealLog.mealType.icon,
                  size: 12,
                  color: mealLog.mealType.fg(context),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    DateFormat('M/d HH:mm').format(mealLog.eatenAt),
                    style: tokens.numeral.copyWith(
                      fontSize: 11.5,
                      color: tokens.textFaint,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
        // タップ時のリップルを写真の上にも出す
        Positioned.fill(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPhoto(KokoTokens tokens) {
    if (photos.isEmpty) {
      return Container(
        color: tokens.photoPlaceholder,
        child: Icon(Icons.restaurant_outlined, color: tokens.textFaint),
      );
    }

    final photo = photos.first;
    return CachedPhotoImage(
      localPath: photo.localPath,
      thumbnailPath: photo.thumbnailUrl,
      originalUrl: photo.originalUrl,
      fit: BoxFit.cover,
    );
  }
}
