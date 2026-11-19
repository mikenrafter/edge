// Owns UI-engine sessions, cancellation, passphrase lifetime and saved receipts.
// CLAIM(official-export-saved-bytes) [coordinator_test; spec §3.2]: receipts
// follow authentication of the actual final destination handle.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../../import/backup_stream.dart';
import '../backup_storage.dart';
import '../attach_copy.dart';
import '../db.dart';
import '../json_payload_lane.dart';
import 'mapper.dart';
import 'mapping_worker.dart';
import 'session.dart';
import 'space_budget.dart';

abstract interface class ExportPrompts {
  Future<String?> askPassphrase();
  Future<bool> askRecovery(OfficialExportSaved saved);
}

class OfficialExportCoordinator extends ChangeNotifier {
  static OfficialExportCoordinator? _owner;
  ExportProgress progress=const ExportProgress(ExportStage.ready);
  OfficialExportOutcome? outcome;
  OfficialMapReport? report;
  VerifiedExportFile? official;
  List<Map<String,Object?>> extrasOmissions=const [];
  Future<OfficialExportOutcome>? _running;
  ExportCancellation _cancellation=ExportCancellation();
  final Stopwatch _elapsed=Stopwatch();
  Directory? _session;
  late Directory _root;
  late CipherBackupStorage _destination;
  late ExportSpaceBudget _space;
  late ExportEstimate _estimate;
  late SnapshotReceipt _snapshot;
  late String _id;
  BackupFile? _incomplete;
  String? _publicationName;
  String? _passphrase;
  bool _retryAvailable=false;
  bool _hasOmissions=false;
  List<Map<String,Object?>>? _omissionGroups;
  Map<String,Object?>? _interruption;
  String? get interruptedName=>(_interruption?['official'] as Map?)?['name'] as String?;
  bool get hasInterruption=>_interruption!=null;
  bool get wasInterrupted=>_interruption!=null && _interruption!['finished']!=true;
  Future<void> loadInterruption(Directory root) async {
    if(active || official!=null)return;
    _root=root;
    await cleanupAbandoned(root);
    await _readInterruption();
    if(_interruption!=null){progress=const ExportProgress(ExportStage.interrupted);notifyListeners();}
  }
  Future<void> _readInterruption() async {
    final journal=File('${_root.path}/interruption.json');
    if(!await journal.exists())return;
    final decoded=await JsonPayloadLane.shared.decodeUncached(await journal.readAsString());
    if(decoded is! Map || decoded['version']!=1)throw const FormatException('Unreadable export receipt');
    _interruption=decoded.cast<String,Object?>();
  }
  Future<void> verifyInterrupted(ExportPrompts prompts) async {
    final record=_interruption;
    if(record==null)return;
    final candidate=record['official'];
    if(candidate is! Map || candidate['path'] is! String || candidate['name'] is! String || candidate['sha256'] is! String || candidate['bytes'] is! int) {
      throw const FormatException('No saved file to verify');
    }
    final file=BackupFile(path:candidate['path'] as String,name:candidate['name'] as String);
    final tree=record['tree'];
    _destination=tree is String?AndroidCipherBackupStorage(BackupFolder(uri:tree,name:record['folder'] as String))
      :LocalCipherBackupStorage(File(file.path).parent);
    final passphrase=await prompts.askPassphrase();
    if(passphrase==null)return;
    final hash=await verifyBackupStream(_destination.readCiphertext(file),passphrase);
    if(hash!=candidate['sha256'])throw const FormatException('Saved file differs');
    official=VerifiedExportFile(file,_destination.label,hash,candidate['bytes'] as int);
    progress=const ExportProgress(ExportStage.complete);_interruption=null;notifyListeners();
  }
  Future<void> cleanInterrupted() async {
    final record=_interruption;
    if(record==null)return;
    final file=record['incomplete'];
    final pendingName=record['pending_name'];
    if(file is Map && file['path'] is String && file['name'] is String) {
      final tree=record['tree'];
      final storage=tree is String?AndroidCipherBackupStorage(BackupFolder(uri:tree,name:record['folder'] as String))
        :LocalCipherBackupStorage(File(file['path'] as String).parent);
      // Listing also makes cleanup idempotent if the prior deletion succeeded
      // before the process died or before its receipt could be replaced.
      for(final candidate in await storage.listCiphertext()) {
        if((candidate.path==file['path'] || candidate.name==file['name'] || candidate.name==pendingName) &&
            candidate.name!=(record['official'] as Map?)?['name']) {
          await storage.deleteCiphertext(candidate);
        }
      }
    }
    final journal=File('${_root.path}/interruption.json');
    if(await journal.exists())await journal.delete();
    _interruption=null;
  }
  bool get active=>_running!=null;
  bool get canRetryRecovery=>_retryAvailable;
  Completer<bool>? _recoveryChoice;
  bool get awaitingRecoveryChoice=>_recoveryChoice!=null && !_recoveryChoice!.isCompleted;
  Future<bool> waitForRecoveryChoice() => (_recoveryChoice??=Completer<bool>()).future;
  void chooseRecovery(bool yes) {if(awaitingRecoveryChoice)_recoveryChoice!.complete(yes);}
  void cancel(){_cancellation.cancel();chooseRecovery(false);}
  void _progress(ExportStage stage,{ExportArtifact artifact=ExportArtifact.official,int done=0,int? total,String? family}) {
    _cancellation.check();
    progress=ExportProgress(stage,artifact:artifact,done:done,total:total,family:family,elapsed:_elapsed.elapsed);
    notifyListeners();
  }
  Future<OfficialExportOutcome> export({required OfficialSnapshotSource snapshot,
      required Directory privateRoot,required CipherBackupStorage destination,
      required ExportSpaceBudget space,required ExportPrompts prompts}) {
    final running=_owner?._running;
    if(running!=null)return running;
    _owner=this;
    return _running??=_run(snapshot,privateRoot,destination,space,prompts)
      .whenComplete((){_running=null;notifyListeners();});
  }
  Future<void> _journal() async {
    final text=(await runMappingWorker(MappingInput('json','',const [],json:{
      'version':1,'folder':_destination.label,'finished':progress.stage==ExportStage.complete,
      if(_publicationName!=null)'pending_name':_publicationName,
      if(_destination is AndroidCipherBackupStorage)'tree':(_destination as AndroidCipherBackupStorage).folder.uri,
      if(official!=null)'official':{'path':official!.file.path,'name':official!.file.name,'sha256':official!.plainSha256,'bytes':official!.bytes},
      if(_incomplete!=null)'incomplete':{'path':_incomplete!.path,'name':_incomplete!.name},
    }))).text!;
    await _space.requireAvailable(8192);
    final pending=File('${_root.path}/interruption.pending');
    await pending.writeAsString(text,flush:true);
    await pending.rename('${_root.path}/interruption.json');
  }
  Future<void> _cleanIncomplete() async {
    final file=_incomplete;
    if(file==null && _publicationName==null)return;
    try {
      if(file!=null) {
      await _destination.closeCiphertext(file);
      await _destination.deleteCiphertext(file);_incomplete=null;
      }
    } catch(_) { /* The provider may have changed identity during publication. */ }
    final name=_publicationName;
    if(name!=null) {
      try {
        for(final pending in await _destination.listCiphertext()) {
          if(pending.name==name && official?.file.name!=name)await _destination.deleteCiphertext(pending);
        }
        _publicationName=null;_incomplete=null;
      }catch(_) { /* Journal retains pending_name when provider access was lost. */ }
    }
  }
  Future<VerifiedExportFile> _save(File plain,String name,ExportArtifact artifact) async {
    _cancellation.check();
    final size=await plain.length();
    await _space.requireAvailable(size*2+8*1024*1024);
    final expected=(await runMappingWorker(MappingInput('fileHash','',const [],json:plain.path))).text!;
    _progress(ExportStage.encrypting,artifact:artifact,total:size);
    _incomplete=await _destination.createCiphertext('$name.incomplete');
    await _journal();
    final encryptedHash=await encryptBackupStream(plain,_passphrase!, (chunk)async {
      _cancellation.check();await _space.requireAvailable(chunk.length+65536);
      await _destination.appendCiphertext(_incomplete!,chunk);
    },checkCancelled:_cancellation.check,onBytes:(n)=>_progress(ExportStage.encrypting,artifact:artifact,done:n,total:size));
    if(encryptedHash!=expected)throw StateError('Plaintext changed while encrypting');
    await _destination.closeCiphertext(_incomplete!);
    await _verify(_incomplete!,expected,size,artifact);
    _progress(ExportStage.publishing,artifact:artifact);
    await _space.requireAvailable(size+54);
    _publicationName=name;await _journal();
    _incomplete=await _destination.publishCiphertext(_incomplete!,name);
    await _journal();
    // Provider rename may copy bytes or change identity, a new trust boundary.
    await _verify(_incomplete!,expected,size,artifact);
    final saved=VerifiedExportFile(_incomplete!,_destination.label,expected,size+54);
    _incomplete=null;_publicationName=null;
    if(artifact==ExportArtifact.official)official=saved;
    await _journal();
    await plain.delete();
    return saved;
  }
  Future<void> _verify(BackupFile file,String expected,int size,ExportArtifact artifact) async {
    _progress(ExportStage.verifying,artifact:artifact,total:size+54);
    final hash=await verifyBackupStream(_destination.readCiphertext(file),_passphrase!,checkCancelled:_cancellation.check,
      onBytes:(n)=>_progress(ExportStage.verifying,artifact:artifact,done:n,total:size+54));
    if(hash!=expected)throw StateError('Saved file differs from verified copy');
  }
  Future<OfficialExportOutcome> _run(OfficialSnapshotSource source,Directory root,
      CipherBackupStorage destination,ExportSpaceBudget space,ExportPrompts prompts) async {
    await finish();
    _root=root;_destination=destination;_space=space;
    _cancellation=ExportCancellation();_recoveryChoice=null;_omissionGroups=null;official=null;report=null;outcome=null;extrasOmissions=const [];
    _elapsed..reset()..start();
    try {
      if(await FileSystemEntity.type(root.path,followLinks:false)==FileSystemEntityType.link)throw StateError('Unsafe private directory');
      await root.create(recursive:true);await cleanupAbandoned(root);
      if(_interruption==null)await _readInterruption();
      if(_interruption!=null)await cleanInterrupted();
      _incomplete=null;_publicationName=null;
      _progress(ExportStage.preparing);
      _estimate=await source.estimate();
      try {await space.requireAvailable(_estimate.peakBytes);} on ExportSpaceExhausted catch(error) {
        if(source is! PartialExportSnapshotSource)return outcome=OfficialExportRefused(error);
        _estimate=await source.estimateWithoutSavedFiles();
        try {await space.requireAvailable(_estimate.peakBytes);} on ExportSpaceExhausted catch(error) {
          return outcome=OfficialExportRefused(error);
        }
      }
      _cancellation.check();
      _id='${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1<<32).toRadixString(16)}';
      _session=await Directory('${root.path}/session-$_id').create();
      _snapshot=await source.capture(_session!,space,_cancellation);
      extrasOmissions=_snapshot.omissions;
      final canonical=await File(_snapshot.path).resolveSymbolicLinks();
      if(!canonical.startsWith('${await _session!.resolveSymbolicLinks()}/'))throw StateError('Snapshot is outside its private session');
      _progress(ExportStage.mapping);
      report=await mapOfficialSnapshot(snapshotPath:_snapshot.path,outputPath:'${_session!.path}/official.db',space:space,
        snapshotReceipt:_snapshot.toJson(),exportId:_id,onProgress:(family,done)=>_progress(ExportStage.mapping,family:family,done:done));
      _hasOmissions=(await omissionSummary()).isNotEmpty;
      _cancellation.check();_passphrase=await prompts.askPassphrase();
      if(_passphrase==null)throw const ExportCancelled();
      official=await _save(File(report!.path),'openstrap-official-v0.12.2-$_id.db.osbk',ExportArtifact.official);
      await _journal();_progress(ExportStage.recoveryChoice);
      final chosen=await prompts.askRecovery(_saved(RecoveryStatus.awaitingChoice));
      _cancellation.check();
      final result=chosen?await _recover():_saved(RecoveryStatus.declined);
      // Recovery cancellation is already a saved result with its own retry;
      // a terminal update must not rethrow it as cancellation of the official file.
      progress=ExportProgress(ExportStage.complete,elapsed:_elapsed.elapsed);
      notifyListeners();return outcome=result;
    } on ExportCancelled {
      progress=const ExportProgress(ExportStage.cancelled);
      return outcome=OfficialExportCancelled(receipt:official);
    } catch(error) {
      final stage=progress.stage;progress=ExportProgress(ExportStage.failed,artifact:progress.artifact);
      return outcome=OfficialExportFailed(stage,error,receipt:official);
    } finally {
      await _cleanIncomplete();
      if(_session!=null) {try {await _journal();} catch(_) { /* Keep earlier interruption metadata if storage is unavailable. */ }}
      if(!_retryAvailable)await finish();
      _elapsed.stop();notifyListeners();
    }
  }
  Future<OfficialExportOutcome> _recover() async {
    try {
      final path='${_session!.path}/recovery.db';
      _cancellation.check();await _space.requireAvailable(_estimate.peakBytes);
      if(await File(path).exists())await databaseFactory.deleteDatabase(path);
      final manifest=(await runMappingWorker(MappingInput('json','',const [],json:{
        ...report!.manifest,'artifact':'fork_recovery','official_sha256':official!.plainSha256,
      }))).text!;
      await LocalDb.exportCopy(attached:AttachedCopy(_snapshot.path,path,(_,_)async=>'',transitionManifest:manifest),
        beforeCopyWrite:()async {_cancellation.check();await _space.requireAvailable(_estimate.sqlBytes*3+_estimate.extrasBytes);});
      final saved=await _save(File(path),'openstrap-fork-recovery-$_id.db.osbk',ExportArtifact.recovery);
      _retryAvailable=false;await _journal();
      return _saved(RecoveryStatus.saved,recovery:saved);
    } catch(error) {
      await _cleanIncomplete();await _journal();
      final partial=File('${_session!.path}/recovery.db');
      if(await partial.exists())await databaseFactory.deleteDatabase(partial.path);
      _retryAvailable=true;
      return _saved(error is ExportCancelled?RecoveryStatus.cancelled:RecoveryStatus.failed,recoveryError:error);
    }
  }
  Future<OfficialExportOutcome?> retryRecovery() async {
    if(!_retryAvailable)return outcome;
    final running=_owner?._running;
    if(running!=null)return running;
    _owner=this;
    return _running??=_retryRecovery().whenComplete((){_running=null;notifyListeners();});
  }
  Future<OfficialExportOutcome> _retryRecovery() async {
    _cancellation=ExportCancellation();
    final result=await _recover();outcome=result;
    if(!_retryAvailable)await finish();
    progress=const ExportProgress(ExportStage.complete);notifyListeners();return result;
  }
  OfficialExportSaved _saved(RecoveryStatus status,{VerifiedExportFile? recovery,Object? recoveryError}) => _hasOmissions
    ?OfficialExportSavedWithOmissions(official!,report!,status,recovery:recovery,recoveryError:recoveryError)
    :OfficialExportSaved(official!,report!,status,recovery:recovery,recoveryError:recoveryError);
  Future<List<Map<String,Object?>>> omissionSummary() async {
    if(_omissionGroups!=null)return _omissionGroups!;
    final rows=(await runMappingWorker(MappingInput('omissionSummary','',const [],json:report?.tables??const {}))).rows;
    return _omissionGroups=[...rows,if(extrasOmissions.isNotEmpty){'family':'settings','reason':'unsupported','count':extrasOmissions.length}];
  }
  Future<void> finish() async {
    _passphrase=null;_retryAvailable=false;
    final session=_session;_session=null;
    if(session!=null && await session.exists())await session.delete(recursive:true);
  }
  static Future<void> cleanupAbandoned(Directory root) async {
    if(!await root.exists())return;
    await for(final entry in root.list(followLinks:false)) {
      if(entry is Directory && entry.path.split('/').last.startsWith('session-'))await entry.delete(recursive:true);
    }
  }
}
