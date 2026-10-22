// RULES B.2 on the nightly sweep ("What changed", the briefing inputs, the
// notification headline). A finding that USES any older-calculation value --
// today's, or any day of the history its usual range and extremes come from --
// is marked: an asterisk beside the figure it touches, the versions on the
// finding, and the localized note (olderVersionSweepFinding) wherever it shows.
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ai/briefing_engine.dart';
import 'package:openstrap_edge/ai/nightly_sweep.dart';
import 'package:openstrap_edge/l10n/app_localizations_de.dart';
import 'package:openstrap_edge/l10n/app_localizations_en.dart';
import 'package:openstrap_edge/l10n/sweep_text.dart';

import 'support/older_version_fixtures.dart';

/// 30 days of 6..8 strain (history), today 20. [histOlder]: days back whose
/// history value is older (with the given version), [todayOlder] today's.
Future<List<SweepFinding>> _findings(
    {int? todayOlder, Map<int, int> histOlder = const {}}) async {
  final pts = [
    for (var back = 30; back >= 1; back--)
      cp(back, 6 + back % 3, older: histOlder[back]),
    cp(0, 20, older: todayOlder),
  ];
  final s = await collectSweepSeries(
      OlderRepo(charts: {'strain': pts}), DateTime.now());
  return sweepFindings(s).where((f) => f.key == 'strain').toList();
}

void main() {
  final en = AppLocalizationsEn();
  final de = AppLocalizationsDe();

  test('today older: asterisk on the figure, the version on the finding',
      () async {
    final f = await _findings(todayOlder: 104);
    expect(f, hasLength(1));
    expect(f.single.text, contains('strain 20.0* — '));
    expect(f.single.olderVersions, [104]);
    // The text itself carries no English marker prose: the note is localized.
    expect(f.single.text, isNot(contains('older calculation')));
    expect(sweepFindingText(en, f.single),
        contains(en.olderVersionSweepFinding(104)));
  });

  test('only the history is older: the finding that compares against it is '
      'marked', () async {
    final f = await _findings(histOlder: {5: 104, 9: 104});
    expect(f, hasLength(1));
    expect(f.single.olderVersions, [104]);
    expect(f.single.text, contains('strain 20.0 — '),
        reason: 'today is a current value');
    expect(f.single.text, matches(RegExp(r'usually [\d.]+–[\d.]+\*\)$')),
        reason: 'the range it quotes is built partly from older values');
    expect(sweepFindingText(en, f.single),
        contains(en.olderVersionSweepFinding(104)));
  });

  test('mixed versions are all named, ascending', () async {
    final f = await _findings(todayOlder: 104, histOlder: {3: 103});
    expect(f.single.olderVersions, [103, 104]);
    final shown = sweepFindingText(en, f.single);
    expect(shown, contains(en.olderVersionSweepFinding(103)));
    expect(shown, contains(en.olderVersionSweepFinding(104)));
  });

  test('nothing older: plain text, no versions, no note', () async {
    final f = await _findings();
    expect(f.single.olderVersions, isEmpty);
    expect(f.single.text, isNot(contains('*')));
    expect(sweepFindingText(en, f.single), f.single.text);
  });

  test('the note is localized through the key, not English prose', () async {
    final f = await _findings(todayOlder: 104);
    final shown = sweepFindingText(de, f.single);
    expect(shown, contains(de.olderVersionSweepFinding(104)));
    expect(shown, isNot(contains('Older calculation')));
  });

  test('the notification headline carries the marker and the version',
      () async {
    final f = await _findings(histOlder: {5: 104});
    final h = sweepHeadline(f)!;
    expect(h, contains('*'));
    expect(h, contains('(v104)'));
    final plain = sweepHeadline(await _findings())!;
    expect(plain, isNot(contains('*')));
    expect(plain, isNot(contains('(v')));
  });

  test('the briefing input for a flagged finding says so; a plain one does '
      'not', () async {
    final flagged = sweepInputs(await _findings(todayOlder: 104));
    final line = (flagged['unusual_for_you'] as List).single as String;
    expect(line, contains('20.0*'));
    expect(line, contains('older calculation (v104)'));
    final plain = sweepInputs(await _findings());
    expect((plain['unusual_for_you'] as List).single as String,
        isNot(contains('older calculation')));
  });

  test('collectSweepSeries keeps each value\'s flag with the value', () async {
    final pts = [
      for (var back = 20; back >= 1; back--)
        cp(back, 6 + back % 3, older: back == 7 ? 103 : null),
      cp(0, 9, older: 104),
    ];
    final s = (await collectSweepSeries(
            OlderRepo(charts: {'strain': pts}), DateTime.now()))
        .single;
    expect(s.todayOlderVersion, 104);
    expect(s.history.length, 20);
    // history is oldest -> newest, so back 7 is at index 20 - 7.
    expect([for (var i = 0; i < 20; i++) s.historyOlderVersions.length > i ? s.historyOlderVersions[i] : 'missing'],
        [for (var i = 0; i < 20; i++) i == 13 ? 103 : null]);
  });
}
