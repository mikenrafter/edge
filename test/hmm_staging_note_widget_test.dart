// The Sleep screen says when the stages came from the experimental model, that
// they are not validated, and why the default estimate was shown instead (spec
// §7 items 2 and 3). English strings; other locales fall back to them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _onset = DateTime(2026, 5, 19, 23, 7).millisecondsSinceEpoch ~/ 1000;

const _claim =
    'Experimental sleep-stage estimate. Not validated against a clinical sleep '
    'study. Not for medical decisions.';
const _allDefault =
    'The experimental model showed little stage variation, so the default '
    'estimate is shown.';
const _generic =
    'The default estimate is shown for this night instead of the experimental '
    'model.';

SleepData _data(Map<String, Object?> staging) => SleepData(
      day: '2026-05-20',
      night: {
        'duration_min': 443,
        'in_bed_min': 486,
        'awake_min': 20,
        'efficiency': .91,
        'onset_ts': _onset,
        'wake_ts': _onset + 486 * 60,
        'light_min': 170,
        'deep_min': 85,
        'rem_min': 95,
        'hypnogram': [
          {'t': _onset, 'stage': 'light'},
          {'t': _onset + 3600, 'stage': 'deep'},
          {'t': _onset + 7200, 'stage': 'rem'},
          {'t': _onset + 486 * 60, 'stage': 'awake'},
        ],
        ...staging,
      },
    );

Future<void> _open(WidgetTester t, Map<String, Object?> staging) async {
  t.view.physicalSize = const Size(390 * 3, 6000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(Brightness.light),
    home: SleepDetail(data: _data(staging)),
  ));
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('an ordinary experimental night says it is experimental only',
      (t) async {
    await _open(t, {
      'staging_method': 'hmm628',
      'staging_effective_method': 'hmm628',
    });
    expect(find.text(_claim), findsOneWidget);
    expect(find.text(_allDefault), findsNothing);
    expect(find.text(_generic), findsNothing);
  });

  testWidgets('a fallback night shows the claim and the reason', (t) async {
    await _open(t, {
      'staging_method': 'hmm628',
      'staging_effective_method': 'cardio',
      'staging_fallback': 'hmm628_degenerate',
      'staging_fallback_sec': 29160,
    });
    expect(find.text(_claim), findsOneWidget);
    expect(find.text(_allDefault), findsOneWidget);
  });

  testWidgets('a mixed night says for how long the default was used',
      (t) async {
    await _open(t, {
      'staging_method': 'hmm628',
      'staging_effective_method': 'mixed',
      'staging_fallback': 'hmm628_degenerate',
      'staging_fallback_sec': 14219,
    });
    expect(find.text(_claim), findsOneWidget);
    expect(
        find.text('The experimental model showed little stage variation for '
            '237 min of this night; the default estimate is shown there.'),
        findsOneWidget);
  });

  testWidgets('an unknown fallback reason is shown generically, estimate kept',
      (t) async {
    await _open(t, {
      'staging_method': 'hmm628',
      'staging_effective_method': 'cardio',
      'staging_fallback': 'hmm628_from_the_future',
    });
    expect(find.text(_claim), findsOneWidget);
    expect(find.text(_generic), findsOneWidget);
    expect(find.textContaining('from_the_future'), findsNothing);
    expect(find.text('Through the night'), findsWidgets);
  });

  const someKnown =
      'The experimental model showed little stage variation for part of this '
      'night; the default estimate is shown there.';
  const someGeneric =
      'For part of this night, the default estimate is shown instead of the '
      'experimental model.';
  const uncertain =
      'The default estimate may be shown for some or all of this night '
      'instead of the experimental model.';

  testWidgets('mixed with malformed seconds: partial wording, no duration',
      (t) async {
    await _open(t, {
      'staging_method': 'hmm628',
      'staging_effective_method': 'mixed',
      'staging_fallback': 'hmm628_degenerate',
    });
    expect(find.text(someKnown), findsOneWidget);
    expect(find.text(_allDefault), findsNothing);
    expect(find.textContaining(' min of this night'), findsNothing);
  });

  testWidgets('mixed with an unknown reason: partial generic wording',
      (t) async {
    await _open(t, {
      'staging_method': 'hmm628',
      'staging_effective_method': 'mixed',
      'staging_fallback': 'hmm628_from_the_future',
      'staging_fallback_sec': 14219,
    });
    expect(find.text(someGeneric), findsOneWidget);
    expect(find.text(_generic), findsNothing);
    expect(find.text(_allDefault), findsNothing);
  });

  for (final effective in <Object?>[null, 'v9', 'hmm628']) {
    testWidgets('unknown scope ($effective) claims neither whole nor part',
        (t) async {
      await _open(t, {
        'staging_method': 'hmm628',
        'staging_effective_method': ?effective,
        'staging_fallback': 'hmm628_degenerate',
        'staging_fallback_sec': 14219,
      });
      expect(find.text(uncertain), findsOneWidget);
      expect(find.text(_allDefault), findsNothing);
      expect(find.text(someKnown), findsNothing);
      expect(find.text(_claim), findsOneWidget);
    });
  }

  testWidgets('an older payload without the keys displays as before',
      (t) async {
    await _open(t, const {});
    expect(find.textContaining('Experimental sleep-stage'), findsNothing);
    expect(find.text(_allDefault), findsNothing);
    expect(find.text(_generic), findsNothing);
  });

  testWidgets('an older experimental night gets the claim and no fallback',
      (t) async {
    await _open(t, {'staging_method': 'hmm628'});
    expect(find.text(_claim), findsOneWidget);
    expect(find.text(_allDefault), findsNothing);
    expect(find.text(_generic), findsNothing);
  });

  testWidgets('the default method never claims a fallback, even from a '
      'hand-edited row', (t) async {
    await _open(t, {
      'staging_method': 'cardio',
      'staging_fallback': 'hmm628_degenerate',
    });
    expect(find.textContaining('Experimental sleep-stage'), findsNothing);
    expect(find.text(_allDefault), findsNothing);
  });
}
