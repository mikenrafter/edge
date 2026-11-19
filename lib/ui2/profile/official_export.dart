// One immediate route shared by Profile > Data and the release checker.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../data/backup_storage.dart';
import '../../data/official_export/coordinator.dart';
import '../../data/official_export/session.dart';
import '../../data/official_export/snapshot.dart';
import '../../data/official_export/space_budget.dart';
import '../../gps/screen_wake.dart';
import '../../import/backup_crypto.dart';
import '../../l10n/app_localizations.dart';
import '../activity/share.dart' show shareOrigin;
import '../onboarding/welcome.dart' show askBackupPassphrase,PassphraseCancelled;
import '../ui2.dart';

final officialExportCoordinator=OfficialExportCoordinator();
bool _routeOpen=false;
Future<void> openOfficialExport(BuildContext context) async {
  if(_routeOpen)return;
  _routeOpen=true;
  try {await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>const OfficialExportScreen()));}
  finally {_routeOpen=false;}
}
class OfficialExportScreen extends StatefulWidget {
  const OfficialExportScreen({super.key,this.coordinator});
  final OfficialExportCoordinator? coordinator;
  @override State<OfficialExportScreen> createState()=>_OfficialExportScreenState();
}
class _OfficialExportScreenState extends State<OfficialExportScreen> implements ExportPrompts {
  late final OfficialExportCoordinator coordinator=widget.coordinator??officialExportCoordinator;
  CipherBackupStorage? _destination;
  BackupFolder? _grant;
  Completer<bool>? _recovery;
  bool _starting=false;
  Object? _error;
  @override void initState(){super.initState();coordinator.addListener(_changed);unawaited(_loadInterruption());}
  Future<void> _loadInterruption() async {
    try {
      if(widget.coordinator!=null)return;
      final root=await getApplicationSupportDirectory();
      await coordinator.loadInterruption(Directory('${root.path}/official-export'));
    }catch(error){if(mounted)setState((){_error=error;});}
  }
  void _changed(){if(mounted)setState((){});}
  @override void dispose(){
    coordinator.removeListener(_changed);
    if(!coordinator.active)unawaited(coordinator.finish());
    super.dispose();
  }
  @override Future<String?> askPassphrase() async {
    if(!mounted)return null;
    try{return await askBackupPassphrase(context,creating:true);}on PassphraseCancelled{return null;}
  }
  @override Future<bool> askRecovery(OfficialExportSaved saved) async {
    _recovery=Completer<bool>();
    if(mounted)setState((){});
    return _recovery!.future;
  }
  Future<void> _chooseFolder() async {
    try {
      if(Platform.isAndroid) {
        final folder=await AndroidBackupStorage.pick();
        if(folder==null)return;
        if(_grant?.acquiredForSession==true)await AndroidBackupStorage.release(_grant!);
        _grant=folder;_destination=AndroidCipherBackupStorage(folder);
      } else {
        // iOS exposes Documents in Files; sharing stays an explicit later action.
        final docs=await getApplicationDocumentsDirectory();
        final dir=await Directory('${docs.path}/official_exports').create(recursive:true);
        _destination=LocalCipherBackupStorage(dir);
      }
      if(mounted)setState((){_error=null;});
    }catch(error){if(mounted)setState((){_error=error;});}
  }
  Future<void> _start() async {
    if(_starting || coordinator.active)return;
    setState((){_starting=true;_error=null;});
    try {
      if(_destination==null)await _chooseFolder();
      if(_destination==null || !mounted)return;
      final support=await getApplicationSupportDirectory();
      await ScreenWake.hold('official-export');
      await coordinator.export(snapshot:LocalDbExportSnapshot(),privateRoot:Directory('${support.path}/official-export'),
        destination:_destination!,space:ExportSpaceBudget(source:AndroidExportFreeSpace()),prompts:this);
    } catch(error){if(mounted)setState((){_error=error;});}
    finally {
      await ScreenWake.releaseOwner('official-export');
      // A preexisting/automatic-backup grant is never released by this session.
      if(_grant?.acquiredForSession==true && !coordinator.canRetryRecovery) {
        await AndroidBackupStorage.release(_grant!);_grant=null;_destination=null;
      }
      if(mounted)setState((){_starting=false;});
    }
  }
  Future<bool> _confirmStop() async {
    final l=AppLocalizations.of(context)!;
    final stop=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
      title:Text(l.officialExportLeave),content:Text(l.officialExportLeaveBody),
      actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:Text(l.officialExportStay)),
        TextButton(onPressed:()=>Navigator.pop(c,true),child:Text(l.officialExportStop))]));
    if(stop==true) {
      coordinator.cancel();
      if(_recovery?.isCompleted==false)_recovery!.complete(false);
      return true;
    }
    return false;
  }
  Future<void> _share(VerifiedExportFile file) async {
    try {
      if(file.file.path.startsWith('content:')) {
        if(_destination==null)await _chooseFolder();
        final destination=_destination;
        if(destination is! AndroidCipherBackupStorage)throw const FileSystemException('Folder unavailable');
        await AndroidBackupStorage.channel.invokeMethod<void>('shareCiphertext',{'tree':destination.folder.uri,'uri':file.file.path});
      } else {
        await Share.shareXFiles([XFile(file.file.path)],sharePositionOrigin:mounted?shareOrigin(context):null);
      }
    }catch(error){if(mounted)setState((){_error=error;});}
  }
  String _failure(AppLocalizations l,Object error)=>switch(error) {
    ExportSpaceExhausted()=>l.officialExportSpace,
    PlatformException()=>l.officialExportAccess,
    BackupFormatException()=>l.officialExportFailed,
    _=>l.officialExportFailed,
  };
  String _stage(AppLocalizations l,ExportStage stage)=>switch(stage) {
    ExportStage.preparing=>l.officialExportPreparing,
    ExportStage.mapping=>l.officialExportMapping,
    ExportStage.encrypting=>l.officialExportEncrypting,
    ExportStage.verifying=>l.officialExportVerifying,
    ExportStage.publishing=>l.officialExportPublishing,
    ExportStage.cancelled=>l.officialExportCancelled,
    ExportStage.failed=>l.officialExportFailed,
    ExportStage.interrupted=>l.officialExportInterrupted,
    ExportStage.complete=>l.officialExportSaved,
    ExportStage.ready || ExportStage.recoveryChoice=>l.officialExportTitle,
  };
  @override Widget build(BuildContext context) {
    final l=AppLocalizations.of(context)!;
    final progress=coordinator.progress;
    final outcome=coordinator.outcome;
    final official=coordinator.official;
    final busy=coordinator.active || _starting;
    Widget button(String text,VoidCallback? action)=>Padding(padding:const EdgeInsets.symmetric(vertical:4),
      child:OutlinedButton(style:OutlinedButton.styleFrom(minimumSize:const Size.fromHeight(48)),onPressed:action,child:Text(text,textAlign:TextAlign.center)));
    return PopScope(canPop:!busy,onPopInvokedWithResult:(didPop,result)async {
      if(didPop)return;
      await _confirmStop();
    },child:Scaffold(
      appBar:AppBar(),
      body:SafeArea(child:ListView(padding:const EdgeInsets.all(16),children:[
        Text(l.officialExportTitle,style:Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height:12),
        Text(l.officialExportTarget,style:Theme.of(context).textTheme.titleMedium),
        const SizedBox(height:12),Text(l.officialExportOffline),
        const SizedBox(height:12),Text(l.officialExportIntro),
        ExpansionTile(title:Text(l.officialExportChecklist.split('\n').first),children:[
          Padding(padding:const EdgeInsets.all(16),child:Text(l.officialExportChecklist)),
          Padding(padding:const EdgeInsets.all(16),child:Text(l.officialExportPrune)),
        ]),
        const SizedBox(height:16),
        if(coordinator.hasInterruption)...[
          Text(l.officialExportInterrupted),
          if(coordinator.interruptedName!=null)Text(coordinator.interruptedName!),
          button(l.officialExportVerifySaved,()async{try{await coordinator.verifyInterrupted(this);}catch(error){if(mounted)setState((){_error=error;});}}),
        ],
        if(!busy && official==null)...[
          button(l.officialExportChooseFolder,_chooseFolder),
          if(_destination!=null)Text(_destination!.label),
          button(l.officialExportStart,_start),
        ],
        if(busy && progress.stage!=ExportStage.recoveryChoice)...[
          Semantics(liveRegion:true,child:Text(_stage(l,progress.stage))),
          Text('${progress.done}${progress.total==null?'':' / ${progress.total}'} · ${progress.elapsed.inSeconds} s'),
          if(progress.total!=null && progress.total!>0)
            LinearProgressIndicator(value:(progress.done/progress.total!).clamp(0,1)),
          button(l.actionCancel,()async{await _confirmStop();}),
        ],
        if(official!=null)...[
          const SizedBox(height:16),Text(l.officialExportSaved),
          SelectableText(official.file.name),Text(official.folder),
          button(l.officialExportShare,()=>_share(official)),
        ],
        if(_recovery!=null && !_recovery!.isCompleted)...[
          Text(l.officialExportRecoveryQuestion,style:Theme.of(context).textTheme.titleMedium),
          Semantics(selected:true,child:button(l.officialExportYes,(){_recovery!.complete(true);setState((){});})),
          button(l.officialExportNo,(){_recovery!.complete(false);setState((){});}),
        ],
        if(outcome is OfficialExportSaved)...[
          if(outcome.recoveryStatus==RecoveryStatus.declined)Text(l.officialExportNotSaved),
          if(outcome.recovery!=null)...[SelectableText(outcome.recovery!.file.name),button(l.officialExportShare,()=>_share(outcome.recovery!))],
          if(outcome.recoveryError!=null)...[
            Text(l.officialExportRecoveryFailed),Text(_failure(l,outcome.recoveryError!)),
            button(l.officialExportRetryRecovery,coordinator.active?null:()async{await coordinator.retryRecovery();}),
          ],
        ],
        if(outcome is OfficialExportRefused)...[Text(_failure(l,outcome.reason)),button(l.officialExportRetry,_start)],
        if(outcome is OfficialExportFailed)...[Text(_failure(l,outcome.reason)),button(l.officialExportRetry,_start)],
        if(outcome is OfficialExportCancelled)...[Text(l.officialExportCancelled),button(l.officialExportRetry,_start)],
        if(_error!=null)Text(_failure(l,_error!)),
        if(coordinator.report!=null)...[
          button(l.officialExportOmissions,()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>_Omissions(coordinator:coordinator)))),
          button(l.officialExportDays,()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>_Days(coordinator:coordinator)))),
        ],
      ])),
    ));
  }
}
class _Omissions extends StatefulWidget {
  const _Omissions({required this.coordinator});
  final OfficialExportCoordinator coordinator;
  @override State<_Omissions> createState()=>_OmissionsState();
}
class _OmissionsState extends State<_Omissions> {
  late final Future<List<Map<String,Object?>>> _groups=widget.coordinator.omissionSummary();
  @override Widget build(BuildContext context) {
    final l=AppLocalizations.of(context)!;
    return Scaffold(appBar:AppBar(title:Text(l.officialExportOmissions)),body:FutureBuilder(
      future:_groups,builder:(c,snapshot){
        if(snapshot.hasError)return Center(child:Text(l.officialExportFailed));
        final groups=snapshot.data;
        if(groups==null)return Padding(padding:const EdgeInsets.all(16),child:Text(l.officialExportPreparing));
        return ListView.builder(itemCount:groups.length+1,itemBuilder:(c,i){
          if(i==0)return Padding(padding:const EdgeInsets.all(16),child:Text(widget.coordinator.outcome is OfficialExportSaved && (widget.coordinator.outcome as OfficialExportSaved).recoveryStatus==RecoveryStatus.saved?l.officialExportSaved:l.officialExportNotSaved));
          final group=groups[i-1];
          final family=switch(group['family']){'recordings'=>l.officialExportRecordings,'entries'=>l.officialExportEntries,'settings'=>l.officialExportSettings,_=>l.officialExportOther};
          return ListTile(title:Text('$family · ${group['count']}'),subtitle:Text(group['reason']=='rebuilt'?l.officialExportRebuilt:l.officialExportUnsupported));
        });
      }));
  }
}
class _Days extends StatelessWidget {
  const _Days({required this.coordinator});
  final OfficialExportCoordinator coordinator;
  @override Widget build(BuildContext context) {
    final l=AppLocalizations.of(context)!;final days=coordinator.report!.days;
    return Scaffold(appBar:AppBar(title:Text(l.officialExportDays)),body:ListView.builder(itemCount:days.length+1,itemBuilder:(c,i){
      if(i==0)return Padding(padding:const EdgeInsets.all(16),child:Text(l.officialExportBoundary));
      final day=days[i-1];
      final coverage=switch(day['coverage']){'Exact input retained'=>l.officialExportExact,'Partial input retained'=>l.officialExportPartial,_=>l.officialExportNone};
      return ListTile(title:Text('${day['day']}'),subtitle:Text('$coverage\n${l.officialExportRecordings}: ${day['source_live_parents']} + ${day['exact_archive_additions']}\n${day['target_beats']}'));
    }));
  }
}
