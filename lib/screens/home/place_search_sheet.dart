import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/places_service.dart';
import '../../theme/app_theme.dart';

/// 周辺検索の条件を決めるシート。決定したら新しい条件を返す(取り消しは null)。
///
/// 20件しか返らないAPIなので、条件を細かく指定できることが「たくさん出す」
/// ことの代わりになる。半径とカテゴリを絞れば、その中の20件が返る。
Future<PlaceSearchOptions?> showPlaceSearchOptions(
  BuildContext context,
  PlaceSearchOptions current,
) {
  return showModalBottomSheet<PlaceSearchOptions>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PlaceSearchOptionsSheet(initial: current),
  );
}

class _PlaceSearchOptionsSheet extends StatefulWidget {
  const _PlaceSearchOptionsSheet({required this.initial});

  final PlaceSearchOptions initial;

  @override
  State<_PlaceSearchOptionsSheet> createState() =>
      _PlaceSearchOptionsSheetState();
}

class _PlaceSearchOptionsSheetState extends State<_PlaceSearchOptionsSheet> {
  late PlaceSearchOptions _options = widget.initial;
  late final _keywordController =
      TextEditingController(text: widget.initial.keyword ?? '');

  static const _radiusChoices = <double>[300, 500, 1000, 2000];
  static const _ratingChoices = <double?>[null, 3.5, 4.0, 4.5];
  static const _priceChoices = <int?>[null, 1, 2, 3];

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);

    return SafeArea(
      child: Padding(
        // キーボードが出ても入力欄が隠れないように持ち上げる
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('お店をさがす',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    if (_options.hasNarrowing)
                      TextButton(
                        onPressed: () {
                          _keywordController.clear();
                          setState(() => _options = PlaceSearchOptions(
                                radiusMeters: _options.radiusMeters,
                                sort: _options.sort,
                              ));
                        },
                        child: const Text('リセット'),
                      ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      color: tokens.textMuted,
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(),
                const SizedBox(height: 12),

                _label('キーワード'),
                TextField(
                  controller: _keywordController,
                  decoration: const InputDecoration(
                    hintText: '店名の一部（例: らーめん）',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 20),
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _submit(),
                ),
                // 追加の呼び出しをしないことを明示しておく(費用の話に効く)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '取得した店名・住所から絞り込みます',
                    style: TextStyle(fontSize: 11, color: tokens.textFaint),
                  ),
                ),
                const SizedBox(height: 18),

                _label('ジャンル'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in PlaceCategory.values)
                      _chip(
                        c.label,
                        _options.category == c,
                        () => setState(
                            () => _options = _options.copyWith(category: c)),
                      ),
                  ],
                ),
                const SizedBox(height: 18),

                _label('範囲'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final r in _radiusChoices)
                      _chip(
                        r >= 1000
                            ? '${(r / 1000).toStringAsFixed(r % 1000 == 0 ? 0 : 1)}km'
                            : '${r.toInt()}m',
                        _options.radiusMeters == r,
                        () => setState(() =>
                            _options = _options.copyWith(radiusMeters: r)),
                      ),
                  ],
                ),
                const SizedBox(height: 18),

                _label('並び順'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in PlaceSortOrder.values)
                      _chip(
                        s.label,
                        _options.sort == s,
                        () =>
                            setState(() => _options = _options.copyWith(sort: s)),
                      ),
                  ],
                ),
                const SizedBox(height: 18),

                _label('評価'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final r in _ratingChoices)
                      _chip(
                        r == null ? '指定なし' : '★$r 以上',
                        _options.minRating == r,
                        () => setState(() => _options = r == null
                            ? _options.copyWith(clearMinRating: true)
                            : _options.copyWith(minRating: r)),
                      ),
                  ],
                ),
                const SizedBox(height: 18),

                _label('価格帯'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final p in _priceChoices)
                      _chip(
                        p == null ? '指定なし' : '${'¥' * p} まで',
                        _options.maxPriceLevel == p,
                        () => setState(() => _options = p == null
                            ? _options.copyWith(clearMaxPriceLevel: true)
                            : _options.copyWith(maxPriceLevel: p)),
                      ),
                  ],
                ),
                const SizedBox(height: 24),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.search),
                    label: const Text('この条件でさがす'),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    '1回の検索で最大20件まで取得します',
                    style: TextStyle(fontSize: 11, color: tokens.textFaint),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _submit() {
    final kw = _keywordController.text.trim();
    Navigator.pop(
      context,
      kw.isEmpty
          ? _options.copyWith(clearKeyword: true)
          : _options.copyWith(keyword: kw),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: KokoTokens.of(context).sectionLabel),
      );

  Widget _chip(String label, bool selected, VoidCallback onTap) => FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      );
}

/// 検索結果の一覧。並び順を指定できても、地図上のピンだけでは順序が見えない
/// ので一覧で見せる。タップでその店へ寄る。
class PlaceSearchResultList extends StatelessWidget {
  const PlaceSearchResultList({
    super.key,
    required this.places,
    required this.centerLat,
    required this.centerLng,
    required this.options,
    required this.onTapPlace,
    required this.onClose,
  });

  final List<PlaceInfo> places;
  final double centerLat;
  final double centerLng;
  final PlaceSearchOptions options;
  final ValueChanged<PlaceInfo> onTapPlace;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = KokoTokens.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${places.length}件 ・ ${options.sort.label}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                color: tokens.textMuted,
                onPressed: onClose,
              ),
            ],
          ),
        ),
        // 20件に張り付いたときは、外に取りこぼしがあることを伝える。
        // 黙って切ると「この辺にはこれだけしか無い」と読めてしまう
        if (places.length >= 20)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 14, color: tokens.textFaint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '取得上限です。範囲やジャンルを絞ると他の店が出ます',
                    style: TextStyle(fontSize: 11, color: tokens.textFaint),
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 1),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: places.length,
            separatorBuilder: (_, _) =>
                const Divider(height: 1, indent: 16, endIndent: 16),
            itemBuilder: (context, i) => _tile(context, places[i], tokens),
          ),
        ),
      ],
    );
  }

  Widget _tile(BuildContext context, PlaceInfo place, KokoTokens tokens) {
    final meta = <String>[];
    if (place.rating != null) {
      final count = place.userRatingCount;
      meta.add('★${place.rating!.toStringAsFixed(1)}'
          '${count == null ? '' : '($count)'}');
    }
    final price = place.priceLabel;
    if (price != null) meta.add(price);
    meta.add(_distanceLabel(place));

    return ListTile(
      dense: true,
      title: Text(
        place.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            meta.join(' ・ '),
            style: tokens.numeral.copyWith(fontSize: 12, color: tokens.textMuted),
          ),
          if (place.address != null)
            Text(
              place.address!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: tokens.textFaint),
            ),
        ],
      ),
      onTap: () => onTapPlace(place),
    );
  }

  String _distanceLabel(PlaceInfo place) {
    final dLat = (place.latitude - centerLat) * 111320;
    final dLng = (place.longitude - centerLng) *
        111320 *
        math.cos(centerLat * math.pi / 180);
    final m = math.sqrt(dLat * dLat + dLng * dLng);
    return m >= 1000 ? '${(m / 1000).toStringAsFixed(1)}km' : '${m.round()}m';
  }
}
