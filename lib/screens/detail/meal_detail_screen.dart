import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable, compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../../database/local_database.dart';
import '../../models/meal_log.dart';
import '../../models/meal_photo.dart';
import '../../models/meal_type.dart';
import '../../providers/map_focus_providers.dart';
import '../../providers/meal_providers.dart';
import '../../services/ai_analysis_service.dart';
import '../../services/app_settings_service.dart';
import '../../services/device_capability.dart';
import '../../services/gemma_download_manager.dart';
import '../../services/gemma_ondevice_service.dart';
import '../../services/location_service.dart';
import '../../services/photo_cache_service.dart';
import '../../services/photo_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/cached_photo_image.dart';
import '../../widgets/meal_type_picker.dart';
import '../editor/photo_edit_core.dart';
import '../editor/photo_editor_screen.dart';
import 'photo_info_edit_sheet.dart';
import 'photo_viewer_screen.dart';
import 'reanalyze_dialog.dart';

class MealDetailScreen extends ConsumerStatefulWidget {
  final String mealLogId;

  const MealDetailScreen({super.key, required this.mealLogId});

  @override
  ConsumerState<MealDetailScreen> createState() => _MealDetailScreenState();
}

class _MealDetailScreenState extends ConsumerState<MealDetailScreen> {
  Timer? _refreshTimer;
  int _selectedPhotoIndex = 0;

  /// 端末内AIモデル(E2B)がインストール済みか。null=未確認。
  /// GemmaDownloadManagerが画面をまたいで保持しているので、この画面を
  /// 開いたままDLが完了した場合も表示が追従する
  final ValueListenable<bool?> _e2bInstalled =
      GemmaDownloadManager.instance.installedOf(GemmaModelKind.e2b);

  @override
  void initState() {
    super.initState();
    _e2bInstalled.addListener(_onE2bInstalledChanged);
    // 端末内AIモード時のみ最新化を依頼する(結果は_e2bInstalledに反映される)
    if (AppSettings.aiMode == AiAnalysisMode.onDevice) {
      GemmaDownloadManager.instance.refreshInstalled(GemmaModelKind.e2b);
    }
  }

