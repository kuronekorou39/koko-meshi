import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/meal_log.dart';
import '../models/meal_photo.dart';
import '../models/meal_type.dart';
import 'cached_photo_image.dart';

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
    return GestureDetector(
      onTap: onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 写真
            Expanded(child: _buildPhoto()),
            // 情報
            Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // メニュー名
                  if (photos.any((p) => p.displayName != null))
                    Text(
                      photos
                          .where((p) => p.displayName != null)
                          .map((p) => p.displayName!)
                          .join('、'),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 2),
                  // 種別 + 日付
                  Row(
                    children: [
                      Icon(
                        _mealTypeIcon(mealLog.mealType),
                        size: 12,
                        color: Colors.grey[500],
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(
                          DateFormat('M/d HH:mm', 'ja').format(mealLog.eatenAt),
                          style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhoto() {
    if (photos.isEmpty) {
      return Container(
        color: Colors.grey[200],
        child: const Icon(Icons.restaurant, color: Colors.grey),
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

  IconData _mealTypeIcon(MealType mealType) {
    return switch (mealType) {
      MealType.unset => Icons.help_outline,
      MealType.eatingOut => Icons.store,
      MealType.homeCooking => Icons.home,
      MealType.takeout => Icons.shopping_bag,
      MealType.delivery => Icons.delivery_dining,
      MealType.snack => Icons.coffee,
      MealType.other => Icons.restaurant,
    };
  }
}
