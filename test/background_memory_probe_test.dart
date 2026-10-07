// ignore_for_file: depend_on_referenced_packages
// Memory probe, opt-in: BGMEM_PROBE=1 flutter test --enable-vmservice <this file>
//
// Builds the incremental state of a 16 h awake day (full pass, then a periodic
// awake pass) and reports the heap each part keeps, measured by the VM after a
// collection. Host side only; use the `[perf] mem` log lines for a device.
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:vm_service/vm_service_io.dart' as vmio;

import 'support/incremental_activity_fixture.dart';
import 'support/incremental_day_fixture.dart';

const _profile = Profile(ageYears: 35, weightKg: 75, heightCm: 178, sex: 'male');
const _seconds = 16 * 3600;

ana.CalculationMode _mode(int pass) =>
    pass == 0 ? ana.CalculationMode.sleep : ana.CalculationMode.periodicAwake;

void main() {
  test('retained heap of one day state', () async {
    final info = await dev.Service.controlWebServer(enable: true);
    final svc =
        await vmio.vmServiceConnectUri(info.serverWebSocketUri.toString());
    final iso = dev.Service.getIsolateId(Isolate.current)!;
    Future<int> heap() async =>
        (await svc.getAllocationProfile(iso, gc: true)).memoryUsage!.heapUsage!;

    final subs = [
      incrementalActivity(seconds: _seconds - 600),
      incrementalActivity(seconds: _seconds)
    ];
    final days = [
      incrementalDay(daySeconds: _seconds - 600, nightSeconds: 8 * 3600),
      incrementalDay(daySeconds: _seconds, nightSeconds: 8 * 3600)
    ];
    final keep = <Object>[];
    var last = await heap();
    final out = StringBuffer('retained heap, one 16 h day state:\n');
    Future<DayCalculationState> part(
        String name, void Function(DayCalculationState st, int pass) f) async {
      final st = DayCalculationState();
      f(st, 0);
      f(st, 1);
      keep.add(st);
      final h = await heap();
      out.writeln('  $name ${((h - last) / 1e6).toStringAsFixed(2)} MB '
          '(cache computed=${st.computations} hits=${st.hits})');
      last = h;
      return st;
    }

    final activity = await part('applyDayActivity  ', (st, p) {
      final s = subs[p];
      DerivationEngine.applyDayActivity(
        bundle: <String, dynamic>{}, scalars: <String, dynamic>{}, daySub: s,
        profile: _profile, sleepOnsetSec: 0, sleepOffsetSec: 0,
        dayStartSec: s.tsSec.first, dayCalendarEndSec: s.tsSec.first + 86400,
        dataNowSec: s.tsSec.last + 1, restingHr: 54, dynFloorG: .03,
        dynHistoryDays: 14, liveStepsReal: 0, liveStepsFromStrap: 0,
        state: st, mode: _mode(p));
      st.motionMinutes([
        for (var i = 0; i < s.length; i++)
          ana.AccelSample(s.tsSec[i] * 1000.0, s.ax[i], s.ay[i], s.az[i])
      ], _mode(p));
    });
    await part('dayHrvCurve        ', (st, p) =>
        DerivationEngine.dayHrvCurve(subs[p], state: st, mode: _mode(p)));
    await part('dayRespCurve       ', (st, p) =>
        DerivationEngine.dayRespCurve(subs[p], state: st, mode: _mode(p)));
    await part('deriveDayBundle    ', (st, p) =>
        deriveDayBundle(copyDay(days[p]), state: st, mode: _mode(p)));
    final before = await heap();
    activity.compact();
    final after = await heap();
    out.writeln('  compact() on the activity state frees '
        '${((before - after) / 1e6).toStringAsFixed(2)} MB');
    // ignore: avoid_print
    print(out);
    expect(keep, isNotEmpty);
  },
      skip: Platform.environment['BGMEM_PROBE'] != '1',
      timeout: const Timeout(Duration(minutes: 20)));
}
