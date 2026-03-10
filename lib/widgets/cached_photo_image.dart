import 'dart:io';
import 'package:flutter/material.dart';

import '../services/photo_cache_service.dart';

/// 写真表示ウィジェット（ローカル→サムネ→クラウドの順でフォールバック）
class CachedPhotoImage extends StatefulWidget {
  final String? localPath;
  final String? thumbnailPath;
  final String? originalUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final bool fullQuality;

  const CachedPhotoImage({
    super.key,
    this.localPath,
    this.thumbnailPath,
    this.originalUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.fullQuality = false,
  });

  @override
  State<CachedPhotoImage> createState() => _CachedPhotoImageState();
}

class _CachedPhotoImageState extends State<CachedPhotoImage> {
  String? _resolvedPath;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(CachedPhotoImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.localPath != widget.localPath ||
        oldWidget.thumbnailPath != widget.thumbnailPath ||
        oldWidget.originalUrl != widget.originalUrl ||
        oldWidget.fullQuality != widget.fullQuality) {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    setState(() => _loading = true);
    final path = await PhotoCacheService.getDisplayPath(
      localPath: widget.localPath,
      thumbnailPath: widget.thumbnailPath,
      originalUrl: widget.originalUrl,
      fullQuality: widget.fullQuality,
    );
    if (mounted) {
      setState(() {
        _resolvedPath = path;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: const Center(
          child: SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_resolvedPath == null || !File(_resolvedPath!).existsSync()) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: Colors.grey[300],
        child: const Center(
          child: Icon(Icons.broken_image, color: Colors.grey),
        ),
      );
    }

    return Image.file(
      File(_resolvedPath!),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
    );
  }
}
