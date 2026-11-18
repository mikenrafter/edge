// WHY: CLAIM(official-export-live-space-floor) and
// CLAIM(official-export-saved-bytes): drive real mapping, crypto and publication.
// catches: no preflight; trust staged bytes; recovery failure deletes official;
// forget finally cleanup; delete official on cancellation.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/backup_storage.dart';
import 'package:openstrap_edge/data/official_export/coordinator.dart';
import 'package:openstrap_edge/data/official_export/session.dart';
import 'package:openstrap_edge/data/official_export/space_budget.dart';
import 'package:openstrap_edge/data/official_export/mapping_worker.dart';
import 'rich_fixture.dart';

class Space implements ExportFreeSpace {
  int available=1<<40;
  @override Future<int> readAvailableBytes() async=>available;
}
class Snapshot implements OfficialSnapshotSource {
  Snapshot(this.path);
  final String path; int captures=0;
  @override Future<ExportEstimate> estimate() async=>ExportEstimate(await File(path).length(),100000,0);
  @override Future<SnapshotReceipt> capture(Directory dir,ExportSpaceBudget space,ExportCancellation cancellation) async {
    captures++;
    final copy=await File(path).copy('${dir.path}/fork.db');
    final hash=(await runMappingWorker(MappingInput('fileHash','',const [],json:copy.path))).text!;
    return SnapshotReceipt(copy.path,hash,92,1,2);
  }
}
class Destination implements CipherBackupStorage {
  Destination(this.root,this.space);
  final Directory root; final Space space;
  bool corrupt=false, corruptRename=false, failRecovery=false, exhaust=false;
  int creates=0;
  @override String get label=>'Selected folder';
  @override Future<BackupFile> createCiphertext(String name) async {
    if(failRecovery && creates==1) throw const FileSystemException('revoked');
    creates++; final file=File('${root.path}/$name'); await file.create(exclusive:true);
    return BackupFile(path:file.path,name:name);
  }
  @override Future<void> appendCiphertext(BackupFile file,List<int> bytes) async {
    if(exhaust) space.available=64*1024*1024;
    await File(file.path).writeAsBytes(bytes,mode:FileMode.append);
  }
  @override Future<void> closeCiphertext(BackupFile file) async {}
  @override Stream<List<int>> readCiphertext(BackupFile file) async* {
    if(corrupt) { yield [1,2,3]; } else { yield* File(file.path).openRead(); }
  }
  @override Future<BackupFile> publishCiphertext(BackupFile file,String name) async {
    final moved=await File(file.path).rename('${root.path}/$name');
    if(corruptRename) await moved.writeAsBytes([1]);
    return BackupFile(path:moved.path,name:name);
  }
  @override Future<void> deleteCiphertext(BackupFile file) async=>File(file.path).delete();
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
        space:ExportSpaceBudget(source:free),askPassphrase:()async=>'pw',askRecovery:(_)async=>false);
      expect(result,isA<OfficialExportRefused>()); expect(source.captures,0);expect(dest.creates,0);
      await File('${root.path}/live-wal').writeAsBytes([1,2]);
      expect(File('${root.path}/live-wal').lengthSync(),2);
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
          space:ExportSpaceBudget(source:free),askPassphrase:()async {prompts++;return 'pw';},askRecovery:(saved)async {
            expect(saved.official.file.name,startsWith('openstrap-official-v0.12.2-'));
            expect(Directory('${root.path}/private').listSync(recursive:true).whereType<File>().where((f)=>f.path.endsWith('official.db')),isEmpty);
            if(mode=='cancel')coord.cancel();return mode=='recoveryFailure';
          });
        expect(prompts,1);expect(source.captures,1);
        if({'corrupt','rename','floor'}.contains(mode)) {
          expect(result,isA<OfficialExportFailed>());expect(result.official,isNull);
          expect(root.listSync().whereType<File>(),isEmpty);
        } else {
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
        // The source fixture stays readable after every failure.
        expect((await fx.inventoryOf(fx.forkPath)).rowCounts['journal'],greaterThan(0));
      } finally {await root.delete(recursive:true);await fx.dispose();}
    },timeout:const Timeout(Duration(minutes:4)));
  }
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
