import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../database/local_database.dart';
import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../models/meal_type.dart';
import '../../models/saved_place.dart';
import '../../providers/meal_providers.dart';
import '../../services/ai_analysis_service.dart';
import '../../services/location_service.dart';
import '../../services/photo_grouping.dart';
import '../../services/photo_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/meal_type_picker.dart';
import '../editor/photo_edit_core.dart';
import '../editor/photo_editor_screen.dart';

class CaptureScreen extends ConsumerStatefulWidget {
  final List<XFile>? initialPhotos;
  final bool fromLibrary;

  const CaptureScreen({super.key, this.initialPhotos, this.fromLibrary = false});

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _SelectedPhoto {
  final XFile originalFile; // 常にオリジナルを保持
  PhotoEditParams? editParams; // 編集パラメータ v2（nullなら未編集）
  DateTime? exifDateTime;
  double? exifLatitude;
  double? exifLongitude;
  _SelectedPhoto(this.originalFile);

  /// 見た目に影響する編集があるか（保存時に焼き込む対象か）
  bool get hasEdits => editParams != null && !editParams!.isIdentity;
}

/// 1つの食事として保存する写真の束。
///
/// 写真は添え字ではなく実体で持つ。添え字で持つと、写真を1枚消しただけで
/// どの組がどの写真を指しているかが崩れる。
class _PhotoGroup {
  _PhotoGroup(this.photos);

  final List<_SelectedPhoto> photos;
  MealType mealType = MealType.unset;

  /// 組の代表(一番古い1枚)。種別を引き継ぐときの鍵に使う
  _SelectedPhoto get representative => photos.first;

  /// 撮影日時が分かる写真があるか。無い組は日時を推測できない
  bool get hasKnownTime => photos.any((p) => p.exifDateTime != null);
}

class _CaptureScreenState extends ConsumerState<CaptureScreen> {
  static const _uuid = Uuid();
  final List<_SelectedPhoto> _selectedPhotos = [];
  bool _saving = false;
  bool _aiEnabled = true; // AI解析ON/OFF

  // 位置・日時。
  //
  // この画面は取り込んだ(過去の)写真だけを扱う。端末の現在位置は「いま
  // 画面を開いている場所」でしかなく、過去の食事の場所ではないので取らない。
  // カメラで撮ってその場で記録する経路は CameraScreen 側が担っている。
  late DateTime _capturedAt;

  @override
  void initState() {
    super.initState();
    _capturedAt = DateTime.now();
    if (widget.initialPhotos != null && widget.initialPhotos!.isNotEmpty) {
      for (final photo in widget.initialPhotos!) {
        _selectedPhotos.add(_SelectedPhoto(photo));
      }
      _readExifForInitialPhotos();
    }
  }

  Future<void> _readExifForInitialPhotos() async {
    for (final item in _selectedPhotos) {
      final exif = await PhotoService.readExifData(item.originalFile.path);
      if (exif.hasDateTime) item.exifDateTime = exif.dateTime;
      if (exif.hasLocation) {
        item.exifLatitude = exif.latitude;
        item.exifLongitude = exif.longitude;
      }
    }
    if (mounted) setState(_regroup);
  }

  /// 食事ごとの組。**画面の状態として持つ**。
  ///
  /// 毎回導出する作りだと、利用者が組を束ねた瞬間に並びが変わり、種別が
  /// 別の組へ移ってしまう。まとめる/分ける操作をそのまま反映できるように、
  /// ここを唯一の持ち主にする。
  List<_PhotoGroup> _groups = [];

