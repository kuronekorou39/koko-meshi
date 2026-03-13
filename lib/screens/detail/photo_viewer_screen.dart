import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

import '../../models/meal_photo.dart';
import '../../services/photo_cache_service.dart';

class PhotoViewerScreen extends StatefulWidget {
  final List<MealPhoto> photos;
  final int initialIndex;

  const PhotoViewerScreen({
    super.key,
    required this.photos,
    this.initialIndex = 0,
  });

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late PageController _pageController;
  late int _currentIndex;
  bool _showUI = true;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _downloadPhoto() async {
    final photo = widget.photos[_currentIndex];
    setState(() => _downloading = true);

    try {
      // フル画質のパスを取得（クラウドからDLも含む）
      final path = await PhotoCacheService.getDisplayPath(
        localPath: photo.localPath,
        thumbnailPath: photo.thumbnailUrl,
        originalUrl: photo.originalUrl,
        fullQuality: true,
      );

      if (path == null || !File(path).existsSync()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('写真が見つかりません')),
          );
        }
        return;
      }

      // カメラロールに保存
      await Gal.putImage(path, album: 'ココメシ');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('カメラロールに保存しました')),
        );
      }
    } on GalException catch (e) {
      if (mounted) {
        final message = e.type == GalExceptionType.accessDenied
            ? 'ギャラリーへのアクセスが許可されていません'
            : '保存に失敗しました';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存に失敗: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _toggleUI() {
    setState(() => _showUI = !_showUI);
    SystemChrome.setEnabledSystemUIMode(
      _showUI ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_currentIndex];
    final hasMultiple = widget.photos.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _showUI
          ? AppBar(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.white,
              title: hasMultiple
                  ? Text('${_currentIndex + 1} / ${widget.photos.length}')
                  : null,
              actions: [
                if (_downloading)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 24, height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.download),
                    tooltip: 'カメラロールに保存',
                    onPressed: _downloadPhoto,
                  ),
              ],
            )
          : null,
      body: GestureDetector(
        onTap: _toggleUI,
        child: PageView.builder(
          controller: _pageController,
          itemCount: widget.photos.length,
          onPageChanged: (index) => setState(() => _currentIndex = index),
          itemBuilder: (context, index) {
            return _PhotoPage(photo: widget.photos[index]);
          },
        ),
      ),
      bottomNavigationBar: _showUI && photo.displayName != null
          ? Container(
              color: Colors.black54,
              padding: EdgeInsets.fromLTRB(
                16, 12, 16, MediaQuery.of(context).padding.bottom + 12,
              ),
              child: Text(
                photo.displayName!,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            )
          : null,
    );
  }
}

class _PhotoPage extends StatefulWidget {
  final MealPhoto photo;

  const _PhotoPage({required this.photo});

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage> {
  String? _path;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPhoto();
  }

  Future<void> _loadPhoto() async {
    final path = await PhotoCacheService.getDisplayPath(
      localPath: widget.photo.localPath,
      thumbnailPath: widget.photo.thumbnailUrl,
      originalUrl: widget.photo.originalUrl,
      fullQuality: true,
    );
    if (mounted) {
      setState(() {
        _path = path;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (_path == null || !File(_path!).existsSync()) {
      return const Center(
        child: Icon(Icons.broken_image, color: Colors.grey, size: 64),
      );
    }

    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4.0,
      child: Center(
        child: Image.file(
          File(_path!),
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
