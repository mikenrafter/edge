// WHY: CLAIM(official-export-live-space-floor) and
// CLAIM(official-export-saved-bytes): drive real mapping, crypto and publication.
// catches: no preflight; trust staged bytes; recovery failure deletes official;
// forget finally cleanup; delete official on cancellation.
import 'dart:io';
import 'dart:convert';
import 'package:openstrap_edge/data/backup_storage.dart';
import 'package:flutter/services.dart';
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
class IntentDestination extends Destination {
  IntentDestination(super.root,super.space,this.journal);
  final File journal;
  @override Future<BackupFile> createCiphertext(String name)async {
    final record=jsonDecode(await journal.readAsString()) as Map;
    expect(record['pending_name'],name,reason:'creation intent must survive before a provider returns its handle');
    return super.createCiphertext(name);
  }
}

// A tree whose persisted grant is gone: every call fails like the native bridge.
class RevokedTree implements CipherBackupStorage {
  @override String get label=>'Old folder';
  Never _deny()=>throw PlatformException(code:'SecurityException',message:'grant revoked');
  @override Future<List<BackupFile>> listCiphertext()async=>_deny();
  @override Future<void> deleteCiphertext(BackupFile file)async=>_deny();
  @override Future<BackupFile> createCiphertext(String name)async=>_deny();
  @override Future<void> appendCiphertext(BackupFile file,List<int> bytes)async=>_deny();
  @override Future<void> closeCiphertext(BackupFile file)async=>_deny();
  @override Stream<List<int>> readCiphertext(BackupFile file)=>Stream.error(PlatformException(code:'SecurityException'));
  @override Future<BackupFile> publishCiphertext(BackupFile file,String name)async=>_deny();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // WHY: review F2. Extras omissions come from the snapshot, so neither saved
  // file holds them; each reason keeps its own group instead of "unsupported".
  test('extras omissions keep their true reason and family',()async {
    final coordinator=OfficialExportCoordinator()..extrasOmissions=[
      {'family':'saved files','identity':'device_lab/imu/saved.jsonl','reason':'omitted to preserve space for new recordings'},
      {'family':'saved files','identity':'a.part','reason':'recording is unfinished'},
      {'family':'saved files','identity':'b.jsonl','reason':'capture failed: FileSystemException'},
      {'family':'settings','identity':'portable preferences','reason':'preference store unavailable'},
      {'family':'settings','identity':'some_key','reason':'unsupported preference type'},
    ];
    try {
      expect(await coordinator.omissionSummary(),unorderedEquals([
        {'family':'recordings','reason':'space','count':1},
        {'family':'recordings','reason':'unfinished','count':1},
        {'family':'recordings','reason':'unreadable','count':1},
        {'family':'settings','reason':'unreadable','count':1},
        {'family':'settings','reason':'value','count':1},
      ]));
    }finally{coordinator.dispose();}
  });
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
  // WHY: stopping only the optional file must keep an actionable saved result
  // and retry the same capture, without asking for another passphrase.
  test('cancelled recovery keeps the official receipt and retries the frozen capture',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('recovery_cancel_');
    final coordinator=OfficialExportCoordinator();
    try {
      final free=Space();final dest=Destination(root,free);final source=Snapshot(fx.forkPath);
      var stopped=false,passes=0;
      coordinator.addListener(() {
        if(!stopped && coordinator.progress.artifact==ExportArtifact.recovery && coordinator.progress.stage==ExportStage.encrypting && coordinator.progress.done>0) {
          stopped=true;coordinator.cancel();
        }
      });
      final result=await coordinator.export(snapshot:source,privateRoot:Directory('${root.path}/private'),destination:dest,
        space:ExportSpaceBudget(source:free),prompts:Prompts(()async{passes++;return 'pw';},(_)async=>true));
      expect(stopped,isTrue);
      expect(result,isA<OfficialExportSaved>());
      expect((result as OfficialExportSaved).recoveryStatus,RecoveryStatus.cancelled);
      expect(File(result.official.file.path).existsSync(),isTrue);
      expect(root.listSync().whereType<File>().length,1);
      expect(coordinator.canRetryRecovery,isTrue);
      final retried=await coordinator.retryRecovery() as OfficialExportSaved;
      expect(retried.recoveryStatus,RecoveryStatus.saved);
      expect(retried.official.file.path,result.official.file.path);
      expect(source.captures,1);expect(passes,1);
    }finally{await coordinator.finish();coordinator.dispose();await root.delete(recursive:true);await fx.dispose();}
  });

  // WHY: a picker retry in the same process must consume the persisted cleanup
  // journal too, after a lost provider grant becomes available again.
  test('same coordinator retry cleans an incomplete file after grant recovery',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('grant_retry_');
    final coordinator=OfficialExportCoordinator();
    try {
      final free=Space();final dest=Destination(root,free)..corrupt=true..denyDelete=true;
      final source=Snapshot(fx.forkPath);final private=Directory('${root.path}/private');
      final prompts=Prompts(()async=>'pw',(_)async=>false);
      final first=await coordinator.export(snapshot:source,privateRoot:private,destination:dest,space:ExportSpaceBudget(source:free),prompts:prompts);
      expect(first,isA<OfficialExportFailed>());
      expect(root.listSync().whereType<File>().single.path,endsWith('.incomplete'));
      dest..corrupt=false..denyDelete=false;
      final second=await coordinator.export(snapshot:source,privateRoot:private,destination:dest,space:ExportSpaceBudget(source:free),prompts:prompts);
      expect(second,isA<OfficialExportSaved>());
      expect(root.listSync().whereType<File>().length,1);
      expect(root.listSync().whereType<File>().single.path,second.official!.file.path);
    }finally{await coordinator.finish();coordinator.dispose();await root.delete(recursive:true);await fx.dispose();}
  });

  // WHY: process death after provider creation but before handle persistence
  // must leave a name that cold cleanup can find, without touching saved files.
  test('provider creation intent is journaled before either artifact is created',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('create_intent_');
    final coordinator=OfficialExportCoordinator();
    try {
      final free=Space();final private=Directory('${root.path}/private');
      final dest=IntentDestination(root,free,File('${private.path}/interruption.json'));
      final result=await coordinator.export(snapshot:Snapshot(fx.forkPath),privateRoot:private,destination:dest,
        space:ExportSpaceBudget(source:free),prompts:Prompts(()async=>'pw',(_)async=>true));
      expect(result,isA<OfficialExportSaved>());
      expect((result as OfficialExportSaved).recoveryStatus,RecoveryStatus.saved);
      expect(dest.creates,2);
    }finally{await coordinator.finish();coordinator.dispose();await root.delete(recursive:true);await fx.dispose();}
  });
  test('cold cleanup resolves a creation intent without a returned handle',()async {
    final root=await Directory.systemTemp.createTemp('cold_intent_');
    final coordinator=OfficialExportCoordinator();
    try {
      final private=await Directory('${root.path}/private').create();
      final orphan=File('${root.path}/openstrap-official-crash.db.osbk.incomplete');await orphan.writeAsString('unfinished');
      final saved=File('${root.path}/saved.db.osbk');await saved.writeAsString('keep');
      await File('${private.path}/interruption.json').writeAsString(jsonEncode({
        'version':1,'folder':root.path,'local_root':root.path,'pending_name':orphan.uri.pathSegments.last,
        'official':{'name':'saved.db.osbk'},
      }));
      await coordinator.loadInterruption(private);await coordinator.cleanInterrupted();
      expect(await orphan.exists(),isFalse);
      expect(await saved.readAsString(),'keep');
    }finally{await coordinator.finish();coordinator.dispose();await root.delete(recursive:true);}
  });

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

  // WHY: review F1. Cleanup of an earlier export is best effort: a journal that
  // cannot be acted on must never stop a new export from producing a file.
  Future<OfficialExportOutcome> exportTo(OfficialExportCoordinator c,RichFixture fx,Directory root,Directory private,Destination dest,Space free)=>
    c.export(snapshot:Snapshot(fx.forkPath),privateRoot:private,destination:dest,space:ExportSpaceBudget(source:free),prompts:Prompts(()async=>'pw',(_)async=>false));
  Future<void> journalWith(Directory private,Map<String,Object?> record)async {
    await private.create(recursive:true);
    await File('${private.path}/interruption.json').writeAsString(jsonEncode(record));
  }
  const staleRecord={'version':1,'folder':'Old folder','tree':'content://old/tree','pending_name':'openstrap-official-x.db.osbk.incomplete','official':{'name':'previous.db.osbk'}};
  test('a revoked old folder does not block a new export and names the leftover',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('f1_revoked_');
    final coordinator=OfficialExportCoordinator()..storageForTree=((_)=>RevokedTree());
    try {
      final free=Space();final private=Directory('${root.path}/private');final dest=Destination(Directory('${root.path}/new')..createSync(),free);
      await journalWith(private,staleRecord);
      final first=await exportTo(coordinator,fx,root,private,dest,free);
      expect(first,isA<OfficialExportSaved>(),reason:first is OfficialExportFailed?'${first.reason}':'$first');
      expect(coordinator.notices.map((n)=>(n.kind,n.file,n.folder)),[(ExportNoticeKind.leftover,'openstrap-official-x.db.osbk.incomplete','Old folder')]);
      final leftovers=File('${private.path}/leftovers.json').readAsStringSync();
      expect(leftovers,contains('content://old/tree'));expect(leftovers,isNot(contains('pw')));
      final second=await exportTo(coordinator,fx,root,private,dest,free);
      expect(second,isA<OfficialExportSaved>());
      expect(coordinator.notices.single.kind,ExportNoticeKind.leftover,reason:'still unverified, still named');
    }finally{await coordinator.finish();coordinator.dispose();await root.delete(recursive:true);await fx.dispose();}
  },timeout:const Timeout(Duration(minutes:4)));
  test('an unreadable journal is set aside and does not block a new export',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('f1_corrupt_');
    final coordinator=OfficialExportCoordinator();
    try {
      final free=Space();final private=Directory('${root.path}/private');final dest=Destination(Directory('${root.path}/new')..createSync(),free);
      await journalWith(private,{'version':7,'folder':'x'});
      final first=await exportTo(coordinator,fx,root,private,dest,free);
      expect(first,isA<OfficialExportSaved>(),reason:first is OfficialExportFailed?'${first.reason}':'$first');
      expect(coordinator.notices.map((n)=>n.kind),[ExportNoticeKind.journalUnreadable]);
      expect(File('${private.path}/interruption.unreadable').existsSync(),isTrue);
      await File('${private.path}/interruption.json').writeAsString('not json');
      final second=await exportTo(coordinator,fx,root,private,dest,free);
      expect(second,isA<OfficialExportSaved>());
    }finally{await coordinator.finish();coordinator.dispose();await root.delete(recursive:true);await fx.dispose();}
  },timeout:const Timeout(Duration(minutes:4)));
  test('a leftover is deleted quietly once the old folder is reachable again',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('f1_regrant_');
    final coordinator=OfficialExportCoordinator()..storageForTree=((_)=>RevokedTree());
    try {
      final old=Directory('${root.path}/old')..createSync();
      final leftover=File('${old.path}/openstrap-official-x.db.osbk.incomplete')..writeAsStringSync('half');
      final other=File('${old.path}/keep.txt')..writeAsStringSync('mine');
      final free=Space();final private=Directory('${root.path}/private');final dest=Destination(Directory('${root.path}/new')..createSync(),free);
      await journalWith(private,staleRecord);
      final first=await exportTo(coordinator,fx,root,private,dest,free);
      expect(first,isA<OfficialExportSaved>());
      expect(leftover.existsSync(),isTrue,reason:'nothing is deleted without access');
      coordinator.storageForTree=((_)=>LocalCipherBackupStorage(old));
      final second=await exportTo(coordinator,fx,root,private,dest,free);
      expect(second,isA<OfficialExportSaved>());
      expect(leftover.existsSync(),isFalse);expect(other.existsSync(),isTrue);
      expect(coordinator.notices,isEmpty);
      expect(File(second.official!.file.path).existsSync(),isTrue);
      expect(File('${private.path}/leftovers.json').existsSync()?File('${private.path}/leftovers.json').readAsStringSync():'',isNot(contains('x.db.osbk')));
    }finally{await coordinator.finish();coordinator.dispose();await root.delete(recursive:true);await fx.dispose();}
  },timeout:const Timeout(Duration(minutes:4)));
}
