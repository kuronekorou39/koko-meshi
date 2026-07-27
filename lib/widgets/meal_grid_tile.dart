import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../models/meal_type.dart';
import '../theme/app_theme.dart';
import '../theme/meal_type_style.dart';
import 'cached_photo_image.dart';
import 'meal_ai_status.dart';
import 'photo_scrim.dart';

/// グリッド表示用タイル: 写真をタイル全面に敷き、下部スクリムの上に
/// メニュー名と種別アイコンつき日時を載せる。
/// スクリムは中身の高さに追従するので、フォントスケールを拡大しても
/// テキストが暗い下地から外れない。余白(タイル間)は呼び出し側で付ける。
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
    final tokens = KokoTokens.of(context);

    return Container(
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.hairline, width: 0.8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildPhoto(tokens),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: PhotoScrim(
                padding: const EdgeInsets.fromLTRB(10, 26, 10, 9),
                child: _buildInfo(context, tokens),
              ),
            ),
            // タップ時のリップルを写真の上にも出す
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(onTap: onTap),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfo(BuildContext context, KokoTokens tokens) {
    final menuNames = photos
        .where((p) => p.displayName != null)
        .map((p) => p.displayName!)
        .join('、');
    final hasStatus = hasMealAiStatus(photos);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (menuNames.isNotEmpty) ...[
          Row(
            children: [
              Flexible(
                child: Text(
                  menuNames,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                    color: PhotoScrim.textColor,
                    shadows: PhotoScrim.textShadows,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (hasStatus) ...[
                const SizedBox(width: 6),
                MealAiStatusLine(
                    photos: photos, showLabel: false, compact: true),
              ],
            ],
          ),
          const SizedBox(height: 2),
        ] else if (hasStatus) ...[
          // 一覧では解析の状態しか手がかりが無いので、名前が無い間も出す
          MealAiStatusLine(photos: photos, compact: true),
          const SizedBox(height: 2),
        ],
        // 種別(未設定なら省く) + 日時
        Row(
          children: [
            if (mealLog.mealType != MealType.unset) ...[
              Icon(
                mealLog.mealType.icon,
                size: 12,
                color: mealLog.mealType.fgOnPhoto,
                shadows: PhotoScrim.textShadows,
              ),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(
                DateFormat('M/d HH:mm').format(mealLog.eatenAt),
                style: tokens.numeral.copyWith(
                  fontSize: 11.5,
                  color: PhotoScrim.mutedTextColor,
                  shadows: PhotoScrim.textShadows,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
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
