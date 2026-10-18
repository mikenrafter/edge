// The cross-day input records are kept between passes: a pass reads and
// decodes only the days whose stored result changed, and the artifact it
// writes is exactly the one a rebuild from nothing would write.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/crossday_input.dart';

const _today = '2026-03-10';

String _day(int n) =>
    DateTime.utc(2026, 3, 10 - (9 - n)).toIso8601String().substring(0, 10);

/// A served-row stand-in: `meta` is what the payload-free read returns, the
/// payload is what only a full read carries.
class _Row {
  _Row(this.day, {this.at = 1000, this.finalized = 1, this.value = 50.0});
  final String day;
  int at;
  int finalized;
  double value;
  bool skipped = false;
  String? payload;

  Map<String, dynamic> get meta => {
        'day_id': day,
        'algo_version': 101,
        'computed_at': at,
        'finalized': finalized,
        'rhr': value,
      };

  Map<String, dynamic> get full => {
        ...meta,
        'payload_json': payload ??
            jsonEncode({
              'scalars': {'strain': value + 1, 'steps': 1000},
              if (skipped) 'skipped': true,
            }),
      };
}

class _Run {
  _Run(this.rows, {this.today = _today});
  final List<_Row> rows; // oldest first
  String today;
  int made = 0;

  Map<String, dynamic>? make(Map<String, dynamic> row, Map<String, dynamic> p) {
    made++;
    final sc = (p['scalars'] as Map).cast<String, dynamic>();
    return {
      'date': row['day_id'],
      'rhr': row['rhr'],
      'strain': sc['strain'],
      'steps': sc['steps'],
    };
  }

  /// One pass as the engine runs it, over [kept] from the previous artifact.
  String pass(Object? previousArtifact) {
    final meta = [for (final r in rows.reversed) r.meta];
    final kept = keptCrossDayInput(previousArtifact);
    final need = crossDayDaysToRead(meta, kept).toSet();
    final full = {
      for (final r in rows)
        if (need.contains(r.day)) r.day: r.full,
    };
    made = 0;
    final out = assembleCrossDayInput(
      meta: meta,
      today: today,
      kept: kept,
      full: full,
      makeRecord: make,
    );
    return jsonEncode({
      'algo_version': 101,
      'built_for_day': today,
      'days': out.days,
      'row_keys': out.keys,
    });
  }
}

List<_Row> _rows() => [for (var i = 0; i < 10; i++) _Row(_day(i), value: 50.0 + i)];

String _scratch(_Run r) => _Run(r.rows, today: r.today).pass(null);

