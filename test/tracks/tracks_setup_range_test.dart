// P8a item 1: the setup-range model. A "done" range may carry a daily intake
// (approximate local minute, amount + the unit it was entered in) and may have
// no end; a "not done" range can carry neither. Pure values first, then the
// store that validates them before they reach SQLite.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import '../backup/backup_support.dart';

DoneRange _daily({
  String? until,
  int? minute = 480,
  DailyAmount? amount = const DailyAmount(50, 'mg'),
}) => DoneRange(
  id: 'r1',
  trackId: 'med:x',
  startDate: '2026-03-01',
  untilDate: until,
  intake: DailyIntake(approxMinute: minute, amount: amount),
);

String _kind(TrackSetupRange range) => switch (range) {
  // why: the switch has no default. Adding a third variant stops compiling
  // here, so every consumer is revisited (technical-excellence 5).
  DoneRange() => 'done',
  NotDoneRange() => 'not_done',
};

TrackDefinition _custom() => TrackDefinition(
  id: 'reading',
  name: 'Reading',
  icon: 'book',
  kind: 'activity',
  unit: 'mg',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('model', () {
    // why: the stored shape is the contract with schema v85 and with exports.
    // The literal map is hand-written from the spec columns, not built from the
    // class's own constants. proves: CLAIM(range-columns)
    test('a daily range with time and amount serialises to the stored row', () {
      expect(_daily(until: '2026-03-31').toJson(), {
        'id': 'r1',
        'track_id': 'med:x',
        'start_date': '2026-03-01',
        'end_date': '2026-03-31',
        'done': 1,
        'approx_minute': 480,
        'amount': 50.0,
        'amount_unit': 'mg',
      });
    });

    test('a done range with no details stores explicit nulls', () {
      expect(_daily(until: '2026-03-31', minute: null, amount: null).toJson(), {
        'id': 'r1',
        'track_id': 'med:x',
        'start_date': '2026-03-01',
        'end_date': '2026-03-31',
        'done': 1,
        'approx_minute': null,
        'amount': null,
        'amount_unit': null,
      });
    });

    // why: "since X" is stored with an end_date that keeps CHECK(start<=end)
    // true without a schema change. proves: CLAIM(ongoing-sentinel)
    test('an ongoing range stores the far-future end and reads back ongoing', () {
      final row = _daily().toJson();
      expect(row['end_date'], '9999-12-31');
      expect(
        (row['start_date'] as String).compareTo(row['end_date'] as String),
        lessThanOrEqualTo(0),
        reason: 'the table CHECK (start_date <= end_date) must stay satisfied',
      );
      final back = TrackSetupRange.fromJson(row);
      expect(back, isA<DoneRange>());
      expect((back as DoneRange).ongoing, isTrue);
      expect(back.untilDate, isNull);
      expect(back.intake.approxMinute, 480);
      expect(back.intake.amount!.value, 50.0);
      expect(back.intake.amount!.unit, 'mg');
    });

    test('a bounded range is not ongoing', () {
      final back =
          TrackSetupRange.fromJson(_daily(until: '2026-03-31').toJson())
              as DoneRange;
      expect(back.ongoing, isFalse);
      expect(back.untilDate, '2026-03-31');
      expect(back.endDate, '2026-03-31');
    });

    // why: a not-done range cannot carry a time or amount. A row that says
    // otherwise (foreign import, hand edit) is read as the not-done range it
    // is, and writes back clean. proves: CLAIM(range-invariants)
    test('a not-done row with intake columns reads as plain not-done', () {
      final back = TrackSetupRange.fromJson({
        'id': 'n',
        'track_id': 'med:x',
        'start_date': '2026-03-01',
        'end_date': '2026-03-05',
        'done': 0,
        'approx_minute': 480,
        'amount': 50.0,
        'amount_unit': 'mg',
      });
      expect(back, isA<NotDoneRange>());
      expect(back.toJson()['approx_minute'], isNull);
      expect(back.toJson()['amount'], isNull);
      expect(back.toJson()['amount_unit'], isNull);
      expect(_kind(back), 'not_done');
    });

    test('the five-field constructor picks the right variant', () {
      expect(
        TrackSetupRange(
          id: 'a',
          trackId: 't',
          startDate: '2026-03-01',
          endDate: '2026-03-02',
          done: true,
        ),
        isA<DoneRange>(),
      );
      expect(
        TrackSetupRange(
          id: 'a',
          trackId: 't',
          startDate: '2026-03-01',
          endDate: '2026-03-02',
          done: false,
        ),
        isA<NotDoneRange>(),
      );
      final ongoing =
          TrackSetupRange(
                id: 'a',
                trackId: 't',
                startDate: '2026-03-01',
                endDate: kOngoingEndDate,
                done: true,
              )
              as DoneRange;
      expect(ongoing.ongoing, isTrue);
    });

    // why: parse, do not validate. A minute or amount that cannot be right
    // reads as unknown (null), never as a clamped or zero value that learning
    // would trust. Each row differs from a good one in exactly one field.
    for (final (name, patch, minute, amount) in <(
      String,
      Map<String, Object?>,
      int?,
      double?
    )>[
      ('minute 1440', {'approx_minute': 1440}, null, 50.0),
      ('minute -1', {'approx_minute': -1}, null, 50.0),
      ('minute 1439 is the last valid one', {'approx_minute': 1439}, 1439, 50.0),
      ('minute 0 is valid', {'approx_minute': 0}, 0, 50.0),
      ('amount 0', {'amount': 0.0}, 480, null),
      ('amount negative', {'amount': -3.0}, 480, null),
      ('amount NaN', {'amount': double.nan}, 480, null),
      ('amount infinite', {'amount': double.infinity}, 480, null),
      ('amount without its unit', {'amount_unit': null}, 480, null),
    ]) {
      test('a stored row with $name', () {
        final row = {..._daily(until: '2026-03-31').toJson(), ...patch};
        final back = TrackSetupRange.fromJson(row) as DoneRange;
        expect(back.intake.approxMinute, minute);
        expect(back.intake.amount?.value, amount);
      });
    }

    test('a unitless track keeps an amount with the empty unit', () {
      final row = {..._daily(until: '2026-03-31').toJson(), 'amount_unit': ''};
      final back = TrackSetupRange.fromJson(row) as DoneRange;
      expect(back.intake.amount!.value, 50.0);
      expect(back.intake.amount!.unit, '');
    });

    test('validationError names the first invalid intake field', () {
      expect(_daily().validationError, isNull);
      expect(_daily(minute: 1440).validationError, 'approx_minute');
      expect(_daily(minute: -1).validationError, 'approx_minute');
      expect(
        _daily(amount: const DailyAmount(0, 'mg')).validationError,
        'amount',
      );
      expect(
        _daily(amount: const DailyAmount(double.nan, 'mg')).validationError,
        'amount',
      );
    });
  });

  group('store', () {
    late BackupEnv env;
    late TracksStore store;
    setUp(() async {
      env = await BackupEnv.create('tracks_setup_range_p8a.db');
      store = TracksStore(await LocalDb.instance);
      await store.saveDefinition(_custom());
    });
    tearDown(() async => env.dispose());

    DoneRange doneRange(
      String id,
      String from,
      String? until, {
      int? minute,
      DailyAmount? amount,
    }) => DoneRange(
      id: id,
      trackId: 'reading',
      startDate: from,
      untilDate: until,
      intake: DailyIntake(approxMinute: minute, amount: amount),
    );

    // why: the editor saves through saveHistory; intake must survive the SQL
    // round trip, including the unit it was entered in. proves: CLAIM(range-columns)
    test('intake and ongoing survive a save and read', () async {
      await store.saveHistory('reading', [
        doneRange(
          'a',
          '2026-03-01',
          '2026-03-10',
          minute: 490,
          amount: const DailyAmount(2.5, 'mg'),
        ),
        NotDoneRange(
          id: 'b',
          trackId: 'reading',
          startDate: '2026-03-11',
          endDate: '2026-03-20',
        ),
        doneRange('c', '2026-03-21', null, minute: 0),
      ]);
      final back = await store.history('reading');
      expect(back.map(_kind), ['done', 'not_done', 'done']);
      final a = back[0] as DoneRange;
      expect(a.intake.approxMinute, 490);
      expect(a.intake.amount!.value, 2.5);
      expect(a.intake.amount!.unit, 'mg');
      expect((back[2] as DoneRange).ongoing, isTrue);
      expect((back[2] as DoneRange).intake.approxMinute, 0);
      expect((back[2] as DoneRange).intake.amount, isNull);
    });

    // why: an ongoing range extends past every later date, so anything that
    // starts after it overlaps it. proves: CLAIM(ongoing-sentinel)
    test('nothing may start after an ongoing range, and only one may exist', () async {
      await expectLater(
        store.saveHistory('reading', [
          doneRange('a', '2026-03-01', null),
          doneRange('b', '2026-06-01', '2026-06-05'),
        ]),
        throwsArgumentError,
      );
      await expectLater(
        store.saveHistory('reading', [
          doneRange('a', '2026-03-01', null),
          doneRange('b', '2026-04-01', null),
        ]),
        throwsArgumentError,
      );
      // Positive control: the same ranges are fine when the ongoing one is last.
      await store.saveHistory('reading', [
        doneRange('b', '2026-02-01', '2026-02-20'),
        doneRange('a', '2026-03-01', null),
      ]);
      expect(await store.history('reading'), hasLength(2));
    });

    test('an invalid minute or amount is rejected before SQLite', () async {
      await expectLater(
        store.saveHistory('reading', [
          doneRange('a', '2026-03-01', null, minute: 1440),
        ]),
        throwsArgumentError,
      );
      await expectLater(
        store.saveHistory('reading', [
          doneRange(
            'a',
            '2026-03-01',
            null,
            amount: const DailyAmount(-1, 'mg'),
          ),
        ]),
        throwsArgumentError,
      );
      expect(await store.history('reading'), isEmpty);
    });

    test('the stored placeholder end satisfies the table CHECK', () async {
      await store.saveHistory('reading', [doneRange('a', '2026-03-01', null)]);
      final row = (await (await LocalDb.instance).query(
        'track_setup_history',
      )).single;
      expect(row['end_date'], '9999-12-31');
      expect(row['done'], 1);
    });
  });
}