  /// 写真の増減に合わせて組を作り直す。
  ///
  /// 利用者が手で束ねた結果は写真が変わると意味を失うので、自動判定に
  /// 戻す。種別だけは代表写真が同じ組へ引き継ぐ(選び直す手間を省く)。
  void _regroup() {
    final previousTypes = {
      for (final g in _groups) g.representative: g.mealType,
    };

    final indexGroups = groupShots(_selectedPhotos
        .map((p) => GroupableShot(
              shotAt: p.exifDateTime,
              latitude: p.exifLatitude,
              longitude: p.exifLongitude,
            ))
        .toList());

    _groups = [
      for (final indices in indexGroups)
        _PhotoGroup([for (final i in indices) _selectedPhotos[i]]),
      // groupShots は古い順に返す。画面は新しい順に並べる(一覧・ファイル選択と
      // 同じ向き)ので、ここで逆さにして保持と表示の向きを揃える
    ].reversed.toList();
    for (final g in _groups) {
      final carried = previousTypes[g.representative];
      if (carried != null) g.mealType = carried;
    }
  }

  /// すぐ上の組と1つにまとめる。
  /// 新しい順に並んでいるので、上は「より新しい組」になる
  void _mergeWithAbove(int position) {
    if (position <= 0 || position >= _groups.length) return;
    setState(() {
      final moved = _groups.removeAt(position);
      final target = _groups[position - 1];
      target.photos.addAll(moved.photos);
      // 代表(=一番古い1枚)から記録の日時を決めるので、並べ直しておく
      _sortPhotosByTime(target.photos);
    });
  }

  /// 古い順に並べる。日時が分からないものは後ろへ送る
  void _sortPhotosByTime(List<_SelectedPhoto> photos) {
    photos.sort((a, b) {
      final at = a.exifDateTime;
      final bt = b.exifDateTime;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return at.compareTo(bt);
    });
  }

  /// 1枚ずつの組に分ける
  void _splitGroup(int position) {
    if (position < 0 || position >= _groups.length) return;
    setState(() {
      final target = _groups[position];
      if (target.photos.length < 2) return;
      final singles = [
        for (final photo in target.photos) _PhotoGroup([photo])..mealType = target.mealType,
      ];
      _groups.replaceRange(position, position + 1, singles);
    });
  }

  /// 組の日時。EXIFを持つ一番古い写真の時刻。
  /// 分からない組は null(推測した時刻を本物のように見せない)
  DateTime? _groupDateTime(_PhotoGroup group) {
    final times = group.photos
        .map((p) => p.exifDateTime)
        .whereType<DateTime>()
        .toList()
      ..sort();
    return times.firstOrNull;
  }

  /// 組の位置。GPSを持つ一番古い写真のもの。
  ///
  /// 出どころは写真のEXIFだけ。端末の現在位置は使わない。
  ({double lat, double lng})? _groupPosition(_PhotoGroup group) {
    final withGps = group.photos
        .where((p) => p.exifLatitude != null && p.exifLongitude != null)
        .toList()
      ..sort((a, b) => (a.exifDateTime ?? DateTime(9999))
          .compareTo(b.exifDateTime ?? DateTime(9999)));
    final source = withGps.firstOrNull;
    if (source != null) {
      return (lat: source.exifLatitude!, lng: source.exifLongitude!);
    }
    return null;
  }

  /// 逆ジオコーディングの結果を覚えておく。
  /// build のたびに引き直すと、住所が出るまで表示が定まらない
  final Map<String, String?> _addressCache = {};

  String _positionKey(double lat, double lng) =>
      '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';

