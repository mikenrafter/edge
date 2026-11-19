// Owns capture through the existing SQL/extras owners, never a live file copy.
// CLAIM(official-export-source-unchanged) [snapshot_test; spec §3.2].
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import '../backup_extras.dart';
import '../backup_storage.dart';
import '../db.dart';
import 'mapping_worker.dart';
import 'session.dart';
import 'space_budget.dart';

class AndroidExportFreeSpace implements ExportFreeSpace {
  @override Future<int> readAvailableBytes() async {
    final bytes=await AndroidBackupStorage.channel.invokeMethod<int>('freeSpace');
    if(bytes==null)throw const FileSystemException('Cannot check available storage');
    return bytes;
  }
}
class LocalDbExportSnapshot implements OfficialSnapshotSource {
  @override Future<ExportEstimate> estimate() async {
    final db=await LocalDb.instance;
    final pages=Sqflite.firstIntValue(await db.rawQuery('PRAGMA page_count'))!;
    final pageSize=Sqflite.firstIntValue(await db.rawQuery('PRAGMA page_size'))!;
    final archive=Sqflite.firstIntValue(await db.rawQuery('SELECT sum(raw_bytes) FROM substrate_archive'))??0;
    // Saved-file byte estimate is captured by the extras owner, before any copy.
    int extras;
    try {extras=await estimateBackupFiles();} catch(_) {extras=0;}
    return ExportEstimate(pages*pageSize,archive,extras);
  }
  @override Future<SnapshotReceipt> capture(Directory session,ExportSpaceBudget space,ExportCancellation cancellation) async {
    final start=DateTime.now().millisecondsSinceEpoch;
    final estimate=await this.estimate();
    final audit=BackupExtrasAudit(beforeWrite:(n)async {cancellation.check();await space.requireAvailable(n);},checkCancelled:cancellation.check);
    final path=await LocalDb.exportCopy(into:session,extras:BackupExtras.none,
      beforeCopyWrite:()async {cancellation.check();await space.requireAvailable(estimate.sqlBytes*3+estimate.extrasBytes);});
    cancellation.check();
    await writeBackupExtras(path,audit:audit);
    final copy=await databaseFactory.openDatabase(path,options:OpenDatabaseOptions(singleInstance:false));
    int schema;
    try {
      schema=await copy.getVersion();
      if((await copy.rawQuery('PRAGMA integrity_check')).single.values.single!='ok')throw StateError('Snapshot integrity check failed');
    }finally{await copy.close();}
    final hash=(await runMappingWorker(MappingInput('fileHash','',const [],json:path))).text!;
    return SnapshotReceipt(path,hash,schema,start,DateTime.now().millisecondsSinceEpoch,omissions:audit.omissions);
  }
}
