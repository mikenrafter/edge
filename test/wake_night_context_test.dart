import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/wake_night_context.dart';
import 'package:openstrap_edge/wake/wake_confounders.dart';
import 'package:openstrap_edge/state/control_operations.dart';

class Source implements WakeNightSource {
  String rev = 'a';
  int reads = 0;
  bool fail = false;
  bool failProfile = false, editDuringRead = false;
  DateTime? bedtime;
  (DateTime, DateTime)? range;
  @override
  Future<String> revision(DateTime from, DateTime to) async {
    if (fail) throw StateError('private journal');
    return rev;
  }

  @override
  Future<ConfounderProfile> profile(
    DateTime from,
    DateTime to,
    DateTime? expectedBedtime,
  ) async {
    reads++;
    bedtime = expectedBedtime;
    range = (from, to);
    if (failProfile) throw StateError('private journal');
    if (editDuringRead) rev = 'edited';
    return const ConfounderProfile(hrArousalBpm: 6, alcohol: true);
  }
}

void main() {
  test(
    'cache keys occurrence, schedule identity and journal revision',
    () async {
      final source = Source();
      final owner = WakeNightContext(source);
      final wake = DateTime(2026, 10, 26, 7);
      const schedule = ExpectedSleepSchedule(
        onsetMinute: 22 * 60,
        wakeMinute: 7 * 60,
      );
      expect((await owner.load(wake, schedule)).profile.hrArousalBpm, 6);
      expect(source.bedtime, DateTime(2026, 10, 25, 22));
      await owner.load(wake, schedule);
      expect(source.reads, 1);
      source.rev = 'b';
      await owner.load(wake, schedule);
      expect(source.reads, 2);
      await owner.load(
        wake,
        const ExpectedSleepSchedule(onsetMinute: 21 * 60, wakeMinute: 7 * 60),
      );
      expect(source.reads, 3);
      await owner.load(wake.add(const Duration(days: 1)), schedule);
      expect(source.reads, 4);
    },
  );
  test('read failure defaults with neutral diagnostics and retries', () async {
    final source = Source()..fail = true;
    final owner = WakeNightContext(source);
    final value = await owner.load(DateTime(2026, 10, 26, 7), null);
    expect(value.profile, const ConfounderProfile());
    expect(value.diagnostic, 'context_unavailable');
    source.fail = false;
    expect(
      (await owner.load(DateTime(2026, 10, 26, 7), null)).profile.hrArousalBpm,
      6,
    );
  });
  test('morning schedule uses actual saved onset', () async {
    final source = Source();
    await WakeNightContext(source).load(
      DateTime(2026, 10, 26, 16),
      const ExpectedSleepSchedule(onsetMinute: 8 * 60, wakeMinute: 16 * 60),
    );
    expect(source.bedtime, DateTime(2026, 10, 26, 8));
  });
  test(
    'cross-midnight bedtime loads both dates, fallback has no saved bedtime',
    () async {
      final source = Source();
      final owner = WakeNightContext(source);
      final wake = DateTime(2026, 10, 26, 9);
      await owner.load(
        wake,
        const ExpectedSleepSchedule(onsetMinute: 60, wakeMinute: 9 * 60),
      );
      expect(source.range, (DateTime(2026, 10, 25), DateTime(2026, 10, 27)));
      expect(source.bedtime, DateTime(2026, 10, 26, 1));
      await owner.load(wake, null);
      expect(source.bedtime, isNull);
      expect(source.range, (DateTime(2026, 10, 25), DateTime(2026, 10, 26)));
    },
  );
  test(
    'profile read failures and concurrent edits never cache an old profile',
    () async {
      final source = Source();
      final owner = WakeNightContext(source);
      final wake = DateTime(2026, 10, 26, 7);
      await owner.load(wake, null);
      source.rev = 'b';
      source.failProfile = true;
      final failed = await owner.load(wake, null);
      expect(failed.profile, const ConfounderProfile());
      expect(failed.diagnostic, 'context_unavailable');
      source.failProfile = false;
      source.editDuringRead = true;
      final changed = await owner.load(wake, null);
      expect(changed.profile, const ConfounderProfile());
      expect(changed.diagnostic, 'context_changed');
      source.editDuringRead = false;
      expect((await owner.load(wake, null)).diagnostic, 'context_ready');
      expect(source.reads, 4);
    },
  );
}