void main() {
  test('a first pass builds every record, oldest first, today flagged', () {
    final r = _Run(_rows());
    final art = jsonDecode(r.pass(null)) as Map;
    expect(r.made, 10);
    final days = (art['days'] as List).cast<Map>();
    expect(days.map((d) => d['date']), [for (var i = 0; i < 10; i++) _day(i)]);
    expect(days.last['is_today'], true);
    expect(days.last.containsKey('unsettled'), isFalse,
        reason: 'the fixture row is finalized');
    expect(days.first.containsKey('is_today'), isFalse);
    expect((art['row_keys'] as Map).length, 10);
  });

  test('an unchanged day set reads nothing and rewrites the same artifact', () {
    final r = _Run(_rows());
    final first = r.pass(null);
    final second = r.pass(jsonDecode(first));
    expect(r.made, 0);
    expect(second, first);
    expect(crossDayInputCurrent(jsonDecode(first), [
      for (final x in r.rows.reversed) x.meta,
    ]), isTrue);
  });

  test('only today changing re-reads only today; equals a rebuild', () {
    final r = _Run(_rows());
    var art = r.pass(null);
    for (var i = 1; i <= 4; i++) {
      r.rows.last
        ..at += i
        ..value += 1
        ..finalized = 0;
      art = r.pass(jsonDecode(art));
      expect(r.made, 1, reason: 'pass $i');
      expect(art, _scratch(r), reason: 'pass $i');
      final today = (jsonDecode(art)['days'] as List).last as Map;
      expect(today['unsettled'], true);
      expect(today['is_today'], true);
    }
  });

  test('a replaced earlier row is read again, and only that one', () {
    final r = _Run(_rows());
    var art = r.pass(null);
    r.rows[3]
      ..at = 5000
      ..value = 99;
    art = r.pass(jsonDecode(art));
    expect(r.made, 1);
    expect(art, _scratch(r));
    expect(((jsonDecode(art)['days'] as List)[3] as Map)['rhr'], 99);
  });

  test('a day that becomes finalized changes key and loses its flag', () {
    final r = _Run(_rows());
    r.rows.last.finalized = 0;
    var art = r.pass(null);
    expect(((jsonDecode(art)['days'] as List).last as Map)['unsettled'], true);
    r.rows.last
      ..finalized = 1
      ..at += 1;
    art = r.pass(jsonDecode(art));
    expect(r.made, 1);
    expect(((jsonDecode(art)['days'] as List).last as Map).containsKey('unsettled'),
        isFalse);
    expect(art, _scratch(r));
  });

  test('midnight: nothing is re-read, the today stamps move to the new day', () {
    final r = _Run(_rows());
    var art = r.pass(null);
    r.rows.add(_Row('2026-03-11', value: 70, finalized: 0));
    r.today = '2026-03-11';
    art = r.pass(jsonDecode(art));
    expect(r.made, 1, reason: 'only the new day');
    expect(art, _scratch(r));
    final days = (jsonDecode(art)['days'] as List).cast<Map>();
    expect(days.where((d) => d['is_today'] == true).map((d) => d['date']),
        ['2026-03-11']);
  });

  test('a day leaving the window drops out; the rest are kept', () {
    final r = _Run(_rows());
    var art = r.pass(null);
    r.rows.removeAt(0);
    art = r.pass(jsonDecode(art));
    expect(r.made, 0);
    expect(art, _scratch(r));
    expect((jsonDecode(art)['days'] as List).length, 9);
  });

  test('a skipped row yields no record and is not read again', () {
    final rows = _rows();
    rows[4].skipped = true;
    final r = _Run(rows);
    var art = r.pass(null);
    final days = (jsonDecode(art)['days'] as List).cast<Map>();
    expect(days.length, 9);
    expect((jsonDecode(art)['row_keys'] as Map).containsKey(_day(4)), isTrue);
    art = r.pass(jsonDecode(art));
    expect(r.made, 0);
    expect(art, _scratch(r));
  });

  test('an artifact without row keys is rebuilt in full', () {
    final r = _Run(_rows());
    final old = jsonDecode(r.pass(null)) as Map..remove('row_keys');
    r.pass(old);
    expect(r.made, 10);
    expect(crossDayInputCurrent(old, [for (final x in r.rows.reversed) x.meta]),
        isFalse);
  });

  test('crossDayInputCurrent is false for any changed, added or lost row', () {
    final r = _Run(_rows());
    final art = jsonDecode(r.pass(null));
    List<Map<String, dynamic>> meta() => [for (final x in r.rows.reversed) x.meta];
    expect(crossDayInputCurrent(art, meta()), isTrue);
    r.rows[2].at += 1;
    expect(crossDayInputCurrent(art, meta()), isFalse);
    r.rows[2].at -= 1;
    r.rows.add(_Row('2026-03-11'));
    expect(crossDayInputCurrent(art, meta()), isFalse);
    r.rows.removeLast();
    r.rows.removeAt(0);
    expect(crossDayInputCurrent(art, meta()), isFalse);
    expect(crossDayInputCurrent('nope', meta()), isFalse);
    expect(crossDayInputCurrent(null, const []), isTrue,
        reason: 'no rows, nothing kept: nothing to rebuild');
  });

  test('random sequences: every pass equals a rebuild from nothing', () {
    var seed = 7;
    int next(int n) => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) % n;
    final r = _Run(_rows());
    var art = r.pass(null);
    for (var step = 0; step < 60; step++) {
      switch (next(5)) {
        case 0:
          r.rows[next(r.rows.length)]
            ..at += 1 + next(5)
            ..value += next(3).toDouble();
        case 1:
          r.rows.last
            ..at += 1
            ..finalized = next(2);
        case 2:
          if (r.rows.length > 4) r.rows.removeAt(next(r.rows.length));
        case 3:
          final last = DateTime.parse(r.rows.last.day).add(const Duration(days: 1));
          final label = last.toIso8601String().substring(0, 10);
          r.rows.add(_Row(label, at: step, finalized: 0));
          r.today = label;
          if (r.rows.length > 12) r.rows.removeAt(0);
        case 4:
          r.rows[next(r.rows.length)]
            ..skipped = next(2) == 0
            ..at += 1;
      }
      art = r.pass(jsonDecode(art));
      expect(art, _scratch(r), reason: 'step $step');
    }
  });
}
