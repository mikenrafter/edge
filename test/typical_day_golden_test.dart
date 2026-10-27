// New baselines require visual review; intentionally never auto-generated.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/data/typical_day_model.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/screens/circadian_detail.dart';
import 'package:openstrap_edge/ui2/screens/typical_day.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'support/bundled_fonts.dart';

void main() {
  setUpAll(loadFonts);
  for (final fixture in [
    (name:'daytime_sleep',sleep:const ClockWindow(480,960),wake:16.0),
    (name:'overnight_sleep',sleep:const ClockWindow(1380,420),wake:7.0),
  ]) {
    testWidgets('Typical day ${fixture.name}',(t) async {
      ClockFormatController.seed(ClockFormat.h24);
      t.view.devicePixelRatio=1; t.view.physicalSize=const Size(412,1400);
      addTearDown(t.view.reset);
      final data=TypicalDayData(sleep:fixture.sleep,quiet:const ClockWindow(1380,420),
        meals:const [720,1140],circadian:CircadianData(chronotypeLabel:'Intermediate',
          cosinorV:const {'acrophase_hours':15.0},
          alertness:ana.alertnessForecast(wakeLocalHour:fixture.wake,
            sleepDurationHours:8,circadianAcrophaseHours:15)));
      await t.pumpWidget(RepaintBoundary(key:const ValueKey('typical-golden'),
        child:MaterialApp(debugShowCheckedModeBanner:false,theme:buildTheme(Brightness.light),
          localizationsDelegates:AppLocalizations.localizationsDelegates,
          supportedLocales:AppLocalizations.supportedLocales,
          home:TypicalDayScreen(data:data))));
      await t.pumpAndSettle();
      expect(t.takeException(),isNull);
      await expectLater(find.byKey(const ValueKey('typical-golden')),
        matchesGoldenFile('goldens/typical_day_${fixture.name}.png'));
    },tags:['golden']);
  }
}
