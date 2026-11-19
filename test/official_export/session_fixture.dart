// WHY: CLAIM(official-export-live-space-floor) and
// CLAIM(official-export-saved-bytes): drive real mapping, crypto and publication.
// catches: no preflight; trust staged bytes; recovery failure deletes official;
// forget finally cleanup; delete official on cancellation.
import 'dart:async';
import 'dart:io';
import 'package:openstrap_edge/data/backup_storage.dart';
import 'package:openstrap_edge/data/official_export/coordinator.dart';
import 'package:openstrap_edge/data/official_export/session.dart';
import 'package:openstrap_edge/data/official_export/space_budget.dart';
import 'package:openstrap_edge/data/official_export/mapping_worker.dart';


class Prompts implements ExportPrompts {
  Prompts(this.pass,this.recovery);
  final Future<String?> Function() pass;
  final Future<bool> Function(OfficialExportSaved) recovery;
  @override Future<String?> askPassphrase()=>pass();
  @override Future<bool> askRecovery(OfficialExportSaved saved)=>recovery(saved);
}
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
  bool corrupt=false, corruptRename=false, failRecovery=false, exhaust=false, denyDelete=false;
  int creates=0;
  Completer<void>? recoveryStarted,recoveryRelease;
  @override String get label=>'Selected folder';
  @override Future<List<BackupFile>> listCiphertext() async=>[for(final file in root.listSync().whereType<File>())BackupFile(path:file.path,name:file.path.split('/').last)];
  @override Future<BackupFile> createCiphertext(String name) async {
    if(creates==1 && recoveryRelease!=null){recoveryStarted!.complete();await recoveryRelease!.future;}
    if(failRecovery && creates==1) throw const FileSystemException('revoked');
    creates++; final file=File('${root.path}/$name'); await file.create(exclusive:true);
    return BackupFile(path:file.path,name:name);
  }
  @override Future<void> appendCiphertext(BackupFile file,List<int> bytes) async {
    if(exhaust) space.available=64*1024*1024+bytes.length+65536;
    space.available-=bytes.length;
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
  @override Future<void> deleteCiphertext(BackupFile file) async {if(denyDelete)throw const FileSystemException('grant revoked');await File(file.path).delete();}
}
