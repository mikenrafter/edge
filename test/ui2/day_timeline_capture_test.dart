// WHY: old/new review artifacts for the actual route and the new filter sheet.
// This does not approve or rewrite checked-in pixel goldens.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../support/apk2_review_harness.dart';
import '../support/pilot_shots.dart';
import '../support/pin_tz.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;

void main() {
  pinProcessTimeZone('America/Denver');
  setUpAll(skLoadAppFonts);
  for (final scenario in [
    (locale: 'en', width: 412.0, scale: 1.0),
    (locale: 'de', width: 320.0, scale: 2.0),
    (locale: 'th', width: 412.0, scale: 1.0),
    (locale: 'hi', width: 412.0, scale: 1.0),
  ]) {
    testWidgets(
      'capture ${scenario.locale} ${scenario.width} ${scenario.scale}',
      (t) async {
        final rig = await Apk2Rig.create(t);
        await rig.mount(
          t,
          size: Size(scenario.width, 850),
          screen: pilotShot(
            MaterialApp(
              locale: Locale(scenario.locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: buildTheme(Brightness.light),
              home: MediaQuery(
                data: MediaQueryData(
                  textScaler: TextScaler.linear(scenario.scale),
                ),
                child: const DayTimelineScreen(day: apk2Day),
              ),
            ),
          ),
        );
        final name =
            '${scenario.locale}-${scenario.width.toInt()}-${scenario.scale}';
        await takePilotShot(t, 'timeline-$name');
        if (Platform.environment['PHASE3A_BASELINE'] != '1') {
          final filter = find.byKey(const ValueKey('timeline-filter'));
          expect(filter, findsOneWidget);
          await t.ensureVisible(filter);
          await t.pump();
          await t.tap(filter);
          await t.pumpAndSettle();
          await takePilotShot(t, 'filter-$name');
        }
      },
    );
  }
}
