// Cycle plurals in the sleep-ring captions: zero, one and many all show the
// real count. fr and hi classify 0 as "one", so a singular that hard-codes
// "1" would print "1 cycle" for zero cycles.
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';

void main() {
  for (final lang in ['en', 'fr', 'hi']) {
    final l = lookupAppLocalizations(Locale(lang));
    final forms = <String, String Function(int)>{
      'homeSleepOnTrack': (n) => l.homeSleepOnTrack(n, 'X'),
      'homeSleepOnTrackDefault': (n) => l.homeSleepOnTrackDefault(n, 'X', 'T'),
      'homeSleepEstimateCompact': (n) => l.homeSleepEstimateCompact(n, 'X'),
      'homeSleepEstimateDefaultCompact': (n) =>
          l.homeSleepEstimateDefaultCompact(n, 'X'),
      'homeSleepEstimateDefaultTight': (n) =>
          l.homeSleepEstimateDefaultTight(n, 'X'),
    };
    forms.forEach((name, f) {
      for (final n in [0, 1, 2, 5]) {
        test('$lang $name: $n renders the count $n', () {
          final s = f(n);
          expect(RegExp('(?<!\\d)$n(?!\\d)').hasMatch(s), isTrue,
              reason: '"$s" should carry the count $n');
          if (n != 1) {
            expect(RegExp('(?<!\\d)1(?!\\d)').hasMatch(s), isFalse,
                reason: '"$s" shows 1 for $n');
          }
        });
      }
    });
  }

  test('estimate compact forms keep the estimate marker and, for a default '
      'target, say so (en, es, fr)', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final es = lookupAppLocalizations(const Locale('es'));
    final fr = lookupAppLocalizations(const Locale('fr'));
    expect(en.homeSleepEstimateCompact(4, '6h'), '~4 cycles · 6h');
    expect(en.homeSleepEstimateDefaultCompact(4, '6h'),
        '~4 cycles · 6h · default target');
    expect(es.homeSleepEstimateDefaultCompact(4, '6 h'), startsWith('~4 ciclos'));
    expect(es.homeSleepEstimateDefaultCompact(4, '6 h'), contains('objetivo'));
    expect(fr.homeSleepEstimateDefaultCompact(4, '6 h'), contains('objectif par défaut'));
    expect(fr.homeSleepEstimateDefaultTight(4, '6 h'), contains('par défaut'));
    expect(fr.homeSleepPctDefaultTight(92, '8 h'), contains('par défaut'));
  });
}
