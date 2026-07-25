import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../models/meal_type.dart';
import '../theme/app_theme.dart';
import '../theme/meal_type_style.dart';
import 'cached_photo_image.dart';
import 'photo_scrim.dart';

/// タイムラインの食事カード。
/// 写真をカード全面に敷き、下部にスクリムを重ねてその上に情報を載せる。
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
    final tokens = KokoTokens.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        // 情報を写真の中に収めた分、従来(写真180 + 情報部)とほぼ同じ
        // スクロール密度になる縦横比
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildPhotoLayer(context, tokens),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: PhotoScrim(
                  padding: const EdgeInsets.fromLTRB(14, 32, 14, 12),
                  child: _buildInfo(context),
                ),
              ),
              if (mealLog.mealType != MealType.unset)
                Positioned(
                  top: 10,
                  left: 10,
                  child: MealTypeChip(mealType: mealLog.mealType, onPhoto: true),
                ),
              // クラスタに載りきらない残り枚数
              if (photos.length > 3)
                Positioned(
                  top: 10,
                  right: 10,
                  child: _photoCountBadge(context, photos.length - 3),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// スクリム上に載せる情報(メニュー名 / 価格・カロリー / 時刻)
  Widget _buildInfo(BuildContext context) {
    final tokens = KokoTokens.of(context);

    final menuNames = photos
        .where((p) => p.displayName != null)
        .map((p) => p.displayName!)
        .join('、');
    final isAnalyzing =
        menuNames.isEmpty && photos.any((p) => p.aiStatus == 'pending');
    final metaText = _buildMetaText();

    final children = <Widget>[];
    if (menuNames.isNotEmpty) {
      children.add(
        Text(
          menuNames,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            height: 1.3,
            color: PhotoScrim.textColor,
            shadows: PhotoScrim.textShadows,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    } else if (isAnalyzing) {
      children.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: PhotoScrim.mutedTextColor,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'AIが解析中',
              style: TextStyle(
                fontSize: 12.5,
                color: PhotoScrim.mutedTextColor,
                shadows: PhotoScrim.textShadows,
              ),
            ),
          ],
        ),
      );
    }
    if (children.isNotEmpty) children.add(const SizedBox(height: 6));

    children.add(
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: metaText == null
                ? const SizedBox.shrink()
                : Text(
                    metaText,
                    style: tokens.numeral.copyWith(
                      fontSize: 13,
                      color: PhotoScrim.mutedTextColor,
                      shadows: PhotoScrim.textShadows,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          const SizedBox(width: 8),
          Text(
            DateFormat('HH:mm').format(mealLog.eatenAt),
            style: tokens.numeral.copyWith(
              fontSize: 12.5,
              color: PhotoScrim.mutedTextColor,
              shadows: PhotoScrim.textShadows,
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
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

  Widget _buildPhotoLayer(BuildContext context, KokoTokens tokens) {
    if (photos.isEmpty) {
      return ColoredBox(
        color: tokens.photoPlaceholder,
        child: Center(
          child: Icon(Icons.restaurant_outlined, color: tokens.textFaint),
        ),
      );
    }
    return photos.length == 1
        ? _photoImage(photos.first)
        : _buildPhotoCluster(context);
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
                    Expanded(child: _photoImage(photos[2])),
                  ],
                ),
        ),
      ],
    );
  }

  /// 4枚以上のときに右上へ出す「+N」バッジ。
  /// 情報を下部スクリムへ集約したので、写真の中央には重ねない。
  Widget _photoCountBadge(BuildContext context, int rest) {
    final tokens = KokoTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '+$rest',
        style: tokens.numeral.copyWith(
          fontSize: 11.5,
          color: PhotoScrim.textColor,
        ),
      ),
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
