import 'dart:io';
import 'package:flutter/material.dart';

import '../config/constants.dart';
import '../services/photo_cache_service.dart';
import '../theme/app_theme.dart';

/// 写真表示ウィジェット（ローカル→サムネ→クラウドの順でフォールバック）。
///
/// 原本は3〜8MBあり、読んで展開するだけで時間がかかる。一覧のように小さく
/// たくさん並べる場所では [fullQuality] を false にして、撮影時に作ってある
/// サムネイルを出す。カード幅がサムネイルより大きい場所では [sharpen] を
/// 足すと、まずサムネイルを出しておき、表示サイズに縮めて展開した原本が
/// 用意できたら上に重ねる(待たせず、かつ荒く見せない)。
class CachedPhotoImage extends StatefulWidget {
  final String? localPath;
  final String? thumbnailPath;
  final String? originalUrl;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// 原本を出すか。false ならサムネイルを優先する
  final bool fullQuality;

  /// サムネイルを出したあと、表示サイズに合わせた原本へ差し替えるか。
  /// [fullQuality] が false のときだけ意味を持つ
  final bool sharpen;

  const CachedPhotoImage({
    super.key,
    this.localPath,
    this.thumbnailPath,
    this.originalUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.fullQuality = true,
    this.sharpen = false,
  });

  @override
  State<CachedPhotoImage> createState() => _CachedPhotoImageState();
}

class _CachedPhotoImageState extends State<CachedPhotoImage> {
  /// 端末内にある原本・サムネイル(無ければ null)
  String? _original;
  String? _thumbnail;

  /// 旧クラウド同期の写真を取りに行っている間だけ true
  bool _downloading = false;

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
        oldWidget.originalUrl != widget.originalUrl) {
      _resolve();
    }
  }

  /// 端末内のファイルはその場で確かめる。非同期を挟むと、スクロールで現れる
  /// たびに1フレームぶん読み込み中の表示が出てしまう。
  void _resolve() {
    _original = _existing(widget.localPath);
    _thumbnail = _existing(widget.thumbnailPath);
    _downloading = false;

    final url = widget.originalUrl;
    if (_original == null && url != null && url.isNotEmpty) {
      _downloading = _thumbnail == null;
      _fetchRemote();
    }
  }

  static String? _existing(String? path) =>
      path != null && File(path).existsSync() ? path : null;

  Future<void> _fetchRemote() async {
    final localPath = widget.localPath;
    final url = widget.originalUrl;
    final path = await PhotoCacheService.getOriginalPath(
      localPath: localPath,
      originalUrl: url,
    );
    // 待っている間に別の写真へ差し替わっていたら捨てる
    if (!mounted ||
        widget.localPath != localPath ||
        widget.originalUrl != url) {
      return;
    }
    setState(() {
      _original = path;
      _downloading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);

    if (_downloading) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: tokens.photoPlaceholder,
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final original = _original;
    final thumbnail = _thumbnail;

    if (original == null && thumbnail == null) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: tokens.photoPlaceholder,
        child: Center(
          child: Icon(Icons.broken_image_outlined, color: tokens.textFaint),
        ),
      );
    }

    if (widget.fullQuality || thumbnail == null) {
      return _file(original ?? thumbnail!);
    }
    if (!widget.sharpen || original == null) return _file(thumbnail);

    return LayoutBuilder(
      builder: (context, constraints) {
        final logicalWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : (widget.width ?? 0);
        final pixelWidth =
            (logicalWidth * MediaQuery.devicePixelRatioOf(context)).round();
        // サムネイルで足りる大きさなら原本は読まない
        if (pixelWidth <= AppConstants.thumbnailMaxWidth) {
          return _file(thumbnail);
        }
        return Stack(
          fit: StackFit.passthrough,
          children: [
            _file(thumbnail),
            Positioned.fill(
              child: Image(
                image: ResizeImage(
                  FileImage(File(original)),
                  width: pixelWidth,
                ),
                fit: widget.fit,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, wasSync) {
                  if (wasSync) return child;
                  return AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 150),
                    child: child,
                  );
                },
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _file(String path) {
    return Image.file(
      File(path),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
    );
  }
}
