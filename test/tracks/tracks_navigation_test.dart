import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SetRow;
import 'package:openstrap_edge/ui2/screens/typical_day.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

Future<void> _mount(WidgetTester t, Widget child) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(412, 5000);
  addTearDown(t.view.reset);
  await t.pumpWidget(ChangeNotifierProvider<LocaleController>.value(
    value: LocaleController.seed(null),
    child: MaterialApp(theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales, home: child)));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('Settings exposes Tracks among the personal tools', (t) async {
    await _mount(t, const MoreSettingsView());
    expect(find.text('Tracks'), findsOneWidget);
    final row = t.widget<SetRow>(find.ancestor(of: find.text('Tracks'),
      matching: find.byType(SetRow)));
    expect(row.onTap, isNotNull, reason: 'Tracks must open its hub');
    expect(t.takeException(), isNull);
  });

  testWidgets('Typical day offers a reachable Tracks hub', (t) async {
    await _mount(t, const TypicalDayScreen(data: TypicalDayData()));
    expect(find.text('Tracks'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
