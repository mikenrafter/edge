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

void main() {
  group('rangesWithoutDays (deleteDays)', () {
    test('a day in the middle splits the period; intake and ongoing survive', () {
      final out = rangesWithoutDays([_done('2026-10-20', null)], {'2026-10-24'});
      expect(_shape(out), [
        ('r@d:2026-10-20..2026-10-23', '2026-10-20', '2026-10-23'),
        ('r@d:2026-10-25..9999-12-31', '2026-10-25', null),
      ]);
      expect((out[1] as DoneRange).intake.amount!.value, 50);
      expect((out[1] as DoneRange).intake.approxMinute, 480);
    });

    test('deleting the first or last day trims; month and year boundaries work', () {
      expect(
        _shape(rangesWithoutDays([_done('2026-12-30', '2027-01-02')], {'2026-12-30', '2027-01-02'})),
        [('r@d:2026-12-31..2027-01-01', '2026-12-31', '2027-01-01')],
      );
    });

    test('every day deleted removes the period', () {
      expect(
        rangesWithoutDays([_done('2026-10-20', '2026-10-21')], {'2026-10-20', '2026-10-21'}),
        isEmpty,
      );
    });

    test('days outside the period change nothing, ids included', () {
      final input = [_done('2026-10-20', '2026-10-25')];
      expect(_shape(rangesWithoutDays(input, {'2026-10-19', '2026-10-26'})), [
        ('r', '2026-10-20', '2026-10-25'),
      ]);
    });

    test('a not-done period is cut the same way', () {
      final out = rangesWithoutDays([
        const NotDoneRange(id: 'n', trackId: 't', startDate: '2026-09-01', endDate: '2026-09-10'),
      ], {'2026-09-05'});
      expect(_shape(out), [
        ('n@n:2026-09-01..2026-09-04', '2026-09-01', '2026-09-04'),
        ('n@n:2026-09-06..2026-09-10', '2026-09-06', '2026-09-10'),
      ]);
      expect(out.every((r) => r is NotDoneRange), isTrue);
    });

    test('deleting the end of an ongoing period leaves it ongoing from the next day', () {
      final out = rangesWithoutDays([_done('2026-10-20', null)], {'2026-10-20', '2026-10-21'});
      expect(_shape(out), [('r@d:2026-10-22..9999-12-31', '2026-10-22', null)]);
    });
  });

  group('rangesOnDays (selected-day export)', () {
    test('keeps only the selected days, as runs of consecutive days', () {
      final out = rangesOnDays(
        [_done('2026-10-20', null)],
        {'2026-10-22', '2026-10-23', '2026-10-26'},
      );
      expect(_shape(out), [
        ('r@d:2026-10-22..2026-10-23', '2026-10-22', '2026-10-23'),
        ('r@d:2026-10-26..2026-10-26', '2026-10-26', '2026-10-26'),
      ]);
      expect(out.every((r) => r is DoneRange && !r.ongoing), isTrue,
          reason: 'an export cannot vouch for days it did not select');
      expect((out.first as DoneRange).intake.amount!.unit, 'mg');
    });

    test('a period fully inside the selection keeps its id', () {
      expect(
        _shape(rangesOnDays([_done('2026-10-20', '2026-10-21')], {'2026-10-19', '2026-10-20', '2026-10-21'})),
        [('r', '2026-10-20', '2026-10-21')],
      );
    });

    test('a period with no selected day is dropped', () {
      expect(rangesOnDays([_done('2026-10-20', '2026-10-21')], {'2026-11-01'}), isEmpty);
    });

    test('not-done periods are clipped too', () {
      final out = rangesOnDays([
        const NotDoneRange(id: 'n', trackId: 't', startDate: '2026-09-01', endDate: '2026-09-10'),
      ], {'2026-09-03'});
      expect(_shape(out), [('n@n:2026-09-03..2026-09-03', '2026-09-03', '2026-09-03')]);
    });
  });

  // why (review R2-1): the piece id carries the original id, the kind and BOTH
  // ends, so no two pieces with different coverage share an id, and a piece
  // never takes the id of the full period it was cut from. Restores that
  // INSERT OR REPLACE by id therefore replace only an identical piece.
  group('piece ids cannot collide (R2-1)', () {
    test('a clipped first day of an ongoing period does not keep the original id', () {
      final out = rangesOnDays([_done('2026-10-20', null)], {'2026-10-20'});
      expect(out.single.id, isNot('r'));
      expect(out.single.id, 'r@d:2026-10-20..2026-10-20');
    });

    test('pieces that share a start but differ in end get different ids', () {
      final one = rangesOnDays([_done('2026-10-20', null)], {'2026-10-22'});
      final two = rangesOnDays([_done('2026-10-20', null)], {'2026-10-22', '2026-10-23'});
      expect(one.single.startDate, two.single.startDate);
      expect(one.single.id, isNot(two.single.id));
    });

    test('a done piece and a not-done piece over the same days differ', () {
      final done = rangesOnDays([_done('2026-10-20', '2026-10-30', id: 'r')], {'2026-10-27'});
      final not = rangesOnDays([
        const NotDoneRange(id: 'r', trackId: 't', startDate: '2026-10-20', endDate: '2026-10-30'),
      ], {'2026-10-27'});
      expect(done.single.id, isNot(not.single.id));
    });

    test('an uncut period keeps its id', () {
      expect(
        rangesWithoutDays([_done('2026-10-20', '2026-10-25')], {'2026-11-01'}).single.id,
        'r',
      );
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
  // new rows, and conflicting local rows do not count as coverage (both are
  // kept; learning abstains on those dates, CLAIM(range-overlap)).
  // proves: CLAIM(range-restore-coverage)
  group('rangesToAdd (restore by coverage)', () {
    List<(String, String, String?)> add(List<TrackSetupRange> local, List<TrackSetupRange> incoming) =>
        _shape(rangesToAdd(local: local, incoming: incoming));

    test('into an empty database every period arrives, ids kept when free', () {
      expect(add([], [_done('2026-10-20', '2026-10-22', id: 'x')]), [('x', '2026-10-20', '2026-10-22')]);
    });

    test('dates an agreeing local period covers are no-ops', () {
      expect(add([_done('2026-10-20', null, id: 'full')], [_done('2026-10-22', '2026-10-25', id: 'p')]), isEmpty);
      expect(add([_done('2026-10-20', '2026-10-25', id: 'full')], [_done('2026-10-20', '2026-10-25', id: 'full')]), isEmpty);
    });

    test('only the uncovered dates are added, as new rows', () {
      final out = rangesToAdd(
        local: [_done('2026-10-20', '2026-10-22', id: 'a')],
        incoming: [_done('2026-10-22', '2026-10-25', id: 'b')],
      );
      expect(_shape(out), [('b', '2026-10-23', '2026-10-25')]);
      expect((out.single as DoneRange).intake.amount!.value, 50);
    });

    test('a gap in the middle and an ongoing tail are both found', () {
      final out = add(
        [_done('2026-10-22', '2026-10-23', id: 'a')],
        [_done('2026-10-20', null, id: 'b')],
      );
      expect(out.map((r) => (r.$2, r.$3)), [('2026-10-20', '2026-10-21'), ('2026-10-24', null)]);
    });

    test('an id that is already local is never reused', () {
      final out = rangesToAdd(
        local: [_done('2026-10-20', '2026-10-21', id: 'same')],
        incoming: [_done('2026-11-01', '2026-11-02', id: 'same')],
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
      expect(add([other], [_done('2026-10-22', '2026-10-23', id: 'b')]), [('b', '2026-10-22', '2026-10-23')]);
      final notDone = const NotDoneRange(id: 'n', trackId: 't', startDate: '2026-10-20', endDate: '2026-10-30');
      expect(add([notDone], [_done('2026-10-22', '2026-10-23', id: 'b')]), [('b', '2026-10-22', '2026-10-23')]);
    });

    test('periods of another track are not coverage', () {
      final other = DoneRange(id: 'o', trackId: 'other', startDate: '2026-10-01', intake: const DailyIntake(approxMinute: 480, amount: DailyAmount(50, 'mg')));
      expect(add([other], [_done('2026-10-22', '2026-10-23', id: 'b')]), [('b', '2026-10-22', '2026-10-23')]);
    });

    test('overlapping agreeing incoming periods do not duplicate each other', () {
      final out = add([], [_done('2026-10-20', '2026-10-22', id: 'a'), _done('2026-10-21', '2026-10-24', id: 'b')]);
      expect(out, [('a', '2026-10-20', '2026-10-22'), ('b', '2026-10-23', '2026-10-24')]);
    });

    test('running it twice adds nothing the second time', () {
      final incoming = [_done('2026-10-20', '2026-10-22', id: 'a'), _done('2026-10-24', null, id: 'b')];
      final first = rangesToAdd(local: [], incoming: incoming);
      expect(rangesToAdd(local: first, incoming: incoming), isEmpty);
    });
  });
}
