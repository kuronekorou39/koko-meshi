import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/meal_type.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  MealType _selectedType = MealType.eatingOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('食事を記録'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 写真選択エリア
            Expanded(
              child: GestureDetector(
                onTap: _pickImage,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey[400]!),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_a_photo, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        'タップして写真を撮影・選択',
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 食事種別選択
            SegmentedButton<MealType>(
              segments: MealType.values
                  .map((type) => ButtonSegment(
                        value: type,
                        label: Text(type.label),
                      ))
                  .toList(),
              selected: {_selectedType},
              onSelectionChanged: (selected) {
                setState(() => _selectedType = selected.first);
              },
            ),
            const SizedBox(height: 16),

            // 保存ボタン
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check),
              label: const Text('保存'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _pickImage() {
    // TODO: image_picker で写真を撮影/選択
  }

  void _save() {
    // TODO: ローカルDBに保存 → キューに追加
    context.pop();
  }
}
