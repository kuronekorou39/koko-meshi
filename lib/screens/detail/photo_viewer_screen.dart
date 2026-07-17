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
  /// 写真上に重ねるUIの下地（黒地の画面専用）
  static const _overlayColor = Colors.black54;

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

  ButtonStyle get _overlayButtonStyle => IconButton.styleFrom(
        backgroundColor: _overlayColor,
        foregroundColor: Colors.white,
      );

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_currentIndex];
    final hasMultiple = widget.photos.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _showUI
          ? AppBar(
              backgroundColor: Colors.transparent,
              foregroundColor: Colors.white,
              centerTitle: true,
              leading: Center(
                child: IconButton(
                  style: _overlayButtonStyle,
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: '閉じる',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              // ページインジケータ
              title: hasMultiple
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: _overlayColor,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${_currentIndex + 1} / ${widget.photos.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    )
                  : null,
              actions: [
                if (_downloading)
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: const BoxDecoration(
                      color: _overlayColor,
                      shape: BoxShape.circle,
                    ),
                    child: const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: IconButton(
                      style: _overlayButtonStyle,
                      icon: const Icon(Icons.download_outlined, size: 20),
                      tooltip: 'カメラロールに保存',
                      onPressed: _downloadPhoto,
                    ),
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
      // 下部バー: メニュー名
      bottomNavigationBar: _showUI && photo.displayName != null
          ? SafeArea(
              top: false,
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: _overlayColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  photo.displayName!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.broken_image_outlined,
              color: Colors.white.withValues(alpha: 0.4),
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              '写真を読み込めません',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
          ],
        ),
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
