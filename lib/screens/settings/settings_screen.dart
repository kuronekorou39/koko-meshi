import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';

import '../../database/local_database.dart';
import '../../models/saved_place.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<SavedPlace> _savedPlaces = [];

  @override
  void initState() {
    super.initState();
    _loadSavedPlaces();
  }

  Future<void> _loadSavedPlaces() async {
    final places = await LocalDatabase.getSavedPlaces();
    if (mounted) setState(() => _savedPlaces = places);
  }

  Future<void> _deleteSavedPlace(SavedPlace place) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('場所を削除'),
        content: Text('「${place.name}」を削除しますか？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('削除')),
        ],
      ),
    );

    if (confirmed == true) {
      await LocalDatabase.deleteSavedPlace(place.id);
      _loadSavedPlaces();
    }
  }

  IconData _iconForType(String iconType) {
    return switch (iconType) {
      'home' => Icons.home,
      'favorite' => Icons.star,
      _ => Icons.place,
    };
  }

  Future<String?> _reverseGeocode(double lat, double lng) async {
    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isEmpty) return null;
      final p = placemarks.first;
      final parts = <String>[
        if (p.administrativeArea?.isNotEmpty == true) p.administrativeArea!,
        if (p.locality?.isNotEmpty == true) p.locality!,
        if (p.subLocality?.isNotEmpty == true) p.subLocality!,
        if (p.thoroughfare?.isNotEmpty == true) p.thoroughfare!,
        if (p.subThoroughfare?.isNotEmpty == true) p.subThoroughfare!,
      ];
      return parts.isEmpty ? null : parts.join('');
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          // 保存した場所
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '保存した場所',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey[600]),
            ),
          ),
          if (_savedPlaces.isEmpty)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('保存した場所はありません'),
              subtitle: Text('マップ画面から登録できます'),
            )
          else
            ..._savedPlaces.map((place) => ListTile(
              leading: Icon(_iconForType(place.iconType)),
              title: Text(place.name),
              subtitle: FutureBuilder<String?>(
                future: _reverseGeocode(place.latitude, place.longitude),
                builder: (context, snapshot) {
                  if (snapshot.hasData && snapshot.data != null) {
                    return Text(snapshot.data!, maxLines: 1, overflow: TextOverflow.ellipsis);
                  }
                  return Text(
                    '${place.latitude.toStringAsFixed(4)}, ${place.longitude.toStringAsFixed(4)}',
                  );
                },
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteSavedPlace(place),
              ),
            )),
          const Divider(),

          // アカウント連携
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('アカウント連携'),
            subtitle: const Text('ログインしてクラウドにバックアップ'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: ログイン画面
            },
          ),
          const Divider(),

          // 同期状況
          ListTile(
            leading: const Icon(Icons.cloud_upload),
            title: const Text('同期状況'),
            subtitle: const Text('未ログイン'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: 同期状況の詳細
            },
          ),
          const Divider(),

          // アプリ情報
          const ListTile(
            leading: Icon(Icons.info),
            title: Text('アプリ情報'),
            subtitle: Text('ココメシ v0.1.0'),
          ),
        ],
      ),
    );
  }
}
