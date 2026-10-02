// 8F — source guard: every chart painter site outside the gallery sits inside
// a ChartScrub (or a raw Scrubber).
//
// HEURISTIC (lexical containment). In each scanned file, comments and string
// bodies are blanked, then every `painter: <ChartPainter>(` site must lie
// inside the argument list of a `ChartScrub(` or `Scrubber(` call in the SAME
// file — i.e. the wrapper's `(` opens before the site and its matching `)`
// closes after it. A painter built in a helper and wrapped at the call site
// does NOT pass: put the ChartScrub inside the helper that builds the painter.
// See test/phase8/CONTRACTS.md §8F.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

const _painters = [
  'LineChart',
  'Bars',
  'Hypnogram',
  'ZoneBar',
  'Actogram',
  'HeatMap',
  'Spectrum',
  'Poincare',
  'NightStack',
  'DayLanes',
];

List<File> _scanned() => [
      ...dartFilesIn('lib/ui2/screens'),
      ...dartFilesIn('lib/ui2/activity'),
      File('lib/ui2/live_hr.dart'),
      if (File('lib/ui2/profile/live_devices.dart').existsSync())
        File('lib/ui2/profile/live_devices.dart'),
    ];

void main() {
  final site = RegExp('painter:\\s*(${_painters.join('|')})\\s*\\(');
  final wrapper = RegExp(r'\b(ChartScrub|Scrubber)\s*\(');

  test('every chart painter site is inside ChartScrub or Scrubber', () {
    final offenders = <String>[];
    var total = 0;
    for (final f in _scanned()) {
      final code = codeOnly(f.readAsStringSync());
      for (final m in site.allMatches(code)) {
        total++;
        if (!enclosedByCall(code, m.start, wrapper)) {
          offenders.add('${f.path}:${lineOf(code, m.start)} ${m.group(1)}');
        }
      }
    }
    expect(total, greaterThan(30),
        reason: 'the scan must find the real chart sites (non-vacuous)');
    expect(offenders, isEmpty,
        reason: 'unwrapped chart painters:\n${offenders.join('\n')}');
  });

  test('ChartScrub lives in grammar.dart or charts.dart and builds a Scrubber',
      () {
    final candidates = [
      File('lib/ui2/grammar.dart'),
      File('lib/ui2/charts.dart'),
    ];
    final home = candidates.where(
        (f) => codeOnly(f.readAsStringSync()).contains('class ChartScrub '));
    expect(home, hasLength(1),
        reason: 'ChartScrub lives in grammar.dart or charts.dart');
    final src = home.single.readAsStringSync();
    final body = src.substring(src.indexOf('class ChartScrub '));
    expect(codeOnly(body), contains('Scrubber('));
  });

  test('the guard itself: lexical containment works on a known case', () {
    const sample = '''
Widget a() => ChartScrub(label: 'x(', child: CustomPaint(painter: Bars(d, c)));
Widget b() => CustomPaint(painter: LineChart(d, c)); // ChartScrub(
''';
    final code = codeOnly(sample);
    final hits = site.allMatches(code).toList();
    expect(hits, hasLength(2));
    expect(enclosedByCall(code, hits[0].start, wrapper), isTrue);
    expect(enclosedByCall(code, hits[1].start, wrapper), isFalse);
  });
}
