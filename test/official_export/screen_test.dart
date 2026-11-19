// WHY: the export destination opens before any unresolved DB/plugin work and
// remains readable at large text. CLAIM(official-export-saved-bytes).
// catches: awaiting storage before push; duplicate routes; fixed-height copy.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/official_export/coordinator.dart';
import 'package:openstrap_edge/data/official_export/session.dart';
import 'package:openstrap_edge/data/official_export/space_budget.dart';
import 'rich_fixture.dart';
import 'session_fixture.dart';
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
      final l=await AppLocalizations.delegate.load(Locale(settings.$1));
      await tester.scrollUntilVisible(find.text(l.officialExportChooseFolder),200,scrollable:find.byType(Scrollable).first);
      final buttons=find.byType(OutlinedButton);
      expect(buttons,findsWidgets);
      for(final button in buttons.evaluate()) {expect(tester.getSize(find.byWidget(button.widget)).height,greaterThanOrEqualTo(48));}
      expect(tester.takeException(),isNull);
    });
  }
  for(final recovery in [false,true]) {
    testWidgets('production saved report and recovery choice $recovery',(tester)async {
      final fx=(await tester.runAsync(RichFixture.build))!;
      final root=(await tester.runAsync(()=>Directory.systemTemp.createTemp('export_ui_')))!;
      final coordinator=OfficialExportCoordinator();
      try {
        await tester.runAsync(()async {
          final db=await databaseFactoryFfi.openDatabase(fx.forkPath);
          try {
            await db.execute('CREATE TABLE unsupported_notes(value TEXT)');
            final batch=db.batch();for(var i=0;i<301;i++){batch.insert('unsupported_notes',{'value':'private'});}await batch.commit(noResult:true);
          }finally{await db.close();}
        });
        final free=Space();final destination=Destination(root,free);
        final ready=Completer<void>();
        void changed(){if((coordinator.progress.stage==ExportStage.recoveryChoice || (!coordinator.active && coordinator.outcome!=null)) && !ready.isCompleted)ready.complete();}
        coordinator.addListener(changed);
        final boundary=GlobalKey();
        await tester.pumpWidget(MaterialApp(theme:buildTheme(Brightness.light),
          localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
          home:RepaintBoundary(key:boundary,child:OfficialExportScreen(coordinator:coordinator,
            snapshot:Snapshot(fx.forkPath),destination:destination,space:ExportSpaceBudget(source:free),privateRoot:Directory('${root.path}/private'),
            passphrasePrompt:Prompts(()async=>'pw',(_)async=>false)))));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Export').last,200,scrollable:find.byType(Scrollable).first);
        final start=find.ancestor(of:find.text('Export').last,matching:find.byType(OutlinedButton));
        await tester.runAsync(()async {
          tester.widget<OutlinedButton>(start).onPressed!();
          await ready.future.timeout(const Duration(minutes:2));
        });
        expect(coordinator.progress.stage,ExportStage.recoveryChoice,reason:'${coordinator.outcome}');
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Yes'),250,scrollable:find.byType(Scrollable).first);
        expect(find.text('Save a second file with data the official version does not yet support?'),findsOneWidget);
        expect(coordinator.official!.file.name,startsWith('openstrap-official-v0.12.2-'));
        final report=await tester.runAsync(()=>coordinator.omissionSummary());
        expect(report!.where((row)=>row['family']=='other').fold<int>(0,(n,row)=>n+(row['count'] as int)),greaterThanOrEqualTo(301));
        final rect=tester.getRect(find.text('Saved and verified'));
        await tester.pump(const Duration(seconds:1));expect(tester.getRect(find.text('Saved and verified')),rect);
        if(Platform.environment['P3_CAPTURE_DIR'] case final String path) {
          final rendered=boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image=await rendered.toImage();final png=await image.toByteData(format:ui.ImageByteFormat.png);
          await tester.runAsync(()async{await Directory(path).create(recursive:true);await File('$path/recovery-choice-$recovery.png').writeAsBytes(png!.buffer.asUint8List());});
          image.dispose();
        }
        final finished=Completer<void>();
        void finish(){if(!coordinator.active && !finished.isCompleted)finished.complete();}
        coordinator.addListener(finish);
        await tester.tap(find.text(recovery?'Yes':'No'));
        await tester.runAsync(()=>finished.future.timeout(const Duration(minutes:2)));
        await tester.pumpAndSettle();
        final outcome=coordinator.outcome as OfficialExportSaved;
        expect(outcome.recoveryStatus,recovery?RecoveryStatus.saved:RecoveryStatus.declined);
        expect(destination.creates,recovery?2:1);
        expect(tester.takeException(),isNull);
        coordinator.removeListener(changed);coordinator.removeListener(finish);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(()async{await coordinator.finish();await root.delete(recursive:true);await fx.dispose();});
        coordinator.dispose();
      }
    });
  }

}