  /// 住所を引く。一度引いたものは覚えておき、次からは即座に返す
  Future<String?> _addressFor(double lat, double lng) async {
    final key = _positionKey(lat, lng);
    if (_addressCache.containsKey(key)) return _addressCache[key];
    final address = await LocationService.getAddress(lat, lng);
    _addressCache[key] = address;
    return address;
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('yyyy/M/d (E) HH:mm', 'ja');
    // 保存ボタンの文言にも使うので先に出しておく
    final groups = _groups;

    return Scaffold(
      appBar: AppBar(
        title: const Text('食事を記録'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 写真から下は流し込み。写真の高さは枚数で決まるので、
            // 固定の枠に押し込めず内容なりに積む
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                children: [
                  // 1件でも複数でも同じ形にする。件数で画面の作りが変わると
                  // 見え方が揃わず、どこに何があるのか覚えられない。
                  // 0件のときは「ライブラリから追加」だけを出す(同じことを
                  // する大きなボタンを重ねて置かない)
                  if (_selectedPhotos.isNotEmpty) ...[
                    _buildGroupSections(groups, dateFormat),
                    const SizedBox(height: 12),
                  ],
                  _buildAddPhotoButton(),
                ],
              ),
            ),

            // 保存ボタン + AI解析トグル(常に手の届く位置に置く)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  // AI解析ON/OFFトグル
                  Material(
                    color: _aiEnabled
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => setState(() => _aiEnabled = !_aiEnabled),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _aiEnabled ? Icons.auto_awesome : Icons.auto_awesome_outlined,
                              size: 20,
                              color: _aiEnabled
                                  ? Theme.of(context).colorScheme.onPrimaryContainer
                                  : KokoTokens.of(context).textMuted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'AI',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: _aiEnabled
                                    ? Theme.of(context).colorScheme.onPrimaryContainer
                                    : KokoTokens.of(context).textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 保存ボタン
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          _selectedPhotos.isEmpty || _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      // 何件になるのかを押す前に見せる
                      label: Text(_saving
                          ? '保存中...'
                          : groups.length > 1
                              ? '${groups.length}件を保存'
                              : '保存'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
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

  /// [indices] を渡すとその写真だけを並べる(組ごとの表示に使う)。
  /// タイルの操作は全体の添え字で動くので、渡すのは添え字のまま。
  Widget _buildPhotoGrid([List<_SelectedPhoto>? photos]) {
    final shown = photos ?? _selectedPhotos;
    // 1枚だけなら列を分けずに大きく見せる。2枚以上は2列。
    // 3列だとタイルが小さすぎて、料理も上に乗るボタンも見えなかった
    final columns = shown.length == 1 ? 1 : 2;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: shown.length,
      itemBuilder: (context, index) => _photoTile(shown[index]),
    );
  }

  /// 組ごとのセクション。2つ以上に分かれたときだけ使う。
  ///
  /// 別の食事として別々に保存されることが、見て分かるようにする。日時・場所・
  /// 種別を組ごとに持たせるのが目的なので、それぞれを枠の中に収める。
  Widget _buildGroupSections(List<_PhotoGroup> groups, DateFormat dateFormat) {
    final tokens = KokoTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 分かれたときだけ、なぜ分かれたのかを書く
        if (groups.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Icon(Icons.call_split, size: 15, color: tokens.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '撮影日時と場所から${groups.length}件の食事に分けました。'
                    'それぞれ別の記録として保存します',
                    style: TextStyle(
                        fontSize: 11.5, height: 1.4, color: tokens.textMuted),
                  ),
                ),
              ],
            ),
          ),
        for (var i = 0; i < groups.length; i++) ...[
          _buildGroupCard(groups[i], i, dateFormat),
          if (i < groups.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }

  /// 写真を足す導線。実線の枠だと写真の枠と同じ強さで並んでしまうので、
  /// 点線にして一段弱く見せる(Flutterに点線の枠が無いので自分で描く)
  Widget _buildAddPhotoButton() {
    final tokens = KokoTokens.of(context);
    return CustomPaint(
      painter: _DashedBorderPainter(color: tokens.hairline),
      child: SizedBox(
        width: double.infinity,
        child: TextButton.icon(
          onPressed: widget.fromLibrary ? _pickFromLibrary : _takePhoto,
          icon: Icon(
            widget.fromLibrary
                ? Icons.photo_library_outlined
                : Icons.add_a_photo_outlined,
            size: 18,
          ),
          label: Text(widget.fromLibrary ? 'ライブラリから追加' : '追加撮影'),
          style: TextButton.styleFrom(
            foregroundColor: tokens.textMuted,
            padding: const EdgeInsets.symmetric(vertical: 14),
            textStyle:
                const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  Widget _buildGroupCard(_PhotoGroup group, int position, DateFormat fmt) {
    final at = _groupDateTime(group);
    final pos = _groupPosition(group);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPhotoGrid(group.photos),
            const SizedBox(height: 10),

            // 日時。分からないものを「いまの時刻」で埋めて本物のように
            // 見せない。保存時に記録した時刻が入ることだけ伝える
            _groupMetaRow(
              icon: Icons.schedule,
              text: at != null ? fmt.format(at) : '撮影日時が分かりません（保存時の時刻を使います）',
              muted: at == null,
              numeral: at != null,
            ),
            const SizedBox(height: 4),
            // 場所。無いときも黙らずに書く(出ないのか無いのか分からなくなる)
            if (pos == null)
              _groupMetaRow(
                icon: Icons.location_off_outlined,
                text: '位置情報がありません',
                muted: true,
              )
            else
              FutureBuilder<String?>(
                // 一度引いた住所は覚えているので、再描画で引き直さない
                future: _addressFor(pos.lat, pos.lng),
                builder: (context, snapshot) => _groupMetaRow(
                  icon: Icons.place_outlined,
                  text: snapshot.data ??
                      (snapshot.connectionState == ConnectionState.waiting
                          ? '住所を調べています…'
                          : '位置情報あり（住所は不明）'),
                  muted: snapshot.data == null,
                ),
              ),
            const SizedBox(height: 10),

            Align(
              alignment: Alignment.centerLeft,
              child: MealTypeField(
                value: group.mealType,
                onChanged: (type) => setState(() => group.mealType = type),
              ),
            ),

            // まとめる / 分ける。どちらも押し戻せるようにしておく
            Wrap(
              spacing: 4,
              children: [
                if (position > 0)
                  TextButton.icon(
                    onPressed: () => _mergeWithAbove(position),
                    icon: const Icon(Icons.merge, size: 15),
                    label: const Text('上とまとめる'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                if (group.photos.length > 1)
                  TextButton.icon(
                    onPressed: () => _splitGroup(position),
                    icon: const Icon(Icons.call_split, size: 15),
                    label: const Text('1枚ずつに分ける'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 組の枠に出す1行(日時・場所)
  Widget _groupMetaRow({
    required IconData icon,
    required String text,
    bool muted = false,
    bool numeral = false,
  }) {
    final tokens = KokoTokens.of(context);
    final color = muted ? tokens.textFaint : tokens.textMuted;
    return Row(
      children: [
        Icon(icon, size: 14, color: tokens.textFaint),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: numeral
                ? tokens.numeral.copyWith(fontSize: 12.5, color: color)
                : TextStyle(fontSize: 12.5, color: color),
            maxLines: 2,
          ),
        ),
      ],
    );
  }

  /// 写真タイル。写真の上に置くのは「その写真への操作」だけにする。
  /// 撮影日時とAIの入り切りは記録ごとの設定で、下のメタデータ欄に出ている
  Widget _photoTile(_SelectedPhoto item) {
    final scheme = Theme.of(context).colorScheme;

    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: _buildPhotoThumbnail(item),
        ),
        // 編集(編集済みならボタン自体を色で示す。別バッジは出さない)
        Positioned(
          top: 2,
          left: 2,
          child: _tileButton(
            icon: Icons.tune,
            onTap: () => _editPhoto(item),
            background: item.hasEdits ? scheme.tertiary : Colors.black54,
            foreground: item.hasEdits ? scheme.onTertiary : Colors.white,
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: _tileButton(
            icon: Icons.close,
            onTap: () {
              setState(() {
                _selectedPhotos.remove(item);
                _regroup();
              });
            },
          ),
        ),
      ],
    );
  }

  /// タイル上の丸ボタン。指で押せる大きさ(36)を確保する
  Widget _tileButton({
    required IconData icon,
    required VoidCallback onTap,
    Color background = Colors.black54,
    Color foreground = Colors.white,
  }) {
    return Material(
      color: background,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, size: 19, color: foreground),
        ),
      ),
    );
  }

  Widget _buildPhotoThumbnail(_SelectedPhoto item) {
    final image = Image.file(
      File(item.originalFile.path),
      fit: BoxFit.cover,
      gaplessPlayback: true,
    );

    // クロップ/回転は焼き込み前なのでプレビューには反映しない（編集済みバッジで示す）。
    // フィルターのみColorFilteredで反映する
    final filter = item.editParams?.filter;
    if (filter == null || filter.isIdentity) return image;

    return ColorFiltered(
      colorFilter: ColorFilter.matrix(buildEditColorMatrix(filter)),
      child: image,
    );
  }

  Future<void> _takePhoto() async {
    final photo = await PhotoService.takePhoto();
    if (photo == null) return;
    // いま撮った写真にもEXIFが入る。読まないと日時不明の扱いになる
    final item = _SelectedPhoto(photo);
    final exif = await PhotoService.readExifData(photo.path);
    item.exifDateTime = exif.dateTime;
    item.exifLatitude = exif.latitude;
    item.exifLongitude = exif.longitude;
    if (!mounted) return;
    setState(() {
      _selectedPhotos.add(item);
      _regroup();
    });
  }

  Future<void> _pickFromLibrary() async {
    final photos = await PhotoService.pickPhotos();
    if (photos.isEmpty) return;

    final items = <_SelectedPhoto>[];
    for (final photo in photos) {
      final item = _SelectedPhoto(photo);
      // EXIFからメタデータを読み取る
      final exif = await PhotoService.readExifData(photo.path);
      item.exifDateTime = exif.dateTime;
      item.exifLatitude = exif.latitude;
      item.exifLongitude = exif.longitude;
      items.add(item);
    }

    if (!mounted) return;
    setState(() {
      _selectedPhotos.addAll(items);
      _regroup();
    });
  }

  Future<void> _editPhoto(_SelectedPhoto item) async {
    final outcome = await Navigator.push<PhotoEditOutcome>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditorScreen(
          imagePath: item.originalFile.path,
          initialParams: item.editParams,
        ),
      ),
    );
    if (outcome is PhotoEditApplied && mounted) {
      setState(() {
        // 恒等（編集なし）で確定された場合は未編集扱いに戻す
        item.editParams = outcome.params.isIdentity ? null : outcome.params;
      });
    }
  }

  /// 座標が登録済みの場所の近くなら、その場所のタグを返す。
  /// 100mはマップ側の判定と揃えている
  String? _matchSavedPlace(
    List<SavedPlace> savedPlaces,
    double? lat,
    double? lng,
  ) {
    if (lat == null || lng == null) return null;
    for (final place in savedPlaces) {
      final distance = Geolocator.distanceBetween(
        lat,
        lng,
        place.latitude,
        place.longitude,
      );
      if (distance <= 100) {
        return place.iconType == 'home' ? 'home' : place.id;
      }
    }
    return null;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    // 画面を閉じた後に通知を出すため、アプリ直下のMessengerを先に掴んでおく
    final messenger = ScaffoldMessenger.of(context);
    var bakeFailures = 0; // 焼き込みに失敗しオリジナルで保存した枚数

    try {
      // 撮影日時と場所で分けた「食事」ごとに、別々の記録として保存する。
      // ライブラリからまとめて取り込むと別の日・別の店が混ざるので、1件に
      // 押し込むと日時と場所が一番古い写真のものに揃えられてしまう
      final groups = _groups;
      // 場所の判定に使うので1回だけ読む
      final savedPlaces = await LocalDatabase.getSavedPlaces();

      for (final group in groups) {
        final mealLogId = _uuid.v4();
        // 撮影日時が分からない組は、いつ食べたかを決められない。
        // 画面にもそう出しているとおり、記録した時刻で埋める
        final eatenAt = _groupDateTime(group) ?? _capturedAt;
        final position = _groupPosition(group);
        final lat = position?.lat;
        final lng = position?.lng;
        final locationTag = _matchSavedPlace(savedPlaces, lat, lng);

        await LocalDatabase.insertMealLog(MealLog(
          id: mealLogId,
          mealType: group.mealType,
          eatenAt: eatenAt,
          latitude: lat,
          longitude: lng,
          locationTag: locationTag,
          createdAt: DateTime.now(),
        ));

        // 写真を保存（編集がある場合は先にisolateで焼き込んでから保存）
        for (final item in group.photos) {
        // まずオリジナル（未編集）画像を保存
        final originalPath = await PhotoService.saveToLocalFromPath(
          item.originalFile.path,
        );

        // 編集がある場合はオリジナルへ焼き込み、パラメータもv2 JSONで保存する
        // （詳細画面からオリジナル基準で再編集できるようにする）
        String localPath = originalPath;
        String? editParamsJson;
        if (item.hasEdits) {
          final params = item.editParams!;
          final tmpDir = await getTemporaryDirectory();
          // 同じミリ秒に複数枚を焼くことがあるので、一意なidを混ぜる
          final outputPath =
              '${tmpDir.path}/edit_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4()}.jpg';
          final baked = await compute(
            bakePhotoEdit,
            PhotoEditBakeRequest(
              inputPath: item.originalFile.path,
              outputPath: outputPath,
              params: params,
            ),
          );
          if (baked != null) {
            localPath = await PhotoService.saveToLocalFromPath(baked);
            editParamsJson = jsonEncode(params.toJson());
            // ローカルへコピー済みなので焼き込みの一時ファイルは片付ける
            try {
              await File(baked).delete();
            } catch (_) {}
          } else {
            // 焼き込み失敗（非対応の画像形式やI/O失敗）。オリジナルで保存を
            // 続行し、後でまとめて通知する
            bakeFailures++;
          }
        }
        final thumbnailPath = await PhotoService.generateThumbnail(localPath);

          final photoLat = item.exifLatitude ?? lat;
          final photoLng = item.exifLongitude ?? lng;
          final photoShotAt = item.exifDateTime ?? eatenAt;

          await LocalDatabase.insertMealPhoto(MealPhoto(
            id: _uuid.v4(),
            mealLogId: mealLogId,
            localPath: localPath,
            originalLocalPath: originalPath,
            thumbnailUrl: thumbnailPath,
            skipAi: !_aiEnabled,
            aiStatus: _aiEnabled ? 'pending' : 'skipped',
            editParamsJson: editParamsJson,
            shotAt: photoShotAt,
            latitude: photoLat,
            longitude: photoLng,
            createdAt: DateTime.now(),
          ));
        }
      }

      // 一覧を更新して画面を閉じる
      ref.read(mealLogsProvider.notifier).refresh();
      if (mounted) context.pop();

      // 焼き込みに失敗した写真があれば通知（オリジナルで保存済み）
      if (bakeFailures > 0) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '$bakeFailures枚の写真は編集を反映できませんでした（非対応の画像形式の可能性）',
            ),
          ),
        );
      }

      // --- 以下バックグラウンド処理（画面はすでに閉じている） ---

      // AI解析（端末内Gemma）
      await AiAnalysisService.processPendingPhotos();
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

/// 点線の角丸枠。実線だと写真の枠と同じ強さで並んでしまうので、
/// 「写真を足す」の導線はこれで一段弱く見せる。
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color});

  final Color color;

  static const _radius = 12.0;
  static const _dash = 5.0;
  static const _gap = 4.0;
  static const _strokeWidth = 1.2;

  @override
  void paint(Canvas canvas, Size size) {
    final border = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(_radius),
      ));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..color = color;

    // 枠線を辿りながら、線と間隔を交互に置く
    for (final metric in border.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + _dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}
