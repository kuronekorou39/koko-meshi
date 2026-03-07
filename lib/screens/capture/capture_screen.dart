import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../database/local_database.dart';
import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../models/meal_type.dart';
import '../../providers/meal_providers.dart';
import '../../services/photo_service.dart';

class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({super.key});

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen> {
  static const _uuid = Uuid();
  MealType _selectedType = MealType.eatingOut;
  final List<XFile> _selectedPhotos = [];
  bool _saving = false;

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
            // 写真表示エリア
            Expanded(
              child: _selectedPhotos.isEmpty
                  ? _buildPhotoPlaceholder()
                  : _buildPhotoGrid(),
            ),
            const SizedBox(height: 12),

            // 写真追加ボタン
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _takePhoto,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('撮影'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickFromLibrary,
                    icon: const Icon(Icons.photo_library),
                    label: const Text('ライブラリ'),
                  ),
                ),
              ],
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
              onPressed: _selectedPhotos.isEmpty || _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(_saving ? '保存中...' : '保存'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotoPlaceholder() {
    return GestureDetector(
      onTap: _showPickerChoice,
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
    );
  }

  Widget _buildPhotoGrid() {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _selectedPhotos.length,
      itemBuilder: (context, index) {
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(_selectedPhotos[index].path),
                fit: BoxFit.cover,
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                onTap: () {
                  setState(() => _selectedPhotos.removeAt(index));
                },
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(4),
                  child: const Icon(Icons.close, size: 16, color: Colors.white),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showPickerChoice() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('カメラで撮影'),
              onTap: () {
                Navigator.pop(context);
                _takePhoto();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('ライブラリから選択'),
              onTap: () {
                Navigator.pop(context);
                _pickFromLibrary();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _takePhoto() async {
    final photo = await PhotoService.takePhoto();
    if (photo != null) {
      setState(() => _selectedPhotos.add(photo));
    }
  }

  Future<void> _pickFromLibrary() async {
    final photos = await PhotoService.pickPhotos();
    if (photos.isNotEmpty) {
      setState(() => _selectedPhotos.addAll(photos));
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    try {
      final now = DateTime.now();
      final mealLogId = _uuid.v4();

      // 食事記録を作成
      final mealLog = MealLog(
        id: mealLogId,
        mealType: _selectedType,
        eatenAt: now,
        createdAt: now,
      );
      await LocalDatabase.insertMealLog(mealLog);

      // 写真を保存
      for (final xFile in _selectedPhotos) {
        final localPath = await PhotoService.saveToLocal(xFile);
        final thumbnailPath = await PhotoService.generateThumbnail(localPath);

        final photo = MealPhoto(
          id: _uuid.v4(),
          mealLogId: mealLogId,
          localPath: localPath,
          thumbnailUrl: thumbnailPath,
          shotAt: now,
          createdAt: now,
        );
        await LocalDatabase.insertMealPhoto(photo);
      }

      // 一覧を更新
      ref.read(mealLogsProvider.notifier).refresh();

      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
