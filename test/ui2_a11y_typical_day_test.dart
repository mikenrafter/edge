// WHY: the Typical day energy curve was a 160 px picture with no semantics:
// the screen's point was invisible to TalkBack (inventory 3.02, P1), and its
// correlation rows were read as "rho equals 0.42 dot n equals 14" (2.08).
//
// CLAIM(A11Y-CHART): the curve speaks where it peaks and dips; the hour ticks
// are not read; a correlation row is read in words.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/data/typical_day_model.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/screens/circadian_detail.dart';
import 'package:openstrap_edge/ui2/screens/typical_day.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/a11y_tree.dart';

int _minutes(String hhmm) {
  final p = hhmm.split(':');
  return int.parse(p[0]) * 60 + int.parse(p[1]);
}

void main() {
  testWidgets('the energy curve says its peak and dip hours', (t) async {
    final h = t.ensureSemantics();
    ClockFormatController.seed(ClockFormat.h24);
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(412, 1400);
    addTearDown(t.view.reset);
    // Body clock peak at 15:00, woke at 07:00 after 8 h (the golden's fixture).
    final data = TypicalDayData(
        sleep: const ClockWindow(1380, 420),
        quiet: const ClockWindow(1380, 420),
        meals: const [720, 1140],
        circadian: CircadianData(
            chronotypeLabel: 'Intermediate',
            cosinorV: const {'acrophase_hours': 15.0},
            alertness: ana.alertnessForecast(
                wakeLocalHour: 7, sleepDurationHours: 8, circadianAcrophaseHours: 15)));
    await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TypicalDayScreen(data: data)));
    await t.pumpAndSettle();

    final curve = spokenLabels(t).where((l) => l.startsWith('Energy forecast')).toList();
    expect(curve, hasLength(1), reason: 'base: the curve had no node at all');
    final m = RegExp(r'highest around (\d\d:\d\d), lowest around (\d\d:\d\d)').firstMatch(curve.single);
    expect(m, isNotNull, reason: curve.single);
    // Oracle: the forecast follows the body clock, so its high is in the
    // afternoon around the 15:00 peak, and its low is not.
    final peak = _minutes(m!.group(1)!), dip = _minutes(m.group(2)!);
    expect(peak, inInclusiveRange(12 * 60, 18 * 60), reason: curve.single);
    expect((peak - dip).abs(), greaterThanOrEqualTo(3 * 60), reason: curve.single);

    expect(spokenLabels(t).any((l) => l == '06:00' || l == '12:00'), isFalse,
        reason: 'axis ticks are not read');
    expect(spokenLabels(t).any((l) => l.contains('ρ =')), isFalse,
        reason: 'the correlation rows are read in words');
    expect(spokenLabels(t).any((l) => l.contains('paired days')), isTrue);
    h.dispose();
  });
}
