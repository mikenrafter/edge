import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/state/power_source.dart';
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:openstrap_edge/sync/ios_bg_task.dart';

import '../p5/support/fake_power_source.dart';

class _UnavailablePowerSource implements PowerSource {
  @override
  Stream<PowerState> get changes => const Stream.empty();

  @override
  Future<PowerState> read() =>
      Future<PowerState>.error(StateError('unavailable'));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  Future<void> saveMode(CalcPowerMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('calc_power_mode', mode.name);
  }

  test('headless drain holds only its automatic derive in Maximum battery',
      () async {
    await saveMode(CalcPowerMode.maxBattery);
    final held = FakePowerSource(charging: false, powerSaver: true);
    expect(await mayRunHeadlessAutomaticDerive(powerSource: held), isFalse);

    await saveMode(CalcPowerMode.balanced);
    expect(await mayRunHeadlessAutomaticDerive(powerSource: held), isTrue);
  });

  test('an unavailable power API leaves automatic headless derives allowed',
      () async {
    await saveMode(CalcPowerMode.maxBattery);
    expect(await mayRunHeadlessAutomaticDerive(
        powerSource: _UnavailablePowerSource()), isTrue);
  });

  // Both entries build their own DerivationEngine, so the gate has to sit in
  // front of every one of them (AGENTS 4.7). Each entry is driven with a
  // recording engine factory and a scripted power source: a blocked mode must
  // construct and run nothing, an allowed one must run.
  group('headless entries behind the power gate', () {
    late List<String> built;
    late List<String> ran;

    setUp(() {
      built = [];
      ran = [];
      debugHeadlessEngineFactory = ({log, background = false}) {
        built.add('background=$background');
        return _RecordingEngine(ran, background: background);
      };
      IosBleRestore.foregroundActive = true; // no headless BLE in the test
    });

    tearDown(() {
      debugHeadlessEngineFactory = null;
      debugHeadlessPowerSource = null;
      IosBleRestore.foregroundActive = false;
    });

    final blocked = FakePowerSource(charging: false, powerSaver: true);
    final free = FakePowerSource(charging: true, powerSaver: false);

    test('the post-drain derive of background_sync builds and runs nothing '
        'when blocked', () async {
      await saveMode(CalcPowerMode.maxBattery);
      debugHeadlessPowerSource = blocked;
      await headlessDeriveAfterSync();
      expect(built, isEmpty);
      expect(ran, isEmpty);
    });

    test('...and runs one light pass when the mode allows it', () async {
      await saveMode(CalcPowerMode.maxBattery);
      debugHeadlessPowerSource = free;
      await headlessDeriveAfterSync();
      expect(built, ['background=true']);
      expect(ran, ['run']);
    });

    for (final syncOnly in [false, true]) {
      final entry = syncOnly ? 'the iOS refresh task' : 'the iOS processing task';

      test('$entry builds and runs nothing when blocked', () async {
        await saveMode(CalcPowerMode.maxBattery);
        debugHeadlessPowerSource = blocked;
        expect(await IosBgTask.runForTest(syncOnly: syncOnly), isTrue);
        expect(built, isEmpty);
        expect(ran, isEmpty);
      });

      test('$entry runs its derive when the mode allows it', () async {
        await saveMode(CalcPowerMode.maxBattery);
        debugHeadlessPowerSource = free;
        expect(await IosBgTask.runForTest(syncOnly: syncOnly), isTrue);
        expect(built, ['background=true']);
        expect(ran, syncOnly ? ['run'] : ['run', 'rescanRecent']);
      });
    }
  });
}

/// A [DerivationEngine] that records the passes it is asked for and computes
/// nothing.
class _RecordingEngine extends DerivationEngine {
  _RecordingEngine(this.calls, {required super.background});
  final List<String> calls;

  @override
  Future<int> run(
    Profile profile, {
    bool heavy = false,
    bool force = false,
    bool changedOnly = false,
    ana.CalculationMode calculationMode = ana.CalculationMode.forced,
    void Function(String day, int index, int total)? onDayDone,
    void Function(int total)? onScope,
    void Function(List<String> days)? onScopeDays,
    void Function(bool active)? onCrossDay,
  }) async {
    calls.add('run');
    return 0;
  }

  @override
  Future<int> rescanRecent(
    Profile profile, {
    void Function(String day, int index, int total)? onDayDone,
    void Function(List<String> days)? onScopeDays,
  }) async {
    calls.add('rescanRecent');
    return 0;
  }
}
