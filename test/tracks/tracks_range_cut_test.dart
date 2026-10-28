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
        ('r', '2026-10-20', '2026-10-23'),
        ('r@2026-10-25', '2026-10-25', null),
      ]);
      expect((out[1] as DoneRange).intake.amount!.value, 50);
      expect((out[1] as DoneRange).intake.approxMinute, 480);
    });

    test('deleting the first or last day trims; month and year boundaries work', () {
      expect(
        _shape(rangesWithoutDays([_done('2026-12-30', '2027-01-02')], {'2026-12-30', '2027-01-02'})),
        [('r@2026-12-31', '2026-12-31', '2027-01-01')],
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
        ('n', '2026-09-01', '2026-09-04'),
        ('n@2026-09-06', '2026-09-06', '2026-09-10'),
      ]);
      expect(out.every((r) => r is NotDoneRange), isTrue);
    });

    test('deleting the end of an ongoing period leaves it ongoing from the next day', () {
      final out = rangesWithoutDays([_done('2026-10-20', null)], {'2026-10-20', '2026-10-21'});
      expect(_shape(out), [('r@2026-10-22', '2026-10-22', null)]);
    });
  });

  group('rangesOnDays (selected-day export)', () {
    test('keeps only the selected days, as runs of consecutive days', () {
      final out = rangesOnDays(
        [_done('2026-10-20', null)],
        {'2026-10-22', '2026-10-23', '2026-10-26'},
      );
      expect(_shape(out), [
        ('r@2026-10-22', '2026-10-22', '2026-10-23'),
        ('r@2026-10-26', '2026-10-26', '2026-10-26'),
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
      expect(_shape(out), [('n@2026-09-03', '2026-09-03', '2026-09-03')]);
    });
  });
}
