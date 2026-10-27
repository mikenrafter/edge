import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/typical_day_model.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/screens/typical_day.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> mountTypical(WidgetTester t, TypicalDayData data) async {
  t.view.devicePixelRatio=1; t.view.physicalSize=const Size(412,1400);
  addTearDown(t.view.reset);
  ClockFormatController.seed(ClockFormat.h24);
  await t.pumpWidget(MaterialApp(theme:buildTheme(Brightness.light),
    localizationsDelegates:AppLocalizations.localizationsDelegates,
    supportedLocales:AppLocalizations.supportedLocales,
    home:TypicalDayScreen(data:data)));
  await t.pumpAndSettle();
}
void main() {
  testWidgets('daytime sleep remains 08–16 and wrapped quiet hours remain 23–07', (t) async {
    await mountTypical(t,const TypicalDayData(sleep:ClockWindow(480,960),quiet:ClockWindow(1380,420)));
    expect(find.text('Expected sleep: 08:00–16:00'),findsOneWidget);
    expect(find.text('Quiet hours: 23:00–07:00'),findsOneWidget);
    expect(find.text('Not enough recent sleep data for a curve.'),findsOneWidget);
    expect(find.text('Your pattern so far, 0 days'),findsOneWidget);
    expect(t.takeException(),isNull);
    final boundary = t.renderObject<RenderRepaintBoundary>(find.descendant(
      of: find.byType(TypicalDayPlot), matching: find.byType(RepaintBoundary)));
    await t.runAsync(() async {
      final image = await boundary.toImage();
      final pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int alpha(int hour, int y) => pixels.getUint8(
        (y * image.width + (image.width * hour / 24).floor()) * 4 + 3);
      // Paint, not only the text: sleep is 08–16, and quiet spans midnight.
      expect(alpha(9, 132), greaterThan(0));
      expect(alpha(15, 132), greaterThan(0));
      expect(alpha(3, 132), 0);
      expect(alpha(17, 132), 0);
      expect(alpha(1, 114), greaterThan(0));
      expect(alpha(23, 114), greaterThan(0));
      expect(alpha(12, 114), 0);
      image.dispose();
    });
  });
  testWidgets('meal editing persists removal and a new picked clock time', (t) async {
    SharedPreferences.setMockInitialValues({});
    await TypicalMealTimes.save([480,1140]);
    await mountTypical(t,const TypicalDayData(meals:[480,1140]));
    await t.tap(find.text('Edit meal times'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Remove').first);
    await t.pump();
    await t.tap(find.text('Add time'));
    await t.pumpAndSettle();
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(await TypicalMealTimes.load(),[720,1140]);
    expect(find.text('12:00 · 19:00'),findsOneWidget);
    expect(t.takeException(),isNull);
  });
}
