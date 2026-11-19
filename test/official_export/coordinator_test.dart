// WHY: CLAIM(official-export-live-space-floor) and
// CLAIM(official-export-saved-bytes): drive real mapping, crypto and publication.
// catches: no preflight; trust staged bytes; recovery failure deletes official;
// forget finally cleanup; delete official on cancellation.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/coordinator.dart';
import 'package:openstrap_edge/data/official_export/session.dart';
import 'package:openstrap_edge/data/official_export/space_budget.dart';
import 'rich_fixture.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'session_fixture.dart';

class StaleReceiptSnapshot extends Snapshot {
 StaleReceiptSnapshot(super.path);
 @override Future<SnapshotReceipt> capture(Directory dir,ExportSpaceBudget space,ExportCancellation cancellation)async{
  final receipt=await super.capture(dir,space,cancellation);
  return SnapshotReceipt(receipt.path,'wrong hash',receipt.schema,1,2);
 }
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('literal full peak includes publication overlap and zero verification file',(){
    expect(const ExportEstimate(100,300,20).peakBytes,8391650);
  });
  test('preflight refuses before capture and leaves live writes possible',() async {
    final fx=await RichFixture.build();
    final root=await Directory.systemTemp.createTemp('coord_');
    try {
      final free=Space()..available=64*1024*1024;
      final source=Snapshot(fx.forkPath), dest=Destination(root,free);
      final result=await OfficialExportCoordinator().export(snapshot:source,privateRoot:Directory('${root.path}/private'),destination:dest,
        space:ExportSpaceBudget(source:free),prompts:Prompts(()async=>'pw',(_)async=>false));
      expect(result,isA<OfficialExportRefused>()); expect(source.captures,0);expect(dest.creates,0);
      final live=await databaseFactoryFfi.openDatabase(fx.forkPath);
      try {
        await live.insert('journal',{'date':'2026-12-31','tags_json':'[]','note':'live write after refusal','updated_at':1});
        expect((await live.query('journal',where:"date='2026-12-31'")).single['note'],'live write after refusal');
      } finally {await live.close();}
    } finally {await root.delete(recursive:true);await fx.dispose();}
  });
  for(final mode in ['saved','recoveryFailure','corrupt','rename','floor','cancel']) {
    test('$mode keeps receipts and cleans plaintext in order',() async {
      final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('coord_');
      try {
        final free=Space();final dest=Destination(root,free)
          ..corrupt=mode=='corrupt'..corruptRename=mode=='rename'..failRecovery=mode=='recoveryFailure'..exhaust=mode=='floor';
        final coord=OfficialExportCoordinator();var prompts=0;
        final source=Snapshot(fx.forkPath);
        final result=await coord.export(snapshot:source,privateRoot:Directory('${root.path}/private'),destination:dest,
          space:ExportSpaceBudget(source:free),prompts:Prompts(()async {prompts++;return 'pw';},(saved)async {
            expect(saved.official.file.name,startsWith('openstrap-official-v0.12.2-'));
            expect(Directory('${root.path}/private').listSync(recursive:true).whereType<File>().where((f)=>f.path.endsWith('official.db')),isEmpty);
            if(mode=='cancel')coord.cancel();return mode=='recoveryFailure';
          }));
        expect(prompts,1);expect(source.captures,1);
        expect(free.available,greaterThanOrEqualTo(64*1024*1024));
        if({'corrupt','rename','floor'}.contains(mode)) {
          expect(result,isA<OfficialExportFailed>());expect(result.official,isNull);
          expect(root.listSync().whereType<File>(),isEmpty);
        } else {
          expect(result,mode=='cancel'?isA<OfficialExportCancelled>():isA<OfficialExportSaved>());
          expect(result.official,isNotNull);
          expect(File(result.official!.file.path).existsSync(),isTrue);
          if(mode=='recoveryFailure') {
            expect((result as OfficialExportSaved).recoveryStatus,RecoveryStatus.failed);
            expect(result.recoveryError,isA<FileSystemException>());
          }
          expect(root.listSync().whereType<File>().length,1);
        }
        if(mode=='recoveryFailure') {
          expect(coord.canRetryRecovery,isTrue);
          expect(Directory('${root.path}/private').listSync(recursive:true).whereType<File>().where((f)=>f.path.endsWith('fork.db')).length,1);
          await coord.finish();
        }
        expect(Directory('${root.path}/private').listSync(recursive:true).whereType<File>().where((f)=>!f.path.endsWith('interruption.json')),isEmpty);
        if(mode=='floor') {
          final live=await databaseFactoryFfi.openDatabase(fx.forkPath);
          try {
            await live.insert('journal',{'date':'2026-12-31','tags_json':'[]','note':'live write after floor stop','updated_at':1});
            expect((await live.query('journal',where:"date='2026-12-31'")).single['note'],'live write after floor stop');
          }finally{await live.close();}
        }
        // The source fixture stays readable after every failure.
        expect((await fx.inventoryOf(fx.forkPath)).rowCounts['journal'],greaterThan(0));
      } finally {await root.delete(recursive:true);await fx.dispose();}
    },timeout:const Timeout(Duration(minutes:4)));
  }
  test('a changed capture receipt is refused before publishing any bytes',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('stale_receipt_');
    try{
      final free=Space();final destination=Destination(root,free);
      final result=await OfficialExportCoordinator().export(snapshot:StaleReceiptSnapshot(fx.forkPath),
        privateRoot:Directory('${root.path}/private'),destination:destination,space:ExportSpaceBudget(source:free),
        prompts:Prompts(()async=>'pw',(_)async=>false));
      expect(result,isA<OfficialExportFailed>());expect(destination.creates,0);
      expect((result as OfficialExportFailed).reason.toString(),contains('Snapshot differs from capture receipt'));
    }finally{await root.delete(recursive:true);await fx.dispose();}
  });
  test('completed receipt is unverified after restart, then authenticates saved bytes',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('restart_receipt_');
    try{
      final free=Space();final destination=Destination(root,free);final private=Directory('${root.path}/private');
      final saved=await OfficialExportCoordinator().export(snapshot:Snapshot(fx.forkPath),privateRoot:private,
        destination:destination,space:ExportSpaceBudget(source:free),prompts:Prompts(()async=>'pw',(_)async=>false));
      final restarted=OfficialExportCoordinator();await restarted.loadInterruption(private);
      expect(restarted.official,isNull);expect(restarted.wasInterrupted,isFalse);
      expect(restarted.interruptedName,saved.official!.file.name);
      await restarted.verifyInterrupted(Prompts(()async=>'pw',(_)async=>false));
      expect(restarted.official!.plainSha256,saved.official!.plainSha256);
      expect(restarted.hasInterruption,isFalse);
    }finally{await root.delete(recursive:true);await fx.dispose();}
  });
  test('cold start deletes abandoned plaintext without following symlinks',()async {
    final root=await Directory.systemTemp.createTemp('cold_');
    final outside=await Directory.systemTemp.createTemp('outside_');
    try {
      Directory('${root.path}/session-old').createSync();File('${root.path}/session-old/fork.db').writeAsStringSync('health');
      File('${outside.path}/keep').writeAsStringSync('keep');Link('${root.path}/session-link').createSync(outside.path);
      await OfficialExportCoordinator.cleanupAbandoned(root);
      expect(Directory('${root.path}/session-old').existsSync(),isFalse);
      expect(File('${outside.path}/keep').readAsStringSync(),'keep');
    }finally{await root.delete(recursive:true);await outside.delete(recursive:true);}
  });
}
