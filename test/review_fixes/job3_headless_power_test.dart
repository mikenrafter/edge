import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/state/power_source.dart';
import 'package:openstrap_edge/sync/background_sync.dart';

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
  // front of every one of them (AGENTS 4.7). Pinned by source, as the other
  // entry-point wiring is: the entries need a band and a platform to run.
  test('every headless DerivationEngine is built behind the power gate', () {
    for (final entry in {
      'lib/sync/background_sync.dart': 'mayRunHeadlessAutomaticDerive()',
      'lib/sync/ios_bg_task.dart': 'mayRunHeadlessAutomaticDerive()',
    }.entries) {
      final src = File(entry.key).readAsStringSync();
      final gate = src.indexOf(entry.value);
      expect(gate, greaterThan(0), reason: '${entry.key} asks the gate');
      var from = 0, engines = 0;
      while (true) {
        final at = src.indexOf('DerivationEngine(', from);
        if (at < 0) break;
        engines++;
        expect(at, greaterThan(gate),
            reason: '${entry.key}: an engine built before the gate');
        from = at + 1;
      }
      expect(engines, greaterThan(0));
    }
  });
}
