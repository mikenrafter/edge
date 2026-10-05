// Wiring that is a statement about where code lives, in the
// repo's usual source-grep style. Every check here fails today on behaviour
// (the symbol or call is not in the file yet), not on a missing import.
//
// Symbol names assumed: DerivePerf / DerivePhase (lib/compute/derive_perf.dart),
// `last_pass_perf`, `[perf] derive`, 'Last calculation', docs/perf.md.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  final engine = _read('lib/compute/derivation_engine.dart');

  group('engine', () {
    test('the pass is measured and published on snapshot()', () {
      expect(engine, contains('DerivePerf('));
      expect(engine, contains("'last_pass_perf'"));
      expect(engine, contains('[perf] derive'));
      expect(engine, contains('DerivePhase.prepare'));
      expect(engine, contains('DerivePhase.compute'));
      expect(engine, contains('DerivePhase.persist'));
    });
  });

  group('UI', () {
    test('Readiness and Circadian detail screens carry the label too', () {
      for (final f in const ['readiness_detail', 'circadian_detail']) {
        final src = _read('lib/ui2/screens/$f.dart');
        expect(src, contains('AsOfLabel'), reason: f);
        expect(src, contains('asOfFor('), reason: f);
      }
    });

    test('Health (Last night / Today / Trends) carries the label', () {
      final src = _read('lib/ui2/screens/health_screen.dart');
      expect(src, contains('AsOfLabel'));
      expect(src, contains('asOfFor('));
    });

    test('Settings > Developer has a read-only "Last calculation" row', () {
      final s = _read('lib/ui2/profile/settings.dart');
      expect(s, contains('Last calculation'));
      expect(s, contains('last_pass_perf'));
      expect(s, contains('DerivePerf.describe'));
    });
  });
}
