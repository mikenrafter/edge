// 8AK C (red): the ECG counts are named "Double tap + N ECG tap(s)".
//
// USER: count 3 = "Double tap + 1 ECG tap", 4 = "Double tap + 2 ECG taps", ...,
// count 2 = "Double tap".
//
// ASSUMED API:
//   * NEW lib/gestures/tap_names.dart: `String ecgTapCountName(int count)`,
//     the plain-English name for logs and anything outside a widget tree:
//       2 -> "Double tap", 3 -> "Double tap + 1 ECG tap",
//       4 -> "Double tap + 2 ECG taps", 5 -> "Double tap + 3 ECG taps".
//     [count] is the activation count (2..5, the opening double tap is 2).
//   * lib/l10n/app_en.arb (+ gen-l10n): the message `gestureEcgTapName` with
//     ONE int placeholder `n` = the number of ECG taps (count - 2), a plural:
//       {n, plural, =0{Double tap} one{Double tap + {n} ECG tap}
//                   other{Double tap + {n} ECG taps}}
//     read as `AppLocalizations.gestureEcgTapName(int n)`. The other locales
//     fall back to the English text through the repo's usual gen-l10n
//     fallback (a translated entry may replace it later); they must still
//     answer, never throw or return an empty string.
//
// Failure mode today: neither exists (this file fails to compile until
// lib/gestures/tap_names.dart exists; the l10n tests fail on the missing
// getter).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/tap_names.dart';
import 'package:openstrap_edge/l10n/app_localizations_de.dart';
import 'package:openstrap_edge/l10n/app_localizations_en.dart';
import 'package:openstrap_edge/l10n/app_localizations_es.dart';
import 'package:openstrap_edge/l10n/app_localizations_fr.dart';
import 'package:openstrap_edge/l10n/app_localizations_hi.dart';
import 'package:openstrap_edge/l10n/app_localizations_zh.dart';

const Map<int, String> _names = {
  2: 'Double tap',
  3: 'Double tap + 1 ECG tap',
  4: 'Double tap + 2 ECG taps',
  5: 'Double tap + 3 ECG taps',
};

// Through `dynamic`, so a build without the getter fails the test that needs
// it and not the whole file at compile time.
String _l10n(Object loc, int n) =>
    (loc as dynamic).gestureEcgTapName(n) as String;

void main() {
  group('the plain-English name (logs, cards)', () {
    for (final e in _names.entries) {
      test('count ${e.key} is "${e.value}"', () {
        expect(ecgTapCountName(e.key), e.value);
      });
    }

    test('one ECG tap is singular, the rest plural', () {
      expect(ecgTapCountName(3), endsWith('1 ECG tap'));
      expect(ecgTapCountName(4), endsWith('2 ECG taps'));
    });
  });

  group('the localized name: an ICU plural over the number of ECG taps', () {
    test('English: 0, 1, 2, 3 ECG taps', () {
      final en = AppLocalizationsEn();
      for (final e in _names.entries) {
        expect(_l10n(en, e.key - 2), e.value);
      }
    });

    test('the same text as the plain helper, for every count', () {
      final en = AppLocalizationsEn();
      for (var count = 2; count <= 5; count++) {
        expect(_l10n(en, count - 2), ecgTapCountName(count));
      }
    });

    test('other locales answer (translated or the English fallback)', () {
      for (final loc in <Object>[
        AppLocalizationsDe(),
        AppLocalizationsEs(),
        AppLocalizationsFr(),
        AppLocalizationsHi(),
        AppLocalizationsZh(),
      ]) {
        for (var n = 0; n <= 3; n++) {
          final s = _l10n(loc, n);
          expect(s, isNotEmpty, reason: '${loc.runtimeType} n=$n');
          if (n > 0) {
            expect(s, contains('$n'), reason: '${loc.runtimeType} n=$n');
          }
        }
      }
    });
  });
}
