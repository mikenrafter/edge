// Owns the UI-engine export guard, passphrase, receipts and private files.
// CLAIM(official-export-saved-bytes) [coordinator_test; spec §3.2]: a receipt
// follows authentication of the actual final destination handle.
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../../import/backup_stream.dart';
import '../backup_storage.dart';
import '../attach_copy.dart';
import '../db.dart';
import 'mapper.dart';
import 'mapping_worker.dart';
import 'session.dart';
import 'space_budget.dart';

class OfficialExportCoordinator extends ChangeNotifier {
  static OfficialExportCoordinator? _owner;
  ExportProgress progress = const ExportProgress(ExportStage.ready);
  OfficialExportOutcome? outcome;
  OfficialMapReport? report;
  VerifiedExportFile? official;
  Future<OfficialExportOutcome>? _running;
  ExportCancellation _cancellation = ExportCancellation();
  final Stopwatch _elapsed=Stopwatch();
  Future<OfficialExportOutcome> Function()? _retry;
  Future<void> Function()? _release;
  bool get active => _running!=null;
  bool get canRetryRecovery => _retry!=null;
  void cancel() => _cancellation.cancel();
  void _progress(ExportStage stage,{ExportArtifact artifact=ExportArtifact.official,int done=0,int? total,String? family}) {
    _cancellation.check();
    progress=ExportProgress(stage,artifact:artifact,done:done,total:total,family:family,elapsed:_elapsed.elapsed);
    notifyListeners();
  }
  Future<OfficialExportOutcome> export({
    required OfficialSnapshotSource snapshot, required Directory privateRoot,
    required CipherBackupStorage destination, required ExportSpaceBudget space,
    required Future<String?> Function() askPassphrase,
    required Future<bool> Function(OfficialExportSaved) askRecovery,
  }) {
    final running=_owner?._running;
    if(running!=null)return running;
    _owner=this;
    // Duplicate entry joins the same operation, including its choice prompt.
    return _running ??= _run(snapshot,privateRoot,destination,space,askPassphrase,askRecovery)
      .whenComplete(() {_running=null;notifyListeners();});
  }
  Future<OfficialExportOutcome> _run(OfficialSnapshotSource snapshot,Directory root,
      CipherBackupStorage destination,ExportSpaceBudget space,
      Future<String?> Function() askPassphrase,Future<bool> Function(OfficialExportSaved) askRecovery) async {
    Directory? session;
    BackupFile? incomplete;
    String? passphrase;
    var retainSnapshot=false;
    _cancellation=ExportCancellation();official=null;report=null;outcome=null;
    _elapsed..reset()..start();
    Future<void> release() async {
      passphrase=null;_retry=null;_release=null;
      if(session!=null && await session!.exists()) await session!.delete(recursive:true);
    }
    Future<void> cleanIncomplete() async {
      if(incomplete!=null) {
        try {await destination.closeCiphertext(incomplete!);await destination.deleteCiphertext(incomplete!);incomplete=null;}
        catch(_) { /* minimal journal retains the incomplete handle for cleanup */ }
      }
    }
    Future<void> journal() async {
      final text=(await runMappingWorker(MappingInput('json','',const [],json:{
        'version':1,'folder':destination.label,
        if(destination is AndroidCipherBackupStorage) 'tree':destination.folder.uri,
        if(official!=null) 'official':{'path':official!.file.path,'name':official!.file.name,'sha256':official!.plainSha256,'bytes':official!.bytes},
        if(incomplete!=null) 'incomplete':{'path':incomplete!.path,'name':incomplete!.name},
      }))).text!;
      final pending=File('${root.path}/interruption.pending');
      await pending.writeAsString(text,flush:true);
      await pending.rename('${root.path}/interruption.json');
    }
    try {
      await finish();
      await root.create(recursive:true);
      await cleanupAbandoned(root);
      _progress(ExportStage.preparing);
      final estimate=await snapshot.estimate();
      try {await space.requireAvailable(estimate.peakBytes);} on ExportSpaceExhausted catch(error) {
        return outcome=OfficialExportRefused(error);
      }
      _cancellation.check();
      final id='${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1<<32).toRadixString(16)}';
      session=await Directory('${root.path}/session-$id').create();
      final receipt=await snapshot.capture(session!,space,_cancellation);
      final canonical=await File(receipt.path).resolveSymbolicLinks();
      final canonicalSession=await session!.resolveSymbolicLinks();
      if(!canonical.startsWith('$canonicalSession/')) throw StateError('Snapshot is outside its private session');
      _progress(ExportStage.mapping);
      report=await mapOfficialSnapshot(snapshotPath:receipt.path,outputPath:'${session!.path}/official.db',space:space,
        snapshotReceipt:receipt.toJson(),onProgress:(family,done) {_progress(ExportStage.mapping,family:family,done:done);});
      _cancellation.check();
      passphrase=await askPassphrase();
      if(passphrase==null) throw const ExportCancelled();
      Future<VerifiedExportFile> save(File plain,String name,ExportArtifact artifact) async {
        _cancellation.check();
        final size=await plain.length();
        await space.requireAvailable(size*2+8*1024*1024);
        final expected=(await runMappingWorker(MappingInput('fileHash','',const [],json:plain.path))).text!;
        incomplete=await destination.createCiphertext('$name.incomplete');
        await journal();
        _progress(ExportStage.encrypting,artifact:artifact,total:size);
        final encryptedHash=await encryptBackupStream(plain,passphrase!, (chunk)async {
          _cancellation.check();await space.requireAvailable(chunk.length+65536);
          await destination.appendCiphertext(incomplete!,chunk);
        },checkCancelled:_cancellation.check,onBytes:(n)=>_progress(ExportStage.encrypting,artifact:artifact,done:n,total:size));
        if(encryptedHash!=expected) throw StateError('Plaintext changed while encrypting');
        await destination.closeCiphertext(incomplete!);
        Future<void> verify(BackupFile file) async {
          _progress(ExportStage.verifying,artifact:artifact,total:size+54);
          final hash=await verifyBackupStream(destination.readCiphertext(file),passphrase!,checkCancelled:_cancellation.check,
            onBytes:(n)=>_progress(ExportStage.verifying,artifact:artifact,done:n,total:size+54));
          if(hash!=expected) throw StateError('Saved file differs from verified copy');
        }
        await verify(incomplete!);
        _progress(ExportStage.publishing,artifact:artifact);
        await space.requireAvailable(size+54);
        incomplete=await destination.publishCiphertext(incomplete!,name);
        await journal();
        // Rename may copy bytes or change identity. That is a new trust boundary.
        await verify(incomplete!);
        final saved=VerifiedExportFile(incomplete!,destination.label,expected,size+54);
        incomplete=null;
        await plain.delete();
        return saved;
      }
      official=await save(File(report!.path),'openstrap-official-v0.12.2-$id.db.osbk',ExportArtifact.official);
      await journal();
      _progress(ExportStage.recoveryChoice);
      final chosen=await askRecovery(OfficialExportSaved(official!,report!,RecoveryStatus.awaitingChoice));
      _cancellation.check();
      Future<OfficialExportOutcome> recovery() async {
        try {
          _cancellation=ExportCancellation();
          await space.requireAvailable(estimate.peakBytes);
          final recoveryPath='${session!.path}/recovery.db';
          if(await File(recoveryPath).exists()) await databaseFactory.deleteDatabase(recoveryPath);
          final manifest=(await runMappingWorker(MappingInput('json','',const [],json:{
            'version':1,'snapshot_receipt':receipt.toJson(),'official_sha256':official!.plainSha256,
            'target_tag':'v0.12.2','tables':report!.tables,'days':report!.days,
          }))).text!;
          await LocalDb.exportCopy(attached:AttachedCopy(receipt.path,recoveryPath,(_,_)async=>'',transitionManifest:manifest));
          final saved=await save(File(recoveryPath),'openstrap-fork-recovery-$id.db.osbk',ExportArtifact.recovery);
          await journal();
          return OfficialExportSaved(official!,report!,RecoveryStatus.saved,recovery:saved);
        } catch(error) {
          await cleanIncomplete();await journal();
          final partial=File('${session!.path}/recovery.db');
          if(await partial.exists()) await databaseFactory.deleteDatabase(partial.path);
          return OfficialExportSaved(official!,report!,error is ExportCancelled?RecoveryStatus.cancelled:RecoveryStatus.failed,recoveryError:error);
        }
      }
      OfficialExportOutcome result=OfficialExportSaved(official!,report!,RecoveryStatus.declined);
      if(chosen) {
        result=await recovery();
        if(result is OfficialExportSaved && {RecoveryStatus.failed,RecoveryStatus.cancelled}.contains(result.recoveryStatus)) {
          retainSnapshot=true;_release=release;
          _retry=() async {
            final result=await recovery();outcome=result;
            if(result is OfficialExportSaved && result.recoveryStatus==RecoveryStatus.saved) await release();
            progress=const ExportProgress(ExportStage.complete);notifyListeners();return result;
          };
        }
      }
      _progress(ExportStage.complete);
      return outcome=result;
    } on ExportCancelled {
      progress=const ExportProgress(ExportStage.cancelled);
      return outcome=OfficialExportCancelled(receipt:official);
    } catch(error) {
      final stage=progress.stage;
      progress=ExportProgress(ExportStage.failed,artifact:progress.artifact);
      return outcome=OfficialExportFailed(stage,error,receipt:official);
    } finally {
      await cleanIncomplete();
      if(session!=null)await journal();
      if(!retainSnapshot) await release();
      _elapsed.stop();notifyListeners();
    }
  }
  Future<OfficialExportOutcome?> retryRecovery() async {
    final retry=_retry;
    if(retry==null)return outcome;
    return _running ??= retry().whenComplete((){_running=null;notifyListeners();});
  }
  Future<void> finish() async {await _release?.call();}
  static Future<void> cleanupAbandoned(Directory root) async {
    if(!await root.exists())return;
    await for(final entry in root.list(followLinks:false)) {
      if(entry is Directory && entry.path.split('/').last.startsWith('session-')) await entry.delete(recursive:true);
    }
  }
}
