// Sol r1 P1 (design 02, AGENTS 3.10): the resumed pass must not serialise the
// streaming RR state or the day curves on the UI isolate. `DayTailInput.fromStates`
// did (ResumeWriter over the RR state and the growing curve pairs, ~41 ms on a
// restored 24 h day) before every dispatch. The worker is handed the stored
// checkpoint bytes the engine already holds (`probe.cp.state`) and decodes them
// itself; nothing O(data) is written on the calling isolate.
//
// A source guard (no runtime seam can see "not on this isolate" cheaply): the
// dispatch path - `_streamDayTail` in the engine and the input type in
// day_tail_fold.dart - names no ResumeWriter, no `fromStates`, and no state
// `.write(`; the entry decodes with `decodeDayResumeState`; and the engine hands
// the stored blob over.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _code(String path) => File(path)
    .readAsLinesSync()
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  final fold = _code('lib/compute/day_tail_fold.dart');
  final engine = _code('lib/compute/derivation_engine.dart');
  final start = engine.indexOf('Future<DayTailResult?> _streamDayTail(');
  final end = engine.indexOf('Future<PreparedDerivationDay> _withFullRr(');
  final dispatch = engine.substring(start, end);

  test('the input type has no serialising factory and writes no state bytes', () {
    expect(fold, isNot(contains('fromStates')));
    expect(fold, isNot(contains('ResumeWriter')));
    expect(fold, isNot(contains('.write(')));
  });

  test('the dispatch path serialises nothing', () {
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    expect(dispatch, isNot(contains('fromStates')));
    expect(dispatch, isNot(contains('ResumeWriter')));
    expect(dispatch, isNot(contains('.write(')));
    expect(dispatch, isNot(contains('encodeDayResumeState')));
  });

  test('the engine hands the worker the stored checkpoint blob', () {
    expect(dispatch, contains('probe.cp.state'));
    expect(dispatch, contains('foldDayTailHeavy'));
  });

  test('the worker decodes the blob itself', () {
    expect(fold, contains('decodeDayResumeState'));
  });
}
