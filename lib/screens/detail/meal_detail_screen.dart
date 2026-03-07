import 'package:flutter/material.dart';

class MealDetailScreen extends StatelessWidget {
  final String mealLogId;

  const MealDetailScreen({super.key, required this.mealLogId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('食事の詳細'),
      ),
      body: Center(
        child: Text('食事記録: $mealLogId'),
        // TODO: 写真一覧、AI推定結果、手動編集、ダウンロード
      ),
    );
  }
}
