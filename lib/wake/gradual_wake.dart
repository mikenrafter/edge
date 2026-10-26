import '../ble/band_buzzer.dart';
import '../state/alarm_schedule.dart';
import 'wake_settings.dart';
import 'wake_stores.dart';

class GradualWake {
  GradualWake({required this.now, required this.store, required this.buzzer});

  final DateTime Function() now;
  final DbWakeStateStore store;
  final BandBuzzer Function() buzzer;
  bool _ticking = false;
  int? _acknowledgedEpoch;
  BandBuzzer? _playing;
  int? _playingEpoch;

  static String _scope(int epoch) => 'gradual:$epoch';

  static AlarmScheduleEntry? entryFor(
      int epoch, List<AlarmScheduleEntry> schedule) {
    final at = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    for (final entry in schedule) {
      if (entry.enabled &&
          entry.weekday == at.weekday - 1 &&
          entry.hour == at.hour && entry.minute == at.minute) {
        return entry;
      }
    }
    return null;
  }

  void cancel(int epoch) {
    final active = _playingEpoch == epoch ? _playing : null;
    active?.stop(_scope(epoch));
    final current = buzzer();
    if (!identical(active, current)) current.stop(_scope(epoch));
  }

  Future<void> acknowledge(int epoch) async {
    _acknowledgedEpoch = epoch;
    cancel(epoch);
    await store.update(epoch, (run) => run['acknowledged'] = true);
  }

  Future<void> tick({required int epoch, required WakeSettings settings,
      required bool Function() canDeliver}) async {
    if (_ticking || !settings.gradualEnabled || !canDeliver()) return;
    _ticking = true;
    try {
      final wakeAt = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
      final steps = GradualWakeSchedule.steps(wakeAt: wakeAt,
          windowMinutes: settings.gradualWindowMinutes,
          cadenceSec: settings.gradualCadenceSec, pattern: settings.gradualPattern);
      final step = await store.update<GradualStep?>(epoch, (run) {
        final at = now();
        if (!at.isBefore(wakeAt)) return null;
        final due = steps.where((s) => !s.at.isAfter(at));
        if (due.isEmpty) return null;
        final latest = due.last;
        if (run['acknowledged'] == true ||
            latest.index < (run['gradualNext'] as int)) {
          return null;
        }
        // Consume even a stale or failed step. Restart must never replay it.
        run['gradualNext'] = latest.index + 1;
        return at.difference(latest.at) <= const Duration(seconds: 90)
            ? latest : null;
      });
      if (step == null || _acknowledgedEpoch == epoch || !canDeliver() ||
          !now().isBefore(wakeAt) ||
          now().difference(step.at) > const Duration(seconds: 90)) {
        return;
      }
      final port = buzzer();
      _playing = port;
      _playingEpoch = epoch;
      await port.play(BandBuzzRequest(
          id: '${_scope(epoch)}:${step.index}', scope: _scope(epoch),
          expiresAt: wakeAt,
          kind: settings.gradualPattern == GradualPattern.ramp
              ? BandBuzzKind.rampStep : BandBuzzKind.steadyStep,
          stepIndex: step.index, stepCount: steps.length, pulses: step.pulses));
    } finally {
      _playing = null;
      _playingEpoch = null;
      _ticking = false;
    }
  }
}
