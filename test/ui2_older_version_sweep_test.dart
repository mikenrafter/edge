// RULES B.2 on the nightly sweep ("What changed", the briefing, the
// notification headline): a finding that quotes today's value must not quote
// an older calculation's value unmarked. The finding text is one line, so it
// carries the asterisk beside the number and the version in words.
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ai/briefing_engine.dart';
import 'package:openstrap_edge/ai/nightly_sweep.dart';

import 'support/older_version_fixtures.dart';

Future<List<SweepFinding>> _findings({int? todayOlder}) async {
  final pts = [
    for (var back = 30; back >= 1; back--) cp(back, 6 + back % 3),
    cp(0, 20, older: todayOlder),
  ];
  final s = await collectSweepSeries(
      OlderRepo(charts: {'strain': pts}), DateTime.now());
  return sweepFindings(s);
}

void main() {
  test('today served from an older calculation is marked in the finding',
      () async {
    final f = (await _findings(todayOlder: 104)).where((f) => f.key == 'strain');
    expect(f, hasLength(1));
    expect(f.single.text, contains('20.0*'));
    expect(f.single.text, contains('older calculation (v104)'));
  });

  test('a current value is quoted plainly', () async {
    final f = (await _findings()).where((f) => f.key == 'strain');
    expect(f, hasLength(1));
    expect(f.single.text, contains('strain 20.0 '));
    expect(f.single.text, isNot(contains('*')));
    expect(f.single.text, isNot(contains('older calculation')));
  });
}
