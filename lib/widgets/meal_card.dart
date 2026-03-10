import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../models/meal_type.dart';
import 'cached_photo_image.dart';

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
    final dateFormat = DateFormat('M/d (E) HH:mm', 'ja');
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 写真サムネイル
            if (photos.isNotEmpty)
              SizedBox(
                height: 180,
                child: photos.length == 1
                    ? _buildSinglePhoto(photos.first)
                    : _buildPhotoRow(),
              ),

            // 情報
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 日付 + 食事種別
                  Row(
                    children: [
                      Icon(
                        _mealTypeIcon(mealLog.mealType),
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        mealLog.mealType.label,
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        dateFormat.format(mealLog.eatenAt),
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  // メニュー名（AI解析結果があれば）
                  if (photos.any((p) => p.displayName != null))
                    Text(
                      photos
                          .where((p) => p.displayName != null)
                          .map((p) => p.displayName!)
                          .join('、'),
                      style: const TextStyle(fontSize: 15),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    )
                  else if (photos.any((p) => p.aiStatus == 'pending'))
                    Text(
                      '解析待ち...',
                      style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 14,
                      ),
                    ),

                  // 価格（あれば）
                  if (mealLog.totalPrice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '¥${NumberFormat('#,###').format(mealLog.totalPrice)}',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[700],
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

  Widget _buildSinglePhoto(MealPhoto photo) {
    return SizedBox(
      width: double.infinity,
      child: _photoImage(photo),
    );
  }

  Widget _buildPhotoRow() {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      itemCount: photos.length,
      itemBuilder: (context, index) {
        return AspectRatio(
          aspectRatio: 1,
          child: _photoImage(photos[index]),
        );
      },
    );
  }

  Widget _photoImage(MealPhoto photo) {
    return CachedPhotoImage(
      localPath: photo.localPath,
      thumbnailPath: photo.thumbnailUrl,
      originalUrl: photo.originalUrl,
    );
  }

  IconData _mealTypeIcon(MealType mealType) {
    return switch (mealType) {
      MealType.eatingOut => Icons.store,
      MealType.homeCooking => Icons.home,
      MealType.delivery => Icons.delivery_dining,
    };
  }
}
