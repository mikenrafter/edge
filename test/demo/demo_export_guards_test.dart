import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/data/auto_backup.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  int documentRequests = 0;
  @override
  Future<String?> getApplicationDocumentsPath() async {
    documentRequests++;
    return root;
  }

  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
}

class _PermissionSpy extends AppState {
  _PermissionSpy() : super.forTesting();
  int permissionRequests = 0;
  @override
  Future<void> requestHealth() async {
    permissionRequests++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late _Paths paths;
  final calls = <MethodCall>[];
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({Prefs.demoModeEnabled: true});
    await Prefs.ensureLoaded();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    temp = await Directory.systemTemp.createTemp('edge_demo_exports_');
    paths = _Paths(temp.path);
    PathProviderPlatform.instance = paths;
    LocalDb.dbName = '${temp.path}/fixture.db';
    await LocalDb.putDayResult(
      dayId: '2026-09-28',
      algoVersion: 97,
      payloadJson: '{"date":"2026-09-28","scalars":{"rhr":55,"readiness":88}}',
      windowJson: '{}',
      finalized: true,
      series: {'readiness': 88},
      source: 'demo',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/device_info'),
          (_) async => <String, Object?>{
            'identifierForVendor': 'fictional-test-device',
            'isPhysicalDevice': false,
            'utsname': <String, Object?>{},
          },
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_health'), (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'getHealthData') return <Object>[];
          if (call.method == 'getDataTypes') return <Object>[];
          return true;
        });
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/device_info'),
          null,
        );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_health'), null);
    await LocalDb.close();
    await temp.delete(recursive: true);
  });
  setUp(() {
    calls.clear();
    paths.documentRequests = 0;
  });
  test(
    'manual and scheduled backups in demo mode never reach the file sink',
    () async {
      final app = AppState.forTesting();
      final outcome = await app.runBackupNow();
      expect(outcome.skipped, true);
      Prefs.setString(Prefs.backupCadence, BackupCadence.daily.name);
      expect(app.backupCadence, BackupCadence.daily);
      await app.runBackupIfDue();
      expect(paths.documentRequests, 0);
      expect(
        temp
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (f) => f.path.endsWith('.gz') || f.path.endsWith('.partial'),
            ),
        isEmpty,
      );
    },
  );
  test(
    'enabling health sync in demo mode saves preference without requesting access',
    () async {
      final app = _PermissionSpy();
      await app.setHealthSync(true);
      expect(app.healthSyncEnabled, true);
      expect(app.permissionRequests, 0);
      expect(calls, isEmpty);
      Prefs.setBool(Prefs.demoModeEnabled, false);
      await app.setHealthSync(true);
      expect(
        app.permissionRequests,
        1,
        reason: 'positive control proves spy catches permission dispatch',
      );
      Prefs.setBool(Prefs.demoModeEnabled, true);
    },
  );
  test(
    'manual health export in demo mode never contacts the platform health store',
    () async {
      final app = AppState.forTesting();
      final written = await app.healthSyncNow();
      expect(
        calls,
        isEmpty,
        reason: 'demo samples cannot cross the external health boundary',
      );
      expect(written, 0);
      expect(
        await LocalDb.getCursor('health_export_through'),
        anyOf(isNull, isEmpty),
        reason: 'demo suppression cannot advance real export progress',
      );
    },
  );
}
