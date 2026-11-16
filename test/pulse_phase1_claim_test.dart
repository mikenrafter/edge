// Exactly-once delivery of a flagged day's alert, across crashes and across the
// foreground and background passes. `pulse_alert` is the claim: a day moves to
// `pending` BEFORE anything is shown, only the claimer may show it, a pending
// row left behind becomes `unknown` and is never sent again, and one day is
// never named by both an alert and a summary.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:openstrap_edge/compute/pulse_alert_delivery.dart';
import 'package:openstrap_edge/compute/pulse_alert_record.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _flag = 'irregular_rhythm_flag';

class _Crash implements Exception {}

/// Pauses or kills a pass at the points the delivery exposes.
class _Probe extends PulseDeliveryProbe {
  _Probe({this.owed, this.present, this.targets});
  final Future<void> Function()? owed;
  final Future<void> Function()? present;
  final Future<Set<String>?> Function(NotificationEvent)? targets;

  @override
  Future<void> afterOwed() => owed?.call() ?? Future<void>.value();

  @override
  Future<void> afterPresent() => present?.call() ?? Future<void>.value();

  @override
  Future<Set<String>?> emit(NotificationEvent e) =>
      targets?.call(e) ?? Future<Set<String>?>.value(null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shown = <NotificationEvent>[];
  final original = NotificationCenter.instance.presentSink;
  late String path;
  late String today;
  Future<bool> Function(NotificationEvent e) onPresent = (e) async => true;

  String daysAgo(int n) => dayLabelBefore(today, n)!;
  String niceDay(String d) => DateFormat.yMMMEd('en').format(DateTime.parse(d));

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'pulse_phase1_claim.db';
    path = p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName);
    await databaseFactory.deleteDatabase(path);
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    NotificationIds.instance.resetForTest();
    shown.clear();
    onPresent = (e) async => true;
    NotificationCenter.instance.presentSink =
        (e, {bool allowPermissionPrompt = true}) async {
          if (!await onPresent(e)) return false;
          shown.add(e);
          return true;
        };
    today = dayLabelOf(DateTime.now());
  });
  tearDown(() async {
    PulseAlertDelivery.probe = const PulseDeliveryProbe();
    NotificationCenter.instance.presentSink = original;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(path);
  });

  Future<void> flag(String d) => LocalDb.putMetricSeriesValue(d, _flag, 1);
  Future<PulseAlertRecord?> record(String d) async =>
      (await LocalDb.pulseAlertRecords())[d];

  // CLAIM health-alert-read: the production repository must serve the actual
  // durable ledger, rather than inheriting the optional empty implementation.
  // catches: forgetting the LocalRepositoryImpl override after moving the read.
  test('Health repository preserves stored alert outcomes', () async {
    await LocalDb.recordPulseAlert([today],
        state: PulseAlertState.notSent, atMs: 1794499200000,
        reason: PulseAlertReason.quiet);
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    final records = await repo.getPulseAlertRecords();
    expect(records.keys, [today]);
    expect(records[today]!.state, PulseAlertState.notSent);
    expect(records[today]!.reason, PulseAlertReason.quiet);
    expect(records[today]!.atMs, 1794499200000);
    expect((await record(today))!.state, PulseAlertState.notSent,
        reason: 'reading presentation metadata cannot change delivery state');
  });

  // why: R2-DS1(a). A summary is on screen and the process dies before its
  // record is written. A later pass finds another flagged day: the new summary
  // must name only that day, because the first two were already named.
  // proves: CLAIM(pulse-claim); catches: a summary key that is a fingerprint of
  // the day set, which changes when the set grows.
  test('a summary shown before its record was written is never repeated',
      () async {
    final a = daysAgo(5), b = daysAgo(4), e = daysAgo(2);
    await flag(a);
    await flag(b);
    PulseAlertDelivery.probe = _Probe(present: () async => throw _Crash());
    await expectLater(PulseAlertDelivery.run(), throwsA(isA<_Crash>()));
    expect(shown, hasLength(1));
    expect(shown.single.body, allOf(contains(niceDay(a)), contains(niceDay(b))));

    PulseAlertDelivery.probe = const PulseDeliveryProbe();
    await flag(e);
    await PulseAlertDelivery.run(pendingGrace: Duration.zero);
    expect(shown, hasLength(2));
    expect(shown.last.body, contains(niceDay(e)));
    expect(shown.last.body, isNot(contains(niceDay(a))));
    expect(shown.last.body, isNot(contains(niceDay(b))));
    expect((await record(a))!.state, PulseAlertState.unknown);
    expect((await record(b))!.state, PulseAlertState.unknown);
    expect((await record(e))!.state, PulseAlertState.summary);
    await PulseAlertDelivery.run(pendingGrace: Duration.zero);
    expect(shown, hasLength(2), reason: 'unknown is never owed again');
  });

  // why: R2-DS1(b). The background pass announces a day on its own while the
  // foreground's nothing-changed pass sweeps up unsent days. The atomic claim
  // is per DAY, so one of them shows it and the other leaves it alone.
  // proves: CLAIM(pulse-claim); catches: a claim on the notification key only.
  test('two passes in flight never name the same day twice', () async {
    final d = daysAgo(1);
    await flag(d);
    final gate = Completer<void>();
    final reached = Completer<void>();
    onPresent = (e) async {
      if (!reached.isCompleted) reached.complete();
      await gate.future;
      return true;
    };
    final background = PulseAlertDelivery.run(individualDays: {d});
    await reached.future; // the background pass has claimed D and is presenting
    // Foreground pass, default grace: D is pending and young, so it stays.
    await PulseAlertDelivery.run();
    expect(shown, isEmpty);
    expect((await record(d))!.state, PulseAlertState.pending,
        reason: 'a young claim is left alone, not relabelled');
    gate.complete();
    await background;
    expect(shown, hasLength(1));
    expect(shown.single.dedupeKey, '$d:irregular-pulse');
    expect((await record(d))!.state, PulseAlertState.sent);
  });

  // why: the same race with no gate at all: whichever pass wins the claim shows
  // the day, and the other shows nothing for it.
  test('racing an individual alert against a summary names the day once',
      () async {
    final d = daysAgo(1);
    await flag(d);
    onPresent = (e) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return true;
    };
    await Future.wait([
      PulseAlertDelivery.run(individualDays: {d}),
      PulseAlertDelivery.run(),
      PulseAlertDelivery.run(),
    ]);
    expect(shown, hasLength(1));
    final s = (await record(d))!.state;
    expect(s, anyOf(PulseAlertState.sent, PulseAlertState.summary));
  });

  // why: R2-DS1(c). The process dies after the OS key is claimed and before the
  // alert reaches the screen. Nothing was shown, so the row must not say "sent":
  // it says delivery is unknown, stamped with when the key was claimed, and the
  // day is never sent again.
  // proves: CLAIM(pulse-claim); catches: reconciling a claimed key to `sent`.
  test('a death after the key claim and before the show is unknown, not sent',
      () async {
    final d = daysAgo(1);
    await flag(d);
    final hung = Completer<bool>();
    final reached = Completer<void>();
    onPresent = (e) {
      reached.complete();
      return hung.future; // the process never gets past the present
    };
    final dying = PulseAlertDelivery.run(individualDays: {d});
    int? claimedAt;
    try {
      await reached.future;
      claimedAt = await LocalDb.notifFiredAt('$d:irregular-pulse');
      expect(claimedAt, isNotNull);
      expect((await record(d))!.state, PulseAlertState.pending);

      await PulseAlertDelivery.run(
        individualDays: {d},
        pendingGrace: Duration.zero,
      );
      expect(shown, isEmpty);
      final r = (await record(d))!;
      expect(r.state, PulseAlertState.unknown);
      expect(r.atMs, claimedAt, reason: 'the claim time, not this pass');
    } finally {
      hung.complete(true); // the pass was slow, not dead: it shows and finishes
      await dying;
    }
    // The truth wins: the guess is overwritten with what really happened, at the
    // time the pass itself finished.
    final truth = (await record(d))!;
    expect(shown, hasLength(1));
    expect(truth.state, PulseAlertState.sent);
    expect(truth.atMs, greaterThan(claimedAt!));
  });

  // why: R3-T1, the other half. A slow pass whose present finally reports that
  // nothing was shown overwrites `unknown` with `not_sent`, so the day is owed
  // again and the next pass announces it.
  // proves: CLAIM(pulse-claim); catches: dropping 'unknown' from the finish's IN list.
  test('a slow pass that shows nothing turns unknown into not sent, then a summary',
      () async {
    final d = daysAgo(1);
    await flag(d);
    final hung = Completer<bool>();
    final reached = Completer<void>();
    onPresent = (e) {
      if (!reached.isCompleted) reached.complete();
      return hung.future;
    };
    final slow = PulseAlertDelivery.run(individualDays: {d});
    try {
      await reached.future;
      await PulseAlertDelivery.run(pendingGrace: Duration.zero);
      expect((await record(d))!.state, PulseAlertState.unknown);
    } finally {
      hung.complete(false);
      await slow;
    }
    expect(shown, isEmpty);
    final r = (await record(d))!;
    expect(r.state, PulseAlertState.notSent);
    onPresent = (e) async => true;
    await PulseAlertDelivery.run();
    expect(shown, hasLength(1));
    expect(shown.single.dedupeKey, startsWith('pulse-summary:'));
    expect((await record(d))!.state, PulseAlertState.summary);
  });

  // why: R2-DS1(b), the exact window. The foreground reads the owed days, then
  // the background announces one on its own before the foreground claims it.
  // The claim is per day and atomic, so the foreground loses it and shows nothing.
  // proves: CLAIM(pulse-claim); catches: showing a day whose claim was lost.
  test('a pass that loses the claim to another pass shows nothing for the day',
      () async {
    final d = daysAgo(1);
    await flag(d);
    final paused = Completer<void>();
    final resume = Completer<void>();
    var first = true;
    PulseAlertDelivery.probe = _Probe(owed: () async {
      if (!first) return;
      first = false;
      paused.complete();
      await resume.future;
    });
    final foreground = PulseAlertDelivery.run(); // owes D, summary path
    await paused.future;
    await PulseAlertDelivery.run(individualDays: {d}); // background wins D
    expect(shown.map((e) => e.dedupeKey), ['$d:irregular-pulse']);
    resume.complete();
    await foreground;
    expect(shown, hasLength(1), reason: 'no summary naming D as well');
    expect((await record(d))!.state, PulseAlertState.sent);
  });

  // The mirror: the summary pass wins the day, so the individual pass shows nothing.
  test('an individual pass that loses the claim to a summary shows nothing',
      () async {
    final d = daysAgo(1);
    await flag(d);
    final paused = Completer<void>();
    final resume = Completer<void>();
    var first = true;
    PulseAlertDelivery.probe = _Probe(owed: () async {
      if (!first) return;
      first = false;
      paused.complete();
      await resume.future;
    });
    final background = PulseAlertDelivery.run(individualDays: {d});
    await paused.future;
    await PulseAlertDelivery.run(); // a summary takes D
    expect(shown.single.dedupeKey, startsWith('pulse-summary:'));
    resume.complete();
    await background;
    expect(shown, hasLength(1), reason: 'D is not also announced by itself');
    expect((await record(d))!.state, PulseAlertState.summary);
  });

  // why: a day cannot be named by an individual alert and a summary in one pass.
  test('days announced by themselves are not repeated in that pass summary',
      () async {
    final a = daysAgo(1), b = daysAgo(8);
    await flag(a);
    await flag(b);
    await PulseAlertDelivery.run(individualDays: {a});
    expect(shown, hasLength(2));
    final summary = shown.firstWhere((e) => e.dedupeKey.startsWith('pulse-summary:'));
    expect(summary.body, contains(niceDay(b)));
    expect(summary.body, isNot(contains(niceDay(a))));
    expect((await record(a))!.state, PulseAlertState.sent);
    expect((await record(b))!.state, PulseAlertState.summary);
  });

  // why: R2-C1. Quiet hours are not "notifications off", and the wearer's note
  // must say which one held the alert back.
  test('quiet hours are recorded as their own reason', () async {
    final d = daysAgo(1);
    await flag(d);
    final at = DateTime.now();
    final minute = at.hour * 60 + at.minute;
    await (await NotificationPrefs.load())
        .copyWith(
          quietEnabled: true,
          quietStartMin: (minute + 1380) % 1440,
          quietEndMin: (minute + 60) % 1440,
          criticalOverridesQuiet: true,
        )
        .save();
    await PulseAlertDelivery.run(individualDays: {d});
    expect(shown, isEmpty);
    final r = (await record(d))!;
    expect((r.state, r.reason), (PulseAlertState.notSent, PulseAlertReason.quiet));
  });

  // why: R2-C2. A band-only health rule that buzzed the band delivered the
  // alert; recording it as off would resend it as a summary later.
  test('an alert that reached only the band is recorded as sent', () async {
    final d = daysAgo(1);
    await flag(d);
    PulseAlertDelivery.probe = _Probe(targets: (e) async => {'band'});
    await PulseAlertDelivery.run(individualDays: {d});
    expect((await record(d))!.state, PulseAlertState.sent);
    final e2 = daysAgo(2);
    await flag(e2);
    PulseAlertDelivery.probe = _Probe(targets: (e) async => <String>{});
    await PulseAlertDelivery.run(individualDays: {e2});
    expect((await record(e2))!.state, PulseAlertState.notSent);
  });

  // why: R2-W1 in the delivery path. Today in the list must not read "earlier",
  // and one day must not read "these days".
  test('a summary that includes today says so plainly', () async {
    await flag(today);
    await flag(daysAgo(4));
    await PulseAlertDelivery.run();
    expect(shown, hasLength(1));
    expect(shown.single.title, 'Irregular pulse flags found on 2 days');
    expect(shown.single.title.toLowerCase(), isNot(contains('earlier')));
    expect(shown.single.body, contains(niceDay(today)));
    expect(shown.single.body, contains('these days'));
    shown.clear();
    final one = daysAgo(9);
    await flag(one);
    await PulseAlertDelivery.run();
    expect(shown.single.title, 'Irregular pulse flag found on 1 day');
    expect(shown.single.body, contains('this day'));
    expect(shown.single.body, isNot(contains('these days')));
  });

  // why: R2-W2. Dates that contain commas are not joined with commas.
  test('the summary date list is separated by semicolons, zh by 、', () async {
    await flag(daysAgo(5));
    await flag(daysAgo(3));
    await PulseAlertDelivery.run();
    expect(
      shown.single.body,
      contains('${niceDay(daysAgo(5))}; ${niceDay(daysAgo(3))}'),
    );
  });

  test('joinDates uses the locale enumeration mark', () {
    expect(PulseAlertDelivery.joinDates(['a', 'b'], 'en'), 'a; b');
    expect(PulseAlertDelivery.joinDates(['2026年11月12日周四', '2026年11月14日周六'], 'zh'),
        '2026年11月12日周四、2026年11月14日周六');
  });
}
