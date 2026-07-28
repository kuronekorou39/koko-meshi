import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/models/meal_photo.dart';
import 'package:koko_meshi/services/app_settings_service.dart';
import 'package:koko_meshi/services/device_capability.dart';
import 'package:koko_meshi/widgets/meal_ai_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 端末側の対応可否を差し替える。MethodChannel を偽装して
/// [DeviceCapability.init] を通すので、判定の経路ごと確かめられる。
Future<void> setDeviceAiSupported(bool supported) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.kokomeshi.koko_meshi/device'),
    (call) async => call.method == 'isOnDeviceAiSupported' ? supported : null,
  );
  await DeviceCapability.init();
}

MealPhoto photo(String status, {bool skipAi = false}) => MealPhoto(
      id: 'p-$status-$skipAi',
      mealLogId: 'log',
      localPath: '/tmp/x.jpg',
      aiStatus: status,
      skipAi: skipAi,
      shotAt: DateTime(2026, 7, 27, 12),
      createdAt: DateTime(2026, 7, 27, 12),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    // 各テストは「AIが動く端末」から始める
    await setDeviceAiSupported(true);
  });

  group('resolveMealAiState (AI解析オン・モデルあり)', () {
    test('解析中の写真があれば analyzing', () {
      final state = resolveMealAiState(
        [photo('completed'), photo('processing')],
        modelInstalled: true,
      );
      expect(state, MealAiState.analyzing);
    });

    test('pending だけなら queued（回さない）', () {
      final state = resolveMealAiState([photo('pending')], modelInstalled: true);
      expect(state, MealAiState.queued);
    });

    test('モデルの確認が済んでいなくても待ち側に倒す', () {
      final state =
          resolveMealAiState([photo('pending')], modelInstalled: null);
      expect(state, MealAiState.queued);
    });

    test('全部 completed なら none', () {
      final state =
          resolveMealAiState([photo('completed')], modelInstalled: true);
      expect(state, MealAiState.none);
    });

    test('スキップした写真は待ち扱いしない', () {
      final state = resolveMealAiState(
        [photo('pending', skipAi: true), photo('skipped')],
        modelInstalled: true,
      );
      expect(state, MealAiState.none);
    });

    test('失敗した写真は failed として出す', () {
      final state =
          resolveMealAiState([photo('failed')], modelInstalled: true);
      expect(state, MealAiState.failed);
    });

    test('解析中の写真があれば失敗より解析中を優先する', () {
      final state = resolveMealAiState(
        [photo('failed'), photo('processing')],
        modelInstalled: true,
      );
      expect(state, MealAiState.analyzing);
    });
  });

  group('resolveMealAiState (解析が始まらない条件)', () {
    test('モデル未DLなら pending は modelMissing', () {
      final state =
          resolveMealAiState([photo('pending')], modelInstalled: false);
      expect(state, MealAiState.modelMissing);
    });

    test('モデル未DLなら processing でも回さない（中断のまま残った写真）', () {
      final state =
          resolveMealAiState([photo('processing')], modelInstalled: false);
      expect(state, MealAiState.modelMissing);
    });

    test('AI解析オフなら aiOff', () async {
      await AppSettings.setAiMode(AiAnalysisMode.off);
      final state = resolveMealAiState(
        [photo('pending'), photo('processing')],
        modelInstalled: true,
      );
      expect(state, MealAiState.aiOff);
    });

    test('端末内AI非対応なら、モデル未DLより先に deviceUnsupported', () async {
      await setDeviceAiSupported(false);
      expect(
        resolveMealAiState([photo('pending')], modelInstalled: false),
        MealAiState.deviceUnsupported,
      );
    });

    test('端末内AI非対応なら processing でも回さない', () async {
      await setDeviceAiSupported(false);
      expect(
        resolveMealAiState([photo('processing')], modelInstalled: true),
        MealAiState.deviceUnsupported,
      );
    });

    test('端末内AI非対応でも、解析済みなら何も出さない', () async {
      await setDeviceAiSupported(false);
      expect(
        resolveMealAiState([photo('completed')], modelInstalled: false),
        MealAiState.none,
      );
    });
  });

  group('hasMealAiStatus', () {
    test('待ち・解析中・失敗があれば true', () {
      for (final s in ['pending', 'processing', 'failed']) {
        expect(hasMealAiStatus([photo(s)]), isTrue, reason: s);
      }
    });

    test('解析済み・スキップだけなら false', () {
      expect(
        hasMealAiStatus([photo('completed'), photo('pending', skipAi: true)]),
        isFalse,
      );
    });
  });
}