  void _onE2bInstalledChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _e2bInstalled.removeListener(_onE2bInstalledChanged);
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _startAutoRefresh(List<MealPhoto> photos) {
    _refreshTimer?.cancel();
    final hasPending = photos.any(
      (p) => p.aiStatus == 'pending' || p.aiStatus == 'processing',
    );
    if (hasPending) {
      _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        ref.invalidate(mealPhotosProvider(widget.mealLogId));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mealLogAsync = ref.watch(mealLogProvider(widget.mealLogId));
    final photosAsync = ref.watch(mealPhotosProvider(widget.mealLogId));

    // pending写真がある場合、自動リフレッシュ
    photosAsync.whenData((photos) {
      _startAutoRefresh(photos);
      // indexが範囲外にならないように
      if (_selectedPhotoIndex >= photos.length && photos.isNotEmpty) {
        _selectedPhotoIndex = photos.length - 1;
      }
    });

    final tokens = KokoTokens.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('食事の詳細'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '記録を削除',
            onPressed: () => _confirmDelete(context),
          ),
        ],
      ),
      body: mealLogAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('エラー: $e', style: TextStyle(color: tokens.textMuted)),
        ),
        data: (mealLog) {
          if (mealLog == null) {
            return Center(
              child: Text(
                '記録が見つかりません',
                style: TextStyle(color: tokens.textMuted),
              ),
            );
          }

          final dateFormat = DateFormat('yyyy年M月d日 (E) HH:mm', 'ja');

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + context.systemBottomInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                photosAsync.when(
                  loading: () => const SizedBox(
                    height: 300,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => SizedBox(
                    height: 300,
                    child: Center(
                      child: Text(
                        '写真の読み込みに失敗: $e',
                        style: TextStyle(color: tokens.textMuted),
                      ),
                    ),
                  ),
                  data: (photos) => _buildPhotoSection(photos),
                ),
                const SizedBox(height: 16),
                _buildMetaRow(mealLog, dateFormat),
                _buildLocationRow(mealLog),
                const SizedBox(height: 16),
                photosAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (photos) => photos.isEmpty
                      ? const SizedBox.shrink()
                      : _buildPhotoAiResult(photos[_selectedPhotoIndex]),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// メタ情報: 食事種別チップ・日時。
  /// 場所は下の行([_buildLocationRow])に任せる(自宅タグを二重に出さない)。
  Widget _buildMetaRow(MealLog mealLog, DateFormat dateFormat) {
    final tokens = KokoTokens.of(context);

    return Row(
      children: [
        _buildMealTypeSelector(mealLog),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            dateFormat.format(mealLog.eatenAt),
            textAlign: TextAlign.end,
            style: tokens.numeral.copyWith(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: tokens.textMuted,
            ),
          ),
        ),
      ],
    );
  }

  /// 場所の行。マイプレイス名(自宅・職場)や店名と、座標から引いた住所を出す。
  ///
  /// タップでマップのその場所へ寄る。記録から地図へ辿れないと、せっかく
  /// 位置を持っているのに見に行けない。長押しで文字列をコピーできる
  /// (店名や住所を検索したり人に送ったりするため。編集はここでは持たない)。
  ///
  /// 住所はOS内蔵のジオコーダで引くので課金されない。座標が無い記録では
  /// この行自体を出さない。
  Widget _buildLocationRow(MealLog mealLog) {
    final tokens = KokoTokens.of(context);
    final lat = mealLog.latitude;
    final lng = mealLog.longitude;
    final placeName = _placeLabel(mealLog);

    // 場所を示すものが何も無ければ行を出さない
    if (lat == null && lng == null && placeName == null) {
      return const SizedBox.shrink();
    }

    return FutureBuilder<String?>(
      // 座標があるときだけ住所を引く
      future: (lat != null && lng != null)
          ? LocationService.getAddress(lat, lng)
          : Future.value(null),
      builder: (context, snapshot) {
        final address = snapshot.data;
        final parts = [?placeName, ?address];
        if (parts.isEmpty) return const SizedBox.shrink();
        final text = parts.join('　');
        final canOpenMap = lat != null && lng != null;

        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: canOpenMap
                ? () => _openInMap(lat, lng, placeName ?? address)
                : null,
            onLongPress: () => _copyLocationText(text),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(
                children: [
                  Icon(_placeIcon(mealLog), size: 16, color: tokens.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(fontSize: 13, color: tokens.textMuted),
                      maxLines: 2,
                    ),
                  ),
                  if (canOpenMap) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.map_outlined, size: 16, color: tokens.textFaint),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// マイプレイス名か店名。どちらも無ければ null
  String? _placeLabel(MealLog mealLog) {
    if (mealLog.locationTag == 'home') return '自宅';

    final tag = mealLog.locationTag;
    if (tag != null) {
      final places = ref.watch(savedPlacesProvider).valueOrNull;
      final place = places?.where((p) => p.id == tag).firstOrNull;
      if (place != null) return place.name;
    }

    final restaurantId = mealLog.restaurantId;
    if (restaurantId != null) {
      return ref.watch(restaurantProvider(restaurantId)).valueOrNull?.name;
    }
    return null;
  }

  IconData _placeIcon(MealLog mealLog) {
    if (mealLog.locationTag == 'home') return Icons.home_outlined;
    if (mealLog.locationTag != null) return Icons.star_outline;
    if (mealLog.restaurantId != null) return Icons.storefront_outlined;
    return Icons.place_outlined;
  }

  /// マップタブへ切り替えてその場所に寄る
  void _openInMap(double latitude, double longitude, String? label) {
    ref.read(mapFocusProvider.notifier).state = MapFocus(
      latitude: latitude,
      longitude: longitude,
      label: label,
    );
    // 詳細を閉じてホーム(マップタブ)へ戻る
    context.go('/');
  }

  Future<void> _copyLocationText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('コピーしました'), duration: Duration(seconds: 2)),
    );
  }

  /// タップで食事種別を変更できるチップ(記録画面と共通)
  Widget _buildMealTypeSelector(MealLog mealLog) => MealTypeField(
        value: mealLog.mealType,
        onChanged: (selected) => _applyMealType(mealLog, selected),
      );

  Future<void> _applyMealType(MealLog mealLog, MealType selected) async {
    await LocalDatabase.updateMealLog(mealLog.copyWith(mealType: selected));
    if (!mounted) return;
    ref.invalidate(mealLogProvider(widget.mealLogId));
    ref.read(mealLogsProvider.notifier).refresh();
  }

  /// 写真セクション: 選択写真 + サムネ一覧
  Widget _buildPhotoSection(List<MealPhoto> photos) {
    final tokens = KokoTokens.of(context);

    if (photos.isEmpty) {
      return Container(
        height: 200,
        width: double.infinity,
        decoration: BoxDecoration(
          color: tokens.photoPlaceholder,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.image_outlined, size: 32, color: tokens.textFaint),
            const SizedBox(height: 8),
            Text(
              '写真がありません',
              style: TextStyle(fontSize: 13, color: tokens.textMuted),
            ),
          ],
        ),
      );
    }

    final selectedPhoto = photos[_selectedPhotoIndex];

    return Column(
      children: [
        // 選択中の写真を大きく表示
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PhotoViewerScreen(
                      photos: photos,
                      initialIndex: _selectedPhotoIndex,
                    ),
                  ),
                ),
                child: CachedPhotoImage(
                  localPath: selectedPhoto.localPath,
                  thumbnailPath: selectedPhoto.thumbnailUrl,
                  originalUrl: selectedPhoto.originalUrl,
                  height: 300,
                  width: double.infinity,
                  fullQuality: true,
                ),
              ),
              // 編集ボタン
              Positioned(
                right: 12,
                bottom: 12,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => _editPhoto(selectedPhoto),
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.tune, color: Colors.white, size: 18),
                    ),
                  ),
                ),
              ),
              // 枚数表示
              if (photos.length > 1)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${_selectedPhotoIndex + 1} / ${photos.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        // サムネイル一覧（2枚以上の場合）
        if (photos.length > 1) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 56,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: photos.length,
              itemBuilder: (context, index) {
                final photo = photos[index];
                final isSelected = index == _selectedPhotoIndex;
                return GestureDetector(
                  onTap: () => setState(() => _selectedPhotoIndex = index),
                  child: Container(
                    width: 56,
                    margin: EdgeInsets.only(
                        right: index == photos.length - 1 ? 0 : 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : tokens.hairline,
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedPhotoImage(
                        localPath: photo.localPath,
                        thumbnailPath: photo.thumbnailUrl,
                        originalUrl: photo.originalUrl,
                        height: 56,
                        width: 56,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  /// 個別写真のAI解析結果
  Widget _buildPhotoAiResult(MealPhoto photo) {
    // AI解析がオフのときは、未解析の写真に「AIオフ + 設定へ」を表示
    if (AppSettings.aiMode == AiAnalysisMode.off &&
        photo.aiStatus != 'completed') {
      return _buildAiOffNotice();
    }
    // 端末内AIが動かない端末では、モデルDLも再解析も意味が無いので入口ごと
    // 出さない。解析済みの結果(別端末で解析したものを復元した等)は見せる
    if (!DeviceCapability.onDeviceAi && photo.aiStatus != 'completed') {
      return _buildDeviceUnsupportedNotice();
    }
    switch (photo.aiStatus) {
      case 'completed':
        return _buildCompletedResult(photo);
      case 'pending':
      case 'processing':
        // 端末内AIモデルが未ダウンロードだと解析は始まらないので、
        // 「解析中」ではなく設定画面への誘導を出す
        if (AppSettings.aiMode == AiAnalysisMode.onDevice &&
            _e2bInstalled.value == false) {
          return _buildModelMissingNotice();
        }
        // pending は順番待ちでしかない。一覧のカードと同じ区別をして、
        // 「一覧では終わって見えるのに詳細だけ解析中」を作らない
        if (photo.aiStatus == 'pending') {
          return _buildStatusCard(
            leading: Icon(
              Icons.schedule,
              size: 18,
              color: KokoTokens.of(context).textFaint,
            ),
            message: 'AI解析の順番待ちです',
          );
        }
        return _buildStatusCard(
          leading: const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          message: 'AI解析中です',
        );
      case 'failed':
        {
          final scheme = Theme.of(context).colorScheme;
          return _buildStatusCard(
            leading: Icon(Icons.error_outline, size: 18, color: scheme.error),
            message: '解析に失敗しました',
            messageColor: scheme.error,
            detail: photo.aiError,
            action: TextButton.icon(
              onPressed: () => _retryForPhoto(photo),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('再解析'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          );
        }
      case 'skipped':
        return _buildSkippedCard(photo);
      case 'unavailable':
        // 写真の実体が無いので再解析しても同じ。ボタンは出さない
        return _buildStatusCard(
          leading: Icon(
            Icons.image_not_supported_outlined,
            size: 18,
            color: KokoTokens.of(context).textFaint,
          ),
          message: '写真の実体が見つかりません',
          detail: photo.aiError ??
              'この記録の写真ファイルが失われているため、AI解析はできません。'
                  '料理名や価格は手入力で記録できます。',
        );
      default:
        // skipAiがtrueでstatusがcompletedでない場合
        if (photo.skipAi) {
          return _buildSkippedCard(photo);
        }
        return _buildStatusCard(
          leading: Icon(
            Icons.smart_toy_outlined,
            size: 18,
            color: KokoTokens.of(context).textFaint,
          ),
          message: 'AI解析は未実行です',
        );
    }
  }

  /// AI解析スキップ時の表示
  Widget _buildSkippedCard(MealPhoto photo) {
    return _buildStatusCard(
      leading: Icon(
        Icons.visibility_off_outlined,
        size: 18,
        color: KokoTokens.of(context).textFaint,
      ),
      message: 'AI解析をスキップしました',
      action: TextButton.icon(
        onPressed: () => _retryForPhoto(photo),
        icon: const Icon(Icons.auto_awesome_outlined, size: 16),
        label: const Text('解析する'),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      ),
    );
  }

  /// 端末内AIが動かない端末(32bit)での表示。
  /// モデルを落としても動かないので、ダウンロードには誘導しない。
  /// 手で入力すれば記録としては完結するため、編集への導線だけ出す。
  Widget _buildDeviceUnsupportedNotice() {
    return _buildStatusCard(
      leading: Icon(
        Icons.phonelink_off,
        size: 18,
        color: KokoTokens.of(context).textFaint,
      ),
      message: 'この端末ではAI解析を使えません',
      detail: '端末内AIは64bit(arm64)端末にのみ対応しています。'
          '料理名や価格は手入力で記録できます。',
    );
  }

  /// 端末内AIモデル未ダウンロード時の表示（設定画面へのリンク付き）
  Widget _buildModelMissingNotice() {
    return _buildStatusCard(
      leading: Icon(
        Icons.download_for_offline_outlined,
        size: 18,
        color: KokoTokens.of(context).textFaint,
      ),
      message: '端末内AIモデルが未ダウンロードです',
      action: TextButton.icon(
        onPressed: () => context.push('/settings'),
        icon: const Icon(Icons.settings_outlined, size: 16),
        label: const Text('設定'),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      ),
    );
  }

  /// AI解析オフ時の表示（設定画面へのリンク付き）
  Widget _buildAiOffNotice() {
    return _buildStatusCard(
      leading: Icon(
        Icons.smart_toy_outlined,
        size: 18,
        color: KokoTokens.of(context).textFaint,
      ),
      message: 'AI解析はオフです',
      action: TextButton.icon(
        onPressed: () => context.push('/settings'),
        icon: const Icon(Icons.settings_outlined, size: 16),
        label: const Text('設定'),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      ),
    );
  }

  /// 解析中/失敗/スキップ/オフの共通カード
  Widget _buildStatusCard({
    required Widget leading,
    required String message,
    Color? messageColor,
    Widget? action,
    String? detail,
  }) {
    final tokens = KokoTokens.of(context);
    return Card(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 10, action != null ? 8 : 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                leading,
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: messageColor ?? tokens.textMuted,
                    ),
                  ),
                ),
                ?action,
              ],
            ),
            if (detail != null)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 2, right: 8),
                child: Text(
                  detail,
                  style: TextStyle(fontSize: 12, color: tokens.textFaint),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 解析完了時の結果表示
  Widget _buildCompletedResult(MealPhoto photo) {
    final tokens = KokoTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final isUserCorrected = photo.userCorrectedName != null ||
        photo.userCorrectedPrice != null ||
        photo.userCorrectedCalories != null;
    final name = photo.displayName;

    return Card(
      // ブロック全体のリップルを角丸の内側に収める
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 記録本体(メニュー名 + 価格/カロリー)。ここ全体がひとつの編集導線。
          // 別に「編集」ボタンを置くと入口が二重になるため、値そのものを
          // タップさせる形に一本化している
          InkWell(
            onTap: () => _showEditSheet(photo),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          name ?? 'メニュー名を追加',
                          style: textTheme.titleLarge?.copyWith(
                            fontSize: 19,
                            height: 1.35,
                            fontWeight: FontWeight.w700,
                            color: name == null ? tokens.textFaint : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Icon(Icons.edit_outlined,
                            size: 18, color: tokens.textMuted),
                      ),
                    ],
                  ),

                  // 価格・カロリーは罫線で区切った数値組にして「記録」らしく見せる
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.only(top: 12),
                    decoration: BoxDecoration(
                      border: Border(
                          top: BorderSide(color: tokens.hairline, width: 0.8)),
                    ),
                    child: IntrinsicHeight(
                      child: Row(
                        children: [
                          Expanded(
                            child: _statCell(
                              label: '価格',
                              value: photo.displayPrice == null
                                  ? null
                                  : '¥${NumberFormat('#,###').format(photo.displayPrice)}',
                            ),
                          ),
                          VerticalDivider(
                              width: 28, thickness: 0.8, color: tokens.hairline),
                          Expanded(
                            child: _statCell(
                              label: 'カロリー',
                              value: photo.displayCalories == null
                                  ? null
                                  : '${NumberFormat('#,###').format(photo.displayCalories)} kcal',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 値の出所(AIモデル / ユーザー修正)
                if (isUserCorrected || photo.aiModel != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        if (isUserCorrected)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: scheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'ユーザー修正済',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        const Spacer(),
                        if (photo.aiModel != null)
                          Text(
                            photo.aiModel!,
                            style: TextStyle(
                                fontSize: 11, color: tokens.textFaint),
                          ),
                      ],
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _showReanalyzeDialog(photo),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('AIで再解析'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 36),
                      textStyle: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 価格/カロリーの1セル。未入力は「—」にして、編集で埋められることを示す。
  Widget _statCell({required String label, String? value}) {
    final tokens = KokoTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: tokens.textFaint,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value ?? '—',
          style: tokens.numeral.copyWith(
            fontSize: 17,
            color: value == null ? tokens.textFaint : null,
          ),
        ),
      ],
    );
  }

  /// 個別写真のAI解析リトライ。
  /// SnackBarアクションから画面破棄後に呼ばれてもDB更新と解析起動は行われるよう、
  /// ref/context へのアクセスはすべて mounted ガード後に限定する。
  /// [aiHint]/[clearHint] で再解析用キーワードを、[clearUserCorrections] で
  /// 手動修正値のクリアを指定できる(再解析ダイアログから使う)。
  Future<void> _retryForPhoto(
    MealPhoto photo, {
    String? aiHint,
    bool clearHint = false,
    bool clearUserCorrections = false,
  }) async {
    // DB更新 → 解析起動（ここまではUIに触れないので画面破棄後でも安全）
    final updated = photo.copyWith(
      aiStatus: 'pending',
      skipAi: false,
      aiHint: aiHint,
      clearAiHint: clearHint,
      clearUserCorrections: clearUserCorrections,
    );
    await LocalDatabase.updateMealPhoto(updated);

    AiAnalysisService.processPendingPhotos().then((_) {
      if (mounted) {
        ref.invalidate(mealPhotosProvider(widget.mealLogId));
        ref.read(mealLogsProvider.notifier).refresh();
      }
    });

    // 起動直後のUI反映（pending表示への切替）は画面が生きているときだけ
    if (mounted) {
      ref.invalidate(mealPhotosProvider(widget.mealLogId));
    }
  }

  /// 解析済み写真をキーワード付きで再解析する。
  /// キーワードは料理特定のヒントとしてプロンプトに注入され、再解析すると
  /// 手動修正値はクリアされる(AI結果で上書きし直すため)。
  Future<void> _showReanalyzeDialog(MealPhoto photo) async {
    final request = await showReanalyzeDialog(context, photo);
    if (request == null) return;
    await _retryForPhoto(
      photo,
      aiHint: request.hint,
      clearHint: request.hint == null,
      clearUserCorrections: true,
    );
  }

  /// ローカルにある編集元のファイルパス（常に真のオリジナルを優先）
  String? _localEditSource(MealPhoto photo) {
    final original = photo.originalLocalPath;
    if (original != null && File(original).existsSync()) return original;
    if (File(photo.localPath).existsSync()) return photo.localPath;
    return null;
  }

  Future<void> _editPhoto(MealPhoto photo) async {
    var editSource = _localEditSource(photo);
    if (editSource == null) {
      // ローカル実体が無い(クラウド後削除・復元レコード等)。
      // 表示系と同じくクラウドのオリジナルをDLして編集元にする
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Expanded(child: Text('クラウドから写真を取得しています…')),
              ],
            ),
          ),
        ),
      );
      try {
        editSource = await PhotoCacheService.getOriginalPath(
          localPath: photo.localPath,
          originalUrl: photo.originalUrl,
        );
      } finally {
        if (mounted) Navigator.of(context).pop();
      }
      if (!mounted) return;
    }
    if (editSource == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('写真ファイルが見つかりません（クラウドからも取得できませんでした）')),
      );
      return;
    }

    // ここから先はnull不可(閉包キャプチャで昇格が効かないためfinalに固定)
    final srcPath = editSource;

    // 保存済み編集パラメータ（v2のみ。v1や欠損はnull=初期状態から）を復元。
    // オリジナルを失って焼き込み済み画像を編集元にする場合は座標系が合わないため復元しない
    PhotoEditParams? initialParams;
    final editingOriginal =
        photo.originalLocalPath == null || srcPath == photo.originalLocalPath;
    if (editingOriginal && photo.editParamsJson != null) {
      try {
        initialParams = PhotoEditParams.fromJson(
          jsonDecode(photo.editParamsJson!) as Map<String, dynamic>,
        );
      } catch (_) {
        initialParams = null;
      }
    }

    // 編集済みで、かつオリジナルが別ファイルとして残っている場合のみ「オリジナルに戻す」を出す
    final canRestoreOriginal = photo.originalLocalPath != null &&
        photo.originalLocalPath != photo.localPath &&
        File(photo.originalLocalPath!).existsSync();

    final outcome = await Navigator.push<PhotoEditOutcome>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditorScreen(
          imagePath: srcPath,
          initialParams: initialParams,
          canRestoreOriginal: canRestoreOriginal,
        ),
      ),
    );

    if (outcome == null || !mounted) return;

    switch (outcome) {
      case PhotoEditRestoreOriginal():
        await _restoreOriginal(photo);
      case PhotoEditApplied(:final params):
        await _applyEditToPhoto(photo, editSource, params);
    }
  }

  /// 編集パラメータをオリジナルへ焼き込み、写真レコードを更新する
  Future<void> _applyEditToPhoto(
    MealPhoto photo,
    String editSource,
    PhotoEditParams params,
  ) async {
    // 恒等（全リセットで確定）はオリジナル復元と同じ扱い
    if (params.isIdentity) {
      if (photo.originalLocalPath != null &&
          photo.originalLocalPath != photo.localPath) {
        await _restoreOriginal(photo);
      }
      return;
    }

    // 進捗モーダルを出しつつisolateで焼き込み
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 16),
              Text('写真を処理中...'),
            ],
          ),
        ),
      ),
    );

    String? newLocalPath;
    String? newThumbPath;
    try {
      final tmpDir = await getTemporaryDirectory();
      final outputPath =
          '${tmpDir.path}/edit_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final baked = await compute(
        bakePhotoEdit,
        PhotoEditBakeRequest(
          inputPath: editSource,
          outputPath: outputPath,
          params: params,
        ),
      );
      if (baked != null) {
        newLocalPath = await PhotoService.saveToLocalFromPath(baked);
        newThumbPath = await PhotoService.generateThumbnail(newLocalPath);
        // ローカルへコピー済みなので焼き込みの一時ファイルは片付ける
        try {
          await File(baked).delete();
        } catch (_) {}
      }
    } finally {
      navigator.pop(); // 進捗モーダルを閉じる
    }

    if (!mounted) return;
    if (newLocalPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('写真の処理に失敗しました')),
      );
      return;
    }

    // 書き戻し直前にDBの最新レコードを取得し、編集関連フィールドだけを重ねる。
    // 編集セッション中に完了したAI解析結果を全列上書きで巻き戻さないため。
    final current = await LocalDatabase.getMealPhoto(photo.id);
    if (current == null) return; // レコードが削除済みなら何もしない

    final oldLocalPath = current.localPath;
    final oldThumbPath = current.thumbnailUrl;
    // 真のオリジナルは上書きしない（未設定の場合のみ今回の編集元を記録）
    final resolvedOriginal = current.originalLocalPath ?? editSource;

    final updated = current.copyWith(
      localPath: newLocalPath,
      originalLocalPath: resolvedOriginal,
      thumbnailUrl: newThumbPath,
      editParamsJson: jsonEncode(params.toJson()),
      uploadStatus: 'pending', // 再編集後の画像をクラウドへ再アップする
    );
    await LocalDatabase.updateMealPhoto(updated);

    // 差し替えで不要になった旧焼き込みファイル・旧サムネイルを削除
    await _deleteStalePhotoFiles(
      oldLocalPath: oldLocalPath,
      oldThumbPath: oldThumbPath,
      originalPath: resolvedOriginal,
      newLocalPath: newLocalPath,
      newThumbPath: newThumbPath,
    );

    if (!mounted) return;
    ref.invalidate(mealPhotosProvider(widget.mealLogId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('写真を更新しました'),
        action: SnackBarAction(
          label: 'AIで再解析',
          onPressed: () => _retryForPhoto(updated),
        ),
      ),
    );
  }

  /// 画像差し替え後に不要となった旧本体・旧サムネイルを削除する。
  /// オリジナル（[originalPath]）と新しいファイルは絶対に消さない。
  Future<void> _deleteStalePhotoFiles({
    required String oldLocalPath,
    required String? oldThumbPath,
    required String? originalPath,
    required String newLocalPath,
    required String? newThumbPath,
  }) async {
    // 旧本体: オリジナルでも新ファイルでもない焼き込みファイルのみ削除
    if (oldLocalPath != originalPath && oldLocalPath != newLocalPath) {
      try {
        await File(oldLocalPath).delete();
      } catch (_) {}
    }
    // 旧サムネイル: 新サムネイル・オリジナルと異なる場合のみ削除
    if (oldThumbPath != null &&
        oldThumbPath != newThumbPath &&
        oldThumbPath != originalPath) {
      try {
        await File(oldThumbPath).delete();
      } catch (_) {}
    }
  }

  /// オリジナル画像に復元（編集パラメータをクリアし、クラウドへ再アップ）
  Future<void> _restoreOriginal(MealPhoto photo) async {
    final originalPath = photo.originalLocalPath;
    if (originalPath == null || !File(originalPath).existsSync()) return;
    final newThumbPath = await PhotoService.generateThumbnail(originalPath);

    // 書き戻し直前にDBの最新レコードを取得し、復元関連フィールドだけを重ねる。
    // 復元セッション中に完了したAI解析結果を全列上書きで巻き戻さないため。
    final current = await LocalDatabase.getMealPhoto(photo.id);
    if (current == null) return; // レコードが削除済みなら何もしない

    final oldLocalPath = current.localPath;
    final oldThumbPath = current.thumbnailUrl;

    final updated = current.copyWith(
      localPath: originalPath,
      thumbnailUrl: newThumbPath,
      clearEditParams: true,
      uploadStatus: 'pending', // 復元後の画像をクラウドへ再アップする
    );
    await LocalDatabase.updateMealPhoto(updated);

    // 差し替えで不要になった旧焼き込みファイル・旧サムネイルを削除。
    // newLocalPath にオリジナルを渡すことで、オリジナルは削除対象から必ず外れる
    await _deleteStalePhotoFiles(
      oldLocalPath: oldLocalPath,
      oldThumbPath: oldThumbPath,
      originalPath: originalPath,
      newLocalPath: originalPath,
      newThumbPath: newThumbPath,
    );

    if (!mounted) return;
    ref.invalidate(mealPhotosProvider(widget.mealLogId));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('オリジナル画像に復元しました')),
    );
  }

  Future<void> _showEditSheet(MealPhoto photo) async {
    final edit = await showPhotoInfoEditSheet(context, photo);
    if (edit == null || !mounted) return;

    // AIの推定値と同じなら修正として記録しない(値を変えずに保存しただけで
    // 「ユーザー修正済」が付くのを防ぐ)。
    // また copyWith は userCorrected* に null を渡すと既存値を維持するので、
    // 一度クリアしてから重ねる。こうしないと入力欄を空にしても前の修正値が
    // 残り、「AIの推定に戻す」ができない
    final updated = photo.copyWith(clearUserCorrections: true).copyWith(
          userCorrectedName:
              edit.name == photo.aiMenuName ? null : edit.name,
          userCorrectedPrice:
              edit.price == photo.aiEstimatedPrice ? null : edit.price,
          userCorrectedCalories: edit.calories == photo.aiEstimatedCalories
              ? null
              : edit.calories,
        );
    await LocalDatabase.updateMealPhoto(updated);
    if (!mounted) return;
    ref.invalidate(mealPhotosProvider(widget.mealLogId));
    ref.read(mealLogsProvider.notifier).refresh();
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('記録を削除'),
        content: const Text('この食事記録を削除しますか？\n写真も一緒に削除されます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await ref.read(mealLogsProvider.notifier).deleteMealLog(widget.mealLogId);
      if (context.mounted) Navigator.pop(context);
    }
  }
}
