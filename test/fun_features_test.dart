import 'package:flutter_test/flutter_test.dart';
import 'package:koko_meshi/services/app_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
  });

  test('既定ではどの遊び要素もオフ', () {
    expect(AppSettings.funFeatures, isEmpty);
    for (final f in FunFeature.values) {
      expect(AppSettings.isFunEnabled(f), isFalse);
    }
  });

  test('オンにすると保存され、読み直しても残る', () async {
    await AppSettings.setFunFeature(FunFeature.trace, true);
    expect(AppSettings.isFunEnabled(FunFeature.trace), isTrue);

    // 起動し直した想定で読み直す
    await AppSettings.init();
    expect(AppSettings.isFunEnabled(FunFeature.trace), isTrue);
  });

  test('オフに戻せる', () async {
    await AppSettings.setFunFeature(FunFeature.trace, true);
    await AppSettings.setFunFeature(FunFeature.trace, false);
    expect(AppSettings.isFunEnabled(FunFeature.trace), isFalse);
    expect(AppSettings.funFeatures, isEmpty);
  });

  test('同じものを二重にオンにしても増えない', () async {
    await AppSettings.setFunFeature(FunFeature.trace, true);
    await AppSettings.setFunFeature(FunFeature.trace, true);
    expect(AppSettings.funFeatures.length, 1);
  });

  test('知らない名前が保存されていても無視して読める', () async {
    SharedPreferences.setMockInitialValues({
      'fun_features': ['trace', 'removed_feature'],
    });
    await AppSettings.init();
    expect(AppSettings.funFeatures, {FunFeature.trace});
  });

  test('項目には表示に必要な文言がそろっている', () {
    for (final f in FunFeature.values) {
      expect(f.label, isNotEmpty);
      expect(f.description, isNotEmpty);
      expect(f.hint, isNotEmpty, reason: 'オンにしたあとの置き場所を案内する');
    }
  });
}
