// Source guard (modelled on the one in test/import_gate_test.dart): every
// public `Future` method of LocalRepositoryImpl either goes through the focus
// check or is listed below with the reason it need not.
//
// "Goes through the focus check" = the method's own text calls `_focusCheck(`
// (the single helper the implementer adds to LocalRepositoryImpl) or names
// `ImportFocus.` directly. Adding a read without either fails this test.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/import_focus.dart';

/// Public Future methods that need no focus check, and why.
const _allowed = <String, String>{
  // Pure compute / memory: no database handle is asked for.
  'getProfile': 'copies the in-memory profile map',
  'spotCheck': 'decodes the caller-supplied records off-isolate',
  'breathingCoherence': 'computes over the caller-supplied records',
  // Writes: not reads. The design pauses reads; writes belong to user actions
  // and the engine, and go through the writer connection the import owns.
  'setStepGoal': 'write',
  'discardActivity': 'write',
  'confirmActivity': 'write',
  'deleteWorkout': 'write',
  'setWorkoutPrivate': 'write',
  'startWorkout': 'write',
  'endWorkout': 'write',
  'logManualWorkout': 'write',
  'setWorkoutWindow': 'write',
  'rescoreRecentSessions': 'write',
  'postJournal': 'write',
  'postJournalMetrics': 'write',
  'postCustomJournalField': 'write',
  'deleteCustomJournalField': 'write',
  'postCycleLog': 'write',
  'deleteCycleLog': 'write',
  'postCycleSymptoms': 'write',
};

final _decl = RegExp(
    r'^  (?:static )?Future<(?:[^;{=]|\n)*?\b([A-Za-z]\w*)\s*(?:<[^>]*>)?\(',
    multiLine: true);

/// Public Future method name -> its text (up to the next member).
Map<String, String> _publicFutureMethods() {
  final src = File('lib/data/local_repository_impl.dart').readAsStringSync();
  final body = src.substring(0, src.indexOf('\nclass _ZoneAnchors'));
  final out = <String, String>{};
  void add(String name, int start) {
    final rest = body.substring(start);
    final next = RegExp(r'\n  [A-Za-z@/]').firstMatch(rest.substring(1));
    out[name] = next == null ? rest : rest.substring(0, next.start + 1);
  }

  for (final m in _decl.allMatches(body)) {
    final name = m[1]!;
    if (!name.startsWith('_')) add(name, m.start);
  }
  // Record return types contain braces, which the pattern above skips.
  final rec = RegExp(r'^  Future<\(\{[^)]*\}\)>\s+([a-z]\w*)\(', multiLine: true);
  for (final m in rec.allMatches(body)) {
    add(m[1]!, m.start);
  }
  return out;
}

bool _checksFocus(String text) =>
    text.contains('_focusCheck(') || text.contains('ImportFocus.');

void main() {
  final methods = _publicFutureMethods();

  test('the scan finds the repository reads it is meant to guard', () {
    for (final n in const [
      'getToday',
      'getTodayStored',
      'getDayHeart',
      'getChart',
      'sleepWindows',
      'getSessions',
      'getNightBeats',
      'availableDays',
    ]) {
      expect(methods.keys, contains(n));
    }
    expect(methods.length, greaterThan(50));
  });

  test('every public read goes through the focus check or is allow-listed', () {
    final missing = [
      for (final e in methods.entries)
        if (!_allowed.containsKey(e.key) && !_checksFocus(e.value)) e.key,
    ];
    expect(missing, isEmpty,
        reason: 'These LocalRepositoryImpl methods read without asking '
            'ImportFocus (call _focusCheck( or add them to _allowed with a '
            'reason): $missing');
  });

  test('the allow-list holds no stale or needlessly listed entry', () {
    for (final e in _allowed.entries) {
      expect(methods.keys, contains(e.key), reason: '${e.key} no longer exists');
      expect(e.value, isNotEmpty);
      expect(_checksFocus(methods[e.key]!), isFalse,
          reason: '${e.key} checks focus now; drop it from _allowed');
    }
  });

  test('the focus check is a single helper, not copies of its logic', () {
    final src = File('lib/data/local_repository_impl.dart').readAsStringSync();
    expect('void _focusCheck('.allMatches(src).length +
            'Future<void> _focusCheck('.allMatches(src).length +
            '_focusCheck('.allMatches(src).length,
        greaterThan(0),
        reason: 'LocalRepositoryImpl defines and calls _focusCheck');
    expect(src, contains('ReadPaused'));
  });

  test('every other read entry point is registered and consults focus', () {
    expect(ImportFocus.readEntryPoints, containsAll(const [
      'repo.read', // LocalRepositoryImpl public reads
      'insights.refresh',
      'notifications.schedule',
      'health.export',
      'coach.read',
      'widget.snapshot',
    ]));
    const files = {
      'lib/data/local_repository_impl.dart': 1,
      'lib/widget/widget_service.dart': 1,
      'lib/health/health_export.dart': 1,
      'lib/coach/coach_engine.dart': 1,
      'lib/state/artifact_warmer.dart': 1, // insights.refresh
      'lib/state/app_state.dart': 1, // notifications.schedule
    };
    files.forEach((f, n) {
      final src = File(f).readAsStringSync();
      expect('ImportFocus.'.allMatches(src).length, greaterThanOrEqualTo(n),
          reason: f);
    });
  });
}
