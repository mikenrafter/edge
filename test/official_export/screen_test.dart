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
      final boundary=GlobalKey();
      await tester.pumpWidget(MaterialApp(theme:buildTheme(Brightness.light),locale:Locale(settings.$1),
        localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
        builder:(c,child)=>MediaQuery(data:MediaQuery.of(c).copyWith(textScaler:TextScaler.linear(settings.$3)),child:child!),
        home:RepaintBoundary(key:boundary,child:const OfficialExportScreen())));
      await tester.pumpAndSettle();
      await capture(tester,boundary,'ready-${settings.$1}-${settings.$2}-${settings.$3}');
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
      Future<OfficialExportOutcome>? pending;
      Completer<void>? recoveryStarted,recoveryRelease;
      try {
        await tester.runAsync(()async {
          final db=await databaseFactoryFfi.openDatabase(fx.forkPath);
          try {
            await db.execute('CREATE TABLE unsupported_notes(value TEXT)');
            final batch=db.batch();for(var i=0;i<301;i++){batch.insert('unsupported_notes',{'value':'private'});}await batch.commit(noResult:true);
          }finally{await db.close();}
        });
        final free=Space();final destination=Destination(root,free);
        late Completer<void> ready;
        late Future<OfficialExportOutcome> running;
        await tester.runAsync(()async {
          ready=Completer<void>();
          if(recovery) {
            recoveryStarted=Completer<void>();recoveryRelease=Completer<void>();
            destination.recoveryStarted=recoveryStarted;destination.recoveryRelease=recoveryRelease;
          }
          running=coordinator.export(snapshot:Snapshot(fx.forkPath),privateRoot:Directory('${root.path}/private'),
            destination:destination,space:ExportSpaceBudget(source:free),prompts:Prompts(()async=>'pw',(_) {
              final choice=coordinator.waitForRecoveryChoice();ready.complete();return choice;
            }));
          pending=running;
          unawaited(running.then((_){if(!ready.isCompleted)ready.complete();}));
          await ready.future.timeout(const Duration(seconds:30));
        });
        expect(coordinator.progress.stage,ExportStage.recoveryChoice,
          reason:coordinator.outcome is OfficialExportFailed?'${(coordinator.outcome as OfficialExportFailed).reason}':'${coordinator.outcome}');
        final boundary=GlobalKey();
        await tester.pumpWidget(MaterialApp(theme:buildTheme(Brightness.light),
          localizationsDelegates:AppLocalizations.localizationsDelegates,supportedLocales:AppLocalizations.supportedLocales,
          home:RepaintBoundary(key:boundary,child:OfficialExportScreen(coordinator:coordinator))));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Yes'),250,scrollable:find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        expect(find.text('Save a second file with data the official version does not yet support?'),findsOneWidget);
        expect(coordinator.official!.file.name,startsWith('openstrap-official-v0.12.2-'));
        final report=await tester.runAsync(()=>coordinator.omissionSummary());
        expect(report!.where((row)=>row['family']=='other').fold<int>(0,(n,row)=>n+(row['count'] as int)),greaterThanOrEqualTo(301));
        await capture(tester,boundary,'recovery-choice-$recovery');
        await tester.scrollUntilVisible(find.text('Saved and verified'),-250,scrollable:find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        final before=tester.getRect(find.text('Saved and verified'));
        final choose=find.ancestor(of:find.text(recovery?'Yes':'No'),matching:find.byType(OutlinedButton));
        tester.widget<OutlinedButton>(choose).onPressed!();
        if(recovery) {
          await tester.runAsync(()=>recoveryStarted!.future.timeout(const Duration(seconds:30)));
          await tester.pumpAndSettle();
          expect(coordinator.progress.artifact,ExportArtifact.recovery);
          expect(coordinator.progress.stage,ExportStage.encrypting);
          await capture(tester,boundary,'recovery-encrypting');
          expect(tester.getRect(find.text('Saved and verified')),before,
            reason:'recovery progress must not move the verified official receipt');
          recoveryRelease!.complete();
        }
        await tester.runAsync(()=>running.timeout(const Duration(seconds:30)));
        await tester.pumpAndSettle();
        final outcome=coordinator.outcome as OfficialExportSaved;
        expect(outcome.recoveryStatus,recovery?RecoveryStatus.saved:RecoveryStatus.declined);
        expect(destination.creates,recovery?2:1);
        await tester.scrollUntilVisible(find.text('Changes and omissions'),250,scrollable:find.byType(Scrollable).first);
        await tester.tap(find.text('Changes and omissions'));await tester.pumpAndSettle();
        expect(find.textContaining('Other records'),findsWidgets);
        expect(find.textContaining('private'),findsNothing);
        expect(tester.takeException(),isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        coordinator.cancel();
        if(recoveryRelease!=null && !recoveryRelease!.isCompleted)recoveryRelease!.complete();
        await tester.runAsync(()async{if(pending!=null)await pending;await coordinator.finish();await root.delete(recursive:true);await fx.dispose();});
        coordinator.dispose();
      }
    });
  }

}


// Captures document the rendered production state; they are inspected manually.
Future<void> capture(WidgetTester tester,GlobalKey key,String name) async {
  final path=Platform.environment['P3_CAPTURE_DIR'];if(path==null)return;
  final boundary=key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(()async {
    final image=await boundary.toImage();
    try {
      final png=await image.toByteData(format:ui.ImageByteFormat.png);
      await Directory(path).create(recursive:true);
      await File('$path/$name.png').writeAsBytes(png!.buffer.asUint8List());
    }finally{image.dispose();}
  });
}
