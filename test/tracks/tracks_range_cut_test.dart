// Review P8a-P2 / P8a-P3: cutting setup periods by day. Export keeps only the
// selected days of a period; deleteDays removes the deleted days from it (those
// dates become "no statement", i.e. unknown to learning), keeping the rest.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/track_model.dart';
import 'package:openstrap_edge/data/track_range_cut.dart';

DoneRange _done(String from, String? until, {String id = 'r'}) => DoneRange(
  id: id,
  trackId: 't',
  startDate: from,
  untilDate: until,
  intake: const DailyIntake(approxMinute: 480, amount: DailyAmount(50, 'mg')),
);

// (id, start, end-or-null-for-ongoing)
List<(String, String, String?)> _shape(List<TrackSetupRange> ranges) => [
  for (final r in ranges)
    (r.id, r.startDate, r is DoneRange && r.ongoing ? null : r.endDate),
];

// Coverage only: ids of new pieces are random and carry no meaning.
List<(String, String?)> _cover(List<TrackSetupRange> ranges) => [
  for (final r in ranges) (r.startDate, r is DoneRange && r.ongoing ? null : r.endDate),
];

/// Deterministic stand-in for the UUID generator: g1, g2, ...
final class _Counter implements RangeIdSource {
  int _n = 0;
  @override
  String next() => 'g${++_n}';
}

RangeIdSource _ids() => _Counter();

