// Review P8a-R4: no sequence of export, restore, edit, delete and re-import may
// lose what the wearer explicitly said, or turn a not-done / deleted date back
// into a nominal dose. Random but seeded, over the pure helpers the real paths
// call (rangesOnDays for export, rangesToAdd for restore, rangesWithoutDays for
// deleteDays); the two DB-level sequences from the review are in
// tracks_history_schema_test. proves: CLAIM(range-restore-coverage),
// CLAIM(range-fresh-id), CLAIM(range-cut)
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/track_model.dart';
import 'package:openstrap_edge/data/track_range_cut.dart';
import 'package:openstrap_edge/tracks/range_exposure.dart';

const _days = 12; // 2026-10-20 .. 2026-10-31
String _date(int i) => '2026-10-${(20 + i).toString().padLeft(2, '0')}';

// A statement a row makes about each of its dates.
String _statement(TrackSetupRange r) => switch (r) {
  DoneRange() => 'D${r.intake.approxMinute}/${r.intake.amount?.value}',
  NotDoneRange() => 'N',
};

bool _covers(TrackSetupRange r, String d) =>
    r.startDate.compareTo(d) <= 0 && r.endDate.compareTo(d) >= 0;

TrackSetupRange _make(String id, int from, int? to, String kind) {
  final end = to == null ? null : _date(to);
  return kind == 'N'
      ? NotDoneRange(id: id, trackId: 't', startDate: _date(from), endDate: end ?? _date(_days - 1))
      : DoneRange(
          id: id,
          trackId: 't',
          startDate: _date(from),
          untilDate: end,
          intake: DailyIntake(
            approxMinute: kind == 'Dm' ? 480 : null,
            amount: kind == 'Dm' ? const DailyAmount(50, 'mg') : null,
          ),
        );
}

final class _Counter implements RangeIdSource {
  int _n = 0;
  @override
  String next() => 'g${++_n}';
}

void main() {
  test('random export / restore / edit / delete / re-import sequences keep the wearer\'s statements', () {
    for (var seed = 0; seed < 400; seed++) {
      final random = Random(seed);
      final newId = _Counter();
      // Two "devices" share files; this is the local one.
      var local = <TrackSetupRange>[
        _make('o', 0, null, ['Dm', 'D', 'N'][random.nextInt(3)]),
      ];
      final files = <List<TrackSetupRange>>[
        [for (final r in local) r],
      ];
      final truth = <String, String>{}; // date -> latest explicit statement
      final deleted = <String>{};
      void log(String what) => what;
      for (final r in local) {
        for (var i = 0; i < _days; i++) {
          if (_covers(r, _date(i))) truth[_date(i)] = _statement(r);
        }
      }
      for (var step = 0; step < 14; step++) {
        final op = random.nextInt(5);
        final what = StringBuffer('seed=$seed step=$step op=$op');
        switch (op) {
          case 0: // selected-day export
            final days = {for (var i = 0; i < _days; i++) if (random.nextBool()) _date(i)};
            files.add(rangesOnDays(local, days, newId: newId));
            what.write(' export $days');
          case 1: // restore a file (maybe an old one, maybe twice)
            final file = files[random.nextInt(files.length)];
            local = [...local, ...rangesToAdd(local: local, incoming: file, newId: newId)];
            final once = local.length;
            local = [...local, ...rangesToAdd(local: local, incoming: file, newId: newId)];
            expect(local.length, once, reason: '$what: a repeat restore must add nothing');
          case 2: // the wearer edits a row (own id kept)
            if (local.isEmpty) continue;
            final index = random.nextInt(local.length);
            final old = local[index];
            final a = random.nextInt(_days), b = a + random.nextInt(_days - a);
            final kind = ['Dm', 'D', 'N'][random.nextInt(3)];
            final edited = _make(old.id, a, b, kind);
            local[index] = edited;
            for (var i = 0; i < _days; i++) {
              final d = _date(i);
              if (_covers(old, d) && !_covers(edited, d)) truth.remove(d);
              if (_covers(edited, d)) {
                truth[d] = _statement(edited);
                deleted.remove(d);
              }
            }
            what.write(' edit ${old.id} -> $a..$b $kind');
          case 3: // deleteDays
            final days = {for (var i = 0; i < _days; i++) if (random.nextInt(4) == 0) _date(i)};
            local = rangesWithoutDays(local, days, newId: newId);
            for (final d in days) {
              truth.remove(d);
              deleted.add(d);
              expect(local.any((r) => _covers(r, d)), isFalse, reason: '$what: deleted $d still covered');
            }
          case 4: // restore the oldest file again (the original backup)
            local = [...local, ...rangesToAdd(local: local, incoming: files.first, newId: newId)];
        }
        log(what.toString());
        // Invariants after every step.
        final ids = local.map((r) => r.id).toList();
        expect(ids.toSet(), hasLength(ids.length), reason: '$what: duplicate ids');
        final exposures = RangeExposures(ranges: local, realEvents: const [], absences: const []);
        for (final entry in truth.entries) {
          expect(
            local.any((r) => _covers(r, entry.key) && _statement(r) == entry.value),
            isTrue,
            reason: '$what: the wearer\'s statement ${entry.value} for ${entry.key} was lost',
          );
          if (entry.value == 'N') {
            expect(exposures.on('t', entry.key), isNull,
                reason: '$what: ${entry.key} is not-done yet has a nominal dose');
          }
        }
      }
    }
  });
}
