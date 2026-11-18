// WHY: the export destination opens before any unresolved DB/plugin work and
// remains readable at large text. CLAIM(official-export-saved-bytes).
// catches: awaiting storage before push; duplicate routes; fixed-height copy.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/official_export.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  testWidgets('entry pushes immediately and a double tap joins one route',(tester)async {
    await tester.pumpWidget(MaterialApp(localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
      home:Builder(builder:(context)=>TextButton(onPressed:(){openOfficialExport(context);openOfficialExport(context);},child:const Text('Open')))));
    await tester.tap(find.text('Open'));await tester.pump();await tester.pump(const Duration(milliseconds:400));
    expect(find.byType(OfficialExportScreen),findsOneWidget);
    expect(find.text('Export for the official app'),findsWidgets);
    expect(tester.takeException(),isNull);
  });
  for(final settings in [('en',320.0,1.0),('en',412.0,2.0),('th',320.0,2.0),('ru',320.0,2.0)]) {
    testWidgets('ready layout ${settings.$1} ${settings.$2} ${settings.$3}',(tester)async {
      tester.view.physicalSize=Size(settings.$2,900);tester.view.devicePixelRatio=1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme:buildTheme(Brightness.light),locale:Locale(settings.$1),
        localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
        builder:(c,child)=>MediaQuery(data:MediaQuery.of(c).copyWith(textScaler:TextScaler.linear(settings.$3)),child:child!),
        home:const OfficialExportScreen()));
      await tester.pumpAndSettle();
      expect(find.byType(Scrollable),findsWidgets);
      expect(find.byType(CircularProgressIndicator),findsNothing);
      final buttons=find.byType(OutlinedButton);
      expect(buttons,findsWidgets);
      for(final button in buttons.evaluate()) expect(tester.getSize(find.byWidget(button.widget)).height,greaterThanOrEqualTo(48));
      expect(tester.takeException(),isNull);
    });
  }
}