void main() {
  // why (review R4-1, R4-2): no id is ever DERIVED from another (`<id>@...`,
  // `<id>~...`). A derived id can equal an id the wearer's edit or an earlier
  // restore already created, and then an INSERT replaces or ignores it. Every
  // new piece gets a fresh id from the generator; an uncut period keeps its own.
  // proves: CLAIM(range-fresh-id)
  group('rangesWithoutDays (deleteDays)', () {
    test('a day in the middle splits the period; intake and ongoing survive', () {
      final out = rangesWithoutDays([_done('2026-10-20', null)], {'2026-10-24'}, newId: _ids());
      expect(_shape(out), [
        ('g1', '2026-10-20', '2026-10-23'),
        ('g2', '2026-10-25', null),
      ]);
      expect((out[1] as DoneRange).intake.amount!.value, 50);
      expect((out[1] as DoneRange).intake.approxMinute, 480);
    });

    test('deleting the first or last day trims; month and year boundaries work', () {
      expect(
        _cover(rangesWithoutDays([_done('2026-12-30', '2027-01-02')], {'2026-12-30', '2027-01-02'}, newId: _ids())),
        [('2026-12-31', '2027-01-01')],
      );
    });

    test('every day deleted removes the period', () {
      expect(
        rangesWithoutDays([_done('2026-10-20', '2026-10-21')], {'2026-10-20', '2026-10-21'}, newId: _ids()),
        isEmpty,
      );
    });

    test('days outside the period change nothing, id included', () {
      final input = [_done('2026-10-20', '2026-10-25')];
      final out = rangesWithoutDays(input, {'2026-10-19', '2026-10-26'}, newId: _ids());
      expect(_shape(out), [('r', '2026-10-20', '2026-10-25')]);
      expect(identical(out.single, input.single), isTrue);
    });

    test('a not-done period is cut the same way', () {
      final out = rangesWithoutDays([
        const NotDoneRange(id: 'n', trackId: 't', startDate: '2026-09-01', endDate: '2026-09-10'),
      ], {'2026-09-05'}, newId: _ids());
      expect(_cover(out), [('2026-09-01', '2026-09-04'), ('2026-09-06', '2026-09-10')]);
      expect(out.every((r) => r is NotDoneRange), isTrue);
    });

    test('deleting the end of an ongoing period leaves it ongoing from the next day', () {
      final out = rangesWithoutDays([_done('2026-10-20', null)], {'2026-10-20', '2026-10-21'}, newId: _ids());
      expect(_cover(out), [('2026-10-22', null)]);
    });

    test('cut pieces never reuse the original id or each other', () {
      final out = rangesWithoutDays([_done('2026-10-20', null)], {'2026-10-22', '2026-10-25'}, newId: _ids());
      final ids = out.map((r) => r.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids, isNot(contains('r')));
    });
  });

  group('rangesOnDays (selected-day export)', () {
    test('keeps only the selected days, as runs of consecutive days', () {
      final out = rangesOnDays(
        [_done('2026-10-20', null)],
        {'2026-10-22', '2026-10-23', '2026-10-26'},
        newId: _ids(),
      );
      expect(_cover(out), [('2026-10-22', '2026-10-23'), ('2026-10-26', '2026-10-26')]);
      expect(out.every((r) => r is DoneRange && !r.ongoing), isTrue,
          reason: 'an export cannot vouch for days it did not select');
      expect((out.first as DoneRange).intake.amount!.unit, 'mg');
    });

    test('a period with no selected day is dropped', () {
      expect(rangesOnDays([_done('2026-10-20', '2026-10-21')], {'2026-11-01'}, newId: _ids()), isEmpty);
    });

    test('not-done periods are clipped too', () {
      final out = rangesOnDays([
        const NotDoneRange(id: 'n', trackId: 't', startDate: '2026-09-01', endDate: '2026-09-10'),
      ], {'2026-09-03'}, newId: _ids());
      expect(_cover(out), [('2026-09-03', '2026-09-03')]);
      expect(out.single, isA<NotDoneRange>());
    });

    test('every exported piece has a fresh id, even a full-inside one', () {
      final out = rangesOnDays(
        [_done('2026-10-20', '2026-10-21'), _done('2026-10-27', '2026-10-28', id: 'q')],
        {'2026-10-20', '2026-10-21', '2026-10-27', '2026-10-28'},
        newId: _ids(),
      );
      expect(out.map((r) => r.id), ['g1', 'g2']);
    });
  });

  // why (review R2-3): periods that overlap AND agree (same kind, same intake)
  // are one period; conflicting ones are kept apart, never merged.
  group('mergeAgreeingOverlaps (R2-3)', () {
    test('an agreeing middle-day piece folds into its period', () {
      final out = mergeAgreeingOverlaps([
        _done('2026-10-20', null, id: 'full'),
        _done('2026-10-24', '2026-10-24', id: 'piece'),
      ]);
      expect(_shape(out), [('full', '2026-10-20', null)]);
    });

    test('overlapping ends extend the survivor; the earlier id survives', () {
      final out = mergeAgreeingOverlaps([
        _done('2026-10-22', '2026-10-30', id: 'b'),
        _done('2026-10-20', '2026-10-25', id: 'a'),
      ]);
      expect(_shape(out), [('a', '2026-10-20', '2026-10-30')]);
    });

    test('different intake is a conflict and both are kept', () {
      final other = DoneRange(
        id: 'b',
        trackId: 't',
        startDate: '2026-10-24',
        untilDate: '2026-10-24',
        intake: const DailyIntake(approxMinute: 600, amount: DailyAmount(50, 'mg')),
      );
      final out = mergeAgreeingOverlaps([_done('2026-10-20', null, id: 'a'), other]);
      expect(_shape(out), [('a', '2026-10-20', null), ('b', '2026-10-24', '2026-10-24')]);
    });

    test('done and not-done overlap is a conflict and both are kept', () {
      final out = mergeAgreeingOverlaps([
        _done('2026-10-20', '2026-10-30', id: 'a'),
        const NotDoneRange(id: 'n', trackId: 't', startDate: '2026-10-25', endDate: '2026-10-26'),
      ]);
      expect(out, hasLength(2));
    });

    test('adjacent (not overlapping) periods are left alone', () {
      final out = mergeAgreeingOverlaps([
        _done('2026-10-20', '2026-10-21', id: 'a'),
        _done('2026-10-22', '2026-10-23', id: 'b'),
      ]);
      expect(out, hasLength(2));
    });
  });

  // why (review R3-1): restore must never REPLACE a setup row by id. Incoming
  // periods are compared by COVERAGE with the local rows of the same track:
  // dates an agreeing local period already covers are no-ops, the rest become
  // new rows with fresh ids, and conflicting local rows do not count as
  // coverage (both are kept; learning abstains, CLAIM(range-overlap)).
  // proves: CLAIM(range-restore-coverage)
  group('rangesToAdd (restore by coverage)', () {
    List<(String, String, String?)> add(List<TrackSetupRange> local, List<TrackSetupRange> incoming) =>
        _shape(rangesToAdd(local: local, incoming: incoming, newId: _ids()));

    test('into an empty database every period arrives, under fresh ids', () {
      expect(add([], [_done('2026-10-20', '2026-10-22', id: 'x')]), [('g1', '2026-10-20', '2026-10-22')]);
    });

    test('dates an agreeing local period covers are no-ops', () {
      expect(add([_done('2026-10-20', null, id: 'full')], [_done('2026-10-22', '2026-10-25', id: 'p')]), isEmpty);
      expect(add([_done('2026-10-20', '2026-10-25', id: 'full')], [_done('2026-10-20', '2026-10-25', id: 'full')]), isEmpty);
    });

    test('only the uncovered dates are added', () {
      final out = rangesToAdd(
        local: [_done('2026-10-20', '2026-10-22', id: 'a')],
        incoming: [_done('2026-10-22', '2026-10-25', id: 'b')],
        newId: _ids(),
      );
      expect(_shape(out), [('g1', '2026-10-23', '2026-10-25')]);
      expect((out.single as DoneRange).intake.amount!.value, 50);
    });

    test('a gap in the middle and an ongoing tail are both found', () {
      final out = add(
        [_done('2026-10-22', '2026-10-23', id: 'a')],
        [_done('2026-10-20', null, id: 'b')],
      );
      expect(out.map((r) => (r.$2, r.$3)), [('2026-10-20', '2026-10-21'), ('2026-10-24', null)]);
    });

    test('an incoming id that is already local is never reused (nor any other)', () {
      final out = rangesToAdd(
        local: [_done('2026-10-20', '2026-10-21', id: 'same')],
        incoming: [_done('2026-11-01', '2026-11-02', id: 'same')],
        newId: _ids(),
      );
      expect(out.single.id, isNot('same'));
      expect(out.single.startDate, '2026-11-01');
    });

    test('a conflicting local period is not coverage: both are kept', () {
      final other = DoneRange(
        id: 'l',
        trackId: 't',
        startDate: '2026-10-20',
        untilDate: '2026-10-30',
        intake: const DailyIntake(approxMinute: 600),
      );
      expect(_cover(rangesToAdd(local: [other], incoming: [_done('2026-10-22', '2026-10-23', id: 'b')], newId: _ids())), [('2026-10-22', '2026-10-23')]);
      final notDone = const NotDoneRange(id: 'n', trackId: 't', startDate: '2026-10-20', endDate: '2026-10-30');
      expect(_cover(rangesToAdd(local: [notDone], incoming: [_done('2026-10-22', '2026-10-23', id: 'b')], newId: _ids())), [('2026-10-22', '2026-10-23')]);
    });

    test('periods of another track are not coverage', () {
      final other = DoneRange(id: 'o', trackId: 'other', startDate: '2026-10-01', intake: const DailyIntake(approxMinute: 480, amount: DailyAmount(50, 'mg')));
      expect(_cover(rangesToAdd(local: [other], incoming: [_done('2026-10-22', '2026-10-23', id: 'b')], newId: _ids())), [('2026-10-22', '2026-10-23')]);
    });

    test('overlapping agreeing incoming periods do not duplicate each other', () {
      expect(
        _cover(rangesToAdd(local: [], incoming: [_done('2026-10-20', '2026-10-22', id: 'a'), _done('2026-10-21', '2026-10-24', id: 'b')], newId: _ids())),
        [('2026-10-20', '2026-10-22'), ('2026-10-23', '2026-10-24')],
      );
    });

    test('running it twice adds nothing the second time', () {
      final incoming = [_done('2026-10-20', '2026-10-22', id: 'a'), _done('2026-10-24', null, id: 'b')];
      final first = rangesToAdd(local: [], incoming: incoming, newId: _ids());
      expect(rangesToAdd(local: first, incoming: incoming, newId: _ids()), isEmpty);
    });
  });
}
