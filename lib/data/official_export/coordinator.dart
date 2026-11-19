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

abstract interface class TreeStorageOpener {
  CipherBackupStorage open(BackupFolder folder);
}
class AndroidTreeStorageOpener implements TreeStorageOpener {
  const AndroidTreeStorageOpener();
  @override CipherBackupStorage open(BackupFolder folder)=>AndroidCipherBackupStorage(folder);
}

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
  List<ExportNotice> notices=const [];
  /// Opens a document tree named by an earlier export's journal.
  TreeStorageOpener trees=const AndroidTreeStorageOpener();
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
    await _loadLeftovers();
    await _readInterruptionSafe();
    _refreshNotices();
    if(_interruption!=null){progress=const ExportProgress(ExportStage.interrupted);notifyListeners();}
  }
  // Cleanup of an earlier export is best effort and never blocks a new one.
  // Files that could not be reached are kept in a small private list (folder
  // label, tree, file name; no passphrase, no health data) and retried later.
  bool _journalAside=false,_asideThisRun=false;
  List<Map<String,Object?>> _leftovers=[];
  File get _leftoversFile=>File('${_root.path}/leftovers.json');
  Future<void> _loadLeftovers() async {
    _leftovers=[];
    try {
      if(!await _leftoversFile.exists())return;
      final decoded=await JsonPayloadLane.shared.decodeUncached(await _leftoversFile.readAsString());
      if(decoded is Map && decoded['version']==1 && decoded['entries'] is List) {
        _leftovers=[for(final e in decoded['entries'] as List)if(e is Map && e['name'] is String && e['folder'] is String)e.cast<String,Object?>()];
      }
    } catch(_) {_leftovers=[];}
  }
  Future<bool> _saveLeftovers([ExportSpaceBudget? space]) async {
    try {
      if(_leftovers.isEmpty) {
        if(await _leftoversFile.exists())await _leftoversFile.delete();
        return true;
      }
      final text=(await runMappingWorker(MappingInput('json','',const [],json:{'version':1,'entries':_leftovers}))).text!;
      await space?.requireAvailable(8192);
      final pending=File('${_root.path}/leftovers.pending');
      await pending.writeAsString(text,flush:true);
      await pending.rename(_leftoversFile.path);
      return true;
    } catch(_) { return false; }
  }
  void _refreshNotices() {
    notices=[
      if(_journalAside)const ExportNotice(ExportNoticeKind.journalUnreadable),
      for(final e in _leftovers)ExportNotice(ExportNoticeKind.leftover,file:e['name'] as String,folder:e['folder'] as String),
    ];
  }
  Future<void> dismissNotices() async {
    _journalAside=false;_leftovers=[];
    await _saveLeftovers();_refreshNotices();notifyListeners();
  }
  Future<void> _readInterruptionSafe() async {
    try {await _readInterruption();} catch(_) {await _setAside();}
  }
  Future<void> _settleInterruption(ExportSpaceBudget space) async {
    final record=_interruption;
    if(record==null)return;
    try {await cleanInterrupted(space:space);return;} catch(_) { /* Fall through to the leftovers list. */ }
    final officialName=(record['official'] as Map?)?['name'];
    final incomplete=record['incomplete'];
    final names={
      if(incomplete is Map && incomplete['name'] is String)incomplete['name'] as String,
      if(record['pending_name'] is String)record['pending_name'] as String,
    }..remove(officialName);
    final tree=record['tree'];final localRoot=record['local_root'];
    final path=incomplete is Map?incomplete['path']:null;
    final location=tree is String?{'tree':tree}:localRoot is String?{'local_root':localRoot}:path is String?{'local_root':File(path).parent.path}:null;
    final folder=record['folder'];
    if(names.isNotEmpty && (location==null || folder is! String)) {
      await _setAside();
    } else {
      for(final name in names) {
        if(!_leftovers.any((e)=>e['name']==name && e['folder']==folder && e['tree']==location!['tree'] && e['local_root']==location['local_root'])) {
          _leftovers.add({'folder':folder,'name':name,...location!});
        }
      }
      final saved=await _saveLeftovers(space);
      if(saved)try {
        final journal=File('${_root.path}/interruption.json');
        if(await journal.exists())await journal.delete();
      } catch(_) { /* A later run reads and settles it again. */ }
    }
    _interruption=null;
  }
  Future<void> _setAside() async {
    _interruption=null;_journalAside=_asideThisRun=true;
    try {
      final aside=File('${_root.path}/interruption.unreadable');
      if(await aside.exists())await aside.delete();
      await File('${_root.path}/interruption.json').rename(aside.path);
    } catch(_) { /* The generic notice still shows. */ }
  }
  Future<void> _retryLeftovers() async {
    if(_leftovers.isEmpty)return;
    final kept=<Map<String,Object?>>[];
    for(final e in _leftovers) {
      try {
        final tree=e['tree'];final local=e['local_root'];
        final CipherBackupStorage storage=tree is String?trees.open(BackupFolder(uri:tree,name:e['folder'] as String))
          :LocalCipherBackupStorage(Directory(local as String));
        for(final file in await storage.listCiphertext()) {
          if(file.name==e['name'])await storage.deleteCiphertext(file);
        }
      } catch(_) {kept.add(e);}
    }
    if(kept.length!=_leftovers.length) {_leftovers=kept;await _saveLeftovers();}
  }
  Future<void> _readInterruption() async {
    final journal=File('${_root.path}/interruption.json');
    if(!await journal.exists())return;
    final decoded=await JsonPayloadLane.shared.decodeUncached(await journal.readAsString());
    if(decoded is! Map || decoded['version']!=1)throw const FormatException('Unreadable export receipt');
    _interruption=decoded.cast<String,Object?>();
    final leftovers=decoded['leftovers'];
    if(leftovers is List) {
      for(final entry in leftovers) {
        if(entry is Map && entry['name'] is String && entry['folder'] is String &&
            !_leftovers.any((e)=>e['name']==entry['name'] && e['folder']==entry['folder'] &&
              e['tree']==entry['tree'] && e['local_root']==entry['local_root'])) {
          _leftovers.add(entry.cast<String,Object?>());
        }
      }
    }
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
    _destination=tree is String?trees.open(BackupFolder(uri:tree,name:record['folder'] as String))
      :LocalCipherBackupStorage(File(file.path).parent);
    final passphrase=await prompts.askPassphrase();
    if(passphrase==null)return;
    final hash=await verifyBackupStream(_destination.readCiphertext(file),passphrase);
    if(hash!=candidate['sha256'])throw const FormatException('Saved file differs');
    official=VerifiedExportFile(file,_destination.label,hash,candidate['bytes'] as int);
    progress=const ExportProgress(ExportStage.complete);_interruption=null;notifyListeners();
  }
  Future<void> cleanInterrupted({ExportSpaceBudget? space}) async {
    final record=_interruption;
    if(record==null)return;
    final file=record['incomplete'];
    final pendingName=record['pending_name'];
    if(file is Map || pendingName is String) {
      final tree=record['tree'];
      final localRoot=record['local_root'];
      final path=file is Map?file['path']:null;
      final CipherBackupStorage storage;
      if(tree is String) {
        storage=trees.open(BackupFolder(uri:tree,name:record['folder'] as String));
      }else if(path is String) {
        storage=LocalCipherBackupStorage(File(path).parent);
      }else if(localRoot is String) {
        storage=LocalCipherBackupStorage(Directory(localRoot));
      }else {throw const FormatException('Missing export folder receipt');}
      // Listing also makes cleanup idempotent if the prior deletion succeeded
      // before the process died or before its receipt could be replaced.
      for(final candidate in await storage.listCiphertext()) {
        if((candidate.path==path || (file is Map && candidate.name==file['name']) || candidate.name==pendingName) &&
            candidate.name!=(record['official'] as Map?)?['name']) {
          await storage.deleteCiphertext(candidate);
        }
      }
    }
    if(_leftovers.isNotEmpty && !await _saveLeftovers(space)) {
      throw const FileSystemException('Could not save export cleanup receipt');
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
      // If the separate list could not be saved, replacing this receipt must
      // still retain its cleanup names. [coordinator_test, R2-1]
      if(_leftovers.isNotEmpty)'leftovers':_leftovers,
      if(_publicationName!=null)'pending_name':_publicationName,
      if(_destination is LocalCipherBackupStorage)'local_root':(_destination as LocalCipherBackupStorage).directory.path,
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
    final incompleteName='$name.incomplete';
    if((await _destination.listCiphertext()).any((file)=>file.name==incompleteName))throw const FileSystemException('Filename is already in use');
    _publicationName=incompleteName;await _journal();
    try {_incomplete=await _destination.createCiphertext(incompleteName);}
    catch(_) {
      // A refused create did not return ownership of any existing document.
      _publicationName=null;await _journal();rethrow;
    }
    _publicationName=null;await _journal();
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
      _asideThisRun=false;await _loadLeftovers();
      if(_interruption==null)await _readInterruptionSafe();
      await _settleInterruption(space);
      _refreshNotices();notifyListeners();
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
      // The set-aside journal stays until a later export succeeds.
      if(!_asideThisRun) {try {await File('${root.path}/interruption.unreadable').delete();} catch(_) { /* Already gone. */ }}
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
      try {await _retryLeftovers();} catch(_) { /* Quiet by design. */ }
      _refreshNotices();
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
    return _omissionGroups=(await runMappingWorker(MappingInput('omissionSummary','',const [],json:{
      'tables':report?.tables??const {},'extras':extrasOmissions,
    }))).rows;
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
