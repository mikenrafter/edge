// One immediate route shared by Profile > Data and the release checker.
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrintThrottled;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../compute/derivation_engine.dart' show DerivationEngine;
import '../../data/backup_storage.dart';
import '../../data/official_export/coordinator.dart';
import '../../data/official_export/mapping_worker.dart' show exportRecordFamily;
import '../../data/official_export/omission_reasons.dart' show kSkippedOmissionGroups;
import '../../data/official_export/session.dart';
import '../../data/official_export/snapshot.dart';
import '../../data/official_export/space_budget.dart';
import '../../gps/screen_wake.dart';
import '../../import/backup_crypto.dart';
import '../../l10n/app_localizations.dart';
import '../activity/share.dart' show shareOrigin;
import '../onboarding/welcome.dart' show askBackupPassphrase,PassphraseCancelled;
import '../ui2.dart';
import 'profile.dart' show SettingsAccordion;

final officialExportCoordinator=OfficialExportCoordinator()..exclusive=const _DeriveHold();
// The derive latch: a pass in flight finishes first, passes that try meanwhile
// take the ordinary busy skip. A wedged pass (over two minutes) is not waited
// for, as for "Delete everything".
class _DeriveHold implements ExportHold {
  const _DeriveHold();
  @override Future<bool> acquire()=>DerivationEngine.acquireForReset();
  @override void release()=>DerivationEngine.releaseForReset();
}
bool _routeOpen=false;
Future<void> openOfficialExport(BuildContext context,{bool newerOfficialAvailable=false,DateTime? checkedAt}) async {
  if(_routeOpen)return;
  _routeOpen=true;
  try {await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>OfficialExportScreen(newerOfficialAvailable:newerOfficialAvailable,checkedAt:checkedAt)));}
  finally {_routeOpen=false;}
}
class OfficialExportScreen extends StatefulWidget {
  const OfficialExportScreen({super.key,this.coordinator,this.newerOfficialAvailable=false,this.checkedAt});
  final bool newerOfficialAvailable;
  final DateTime? checkedAt;
  final OfficialExportCoordinator? coordinator;
  @override State<OfficialExportScreen> createState()=>_OfficialExportScreenState();
}
class _OfficialExportScreenState extends State<OfficialExportScreen> implements ExportPrompts {
  late final OfficialExportCoordinator coordinator=widget.coordinator??officialExportCoordinator;
  CipherBackupStorage? _destination;
  BackupFolder? _grant;
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
    if(!coordinator.active) {
      unawaited(coordinator.finish());
      if(_grant?.acquiredForSession==true)unawaited(_releaseGrant());
    }
    super.dispose();
  }
  @override Future<String?> askPassphrase() async {
    if(!mounted)return null;
    try{return await askBackupPassphrase(context,creating:true);}on PassphraseCancelled{return null;}
  }
  @override Future<bool> askRecovery(OfficialExportSaved saved) async {
    final choice=coordinator.waitForRecoveryChoice();
    if(mounted)setState((){});
    return choice;
  }
  Future<void> _chooseFolder() async {
    try {
      if(Platform.isAndroid) {
        final folder=await AndroidBackupStorage.pick();
        if(folder==null)return;
        if(_grant?.acquiredForSession==true)await _releaseGrant();
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
    } catch(error,stack){
      debugPrintThrottled('[official-export] screen error: ${error.runtimeType}: $error\n$stack');
      if(mounted)setState((){_error=error;});
    }
    finally {
      await ScreenWake.releaseOwner('official-export');
      // A preexisting/automatic-backup grant is never released by this session.
      if(_grant?.acquiredForSession==true && !coordinator.canRetryRecovery) {
        await _releaseGrant();
      }
      if(mounted)setState((){_starting=false;});
    }
  }
  Future<void> _releaseGrant() async {
    final grant=_grant;
    if(grant?.acquiredForSession!=true)return;
    try {await AndroidBackupStorage.release(grant!);}
    catch(error){if(mounted)setState((){_error=error;});}
    finally {_grant=null;_destination=null;}
  }
  Future<void> _retryRecovery() async {
    await ScreenWake.hold('official-export');
    try {await coordinator.retryRecovery();}
    catch(error){if(mounted)setState((){_error=error;});}
    finally {
      await ScreenWake.releaseOwner('official-export');
      if(!coordinator.canRetryRecovery)await _releaseGrant();
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
    finally {await _releaseGrant();}
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
      backgroundColor:P.of(context).bg,
      appBar:AppBar(),
      body:SafeArea(child:ListView(padding:const EdgeInsets.all(16),children:[
        Text(l.officialExportTitle,style:Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height:12),
        Text(l.officialExportTarget,style:Theme.of(context).textTheme.titleMedium),
        const SizedBox(height:12),Text(widget.newerOfficialAvailable?l.officialExportNewer:widget.checkedAt!=null?l.officialExportNoNewer:l.officialExportOffline),
        if(widget.checkedAt!=null)Text('${l.officialExportChecked} ${MaterialLocalizations.of(context).formatMediumDate(widget.checkedAt!)}'),
        const SizedBox(height:12),Text(l.officialExportIntro),
        SettingsAccordion(l.officialExportChecklist.split('\n').first,id:'official_export_checklist',children:[
          Padding(padding:const EdgeInsets.all(16),child:Text(l.officialExportChecklist)),
          Padding(padding:const EdgeInsets.all(16),child:Text(l.officialExportPrune)),
        ]),
        const SizedBox(height:16),
        if(coordinator.hasInterruption)...[
          if(coordinator.wasInterrupted)Text(l.officialExportInterrupted),
          if(coordinator.interruptedName!=null)Text(coordinator.interruptedName!),
          if(coordinator.interruptedName!=null)button(l.officialExportVerifySaved,()async{try{await coordinator.verifyInterrupted(this);}catch(error){if(mounted)setState((){_error=error;});}}),
        ],
        for(final notice in coordinator.notices)Padding(padding:const EdgeInsets.symmetric(vertical:4),
          child:Text(switch(notice.kind){
            ExportNoticeKind.leftover=>l.officialExportLeftover(notice.file!,notice.folder!),
            ExportNoticeKind.journalUnreadable=>l.officialExportJournalUnreadable})),
        if(coordinator.notices.isNotEmpty)button(l.officialExportDismiss,busy?null:()=>coordinator.dismissNotices()),
        // The result takes the progress line's place. Below the buttons it sat
        // off screen once the wearer had scrolled to the progress, and the
        // page looked idle (emulator, 2026-11-20).
        if(!busy && outcome is OfficialExportRefused)...[Semantics(liveRegion:true,child:Text(_failure(l,outcome.reason))),button(l.officialExportRetry,_start)],
        if(!busy && outcome is OfficialExportFailed)...[Semantics(liveRegion:true,child:Text(_failure(l,outcome.reason))),button(l.officialExportRetry,_start)],
        if(!busy && outcome is OfficialExportCancelled)...[Semantics(liveRegion:true,child:Text(l.officialExportCancelled)),button(l.officialExportRetry,_start)],
        if(_error!=null)Semantics(liveRegion:true,child:Text(_failure(l,_error!))),
        if(!busy && official==null)...[
          button(l.officialExportChooseFolder,_chooseFolder),
          if(_destination!=null)Text(_destination!.label),
          button(l.officialExportStart,_start),
        ],
        if(official!=null)...[
          const SizedBox(height:16),Text(l.officialExportSaved),
          SelectableText(official.file.name),Text(official.folder),
          button(l.officialExportShare,()=>_share(official)),
        ],
        if(busy && progress.stage!=ExportStage.recoveryChoice)...[
          Semantics(liveRegion:true,child:Text(_stage(l,progress.stage))),
          if(progress.stage==ExportStage.mapping && progress.family!=null)Text(switch(exportRecordFamily(progress.family!)){
            'recordings'=>l.officialExportRecordings,'settings'=>l.officialExportSettings,'entries'=>l.officialExportEntries,_=>l.officialExportOther}),
          Text('${progress.done}${progress.total==null?'':' / ${progress.total}'} ${progress.stage==ExportStage.mapping?l.officialExportRows:l.officialExportBytes} · ${l.snoozeValueSeconds(progress.elapsed.inSeconds)}'),
          if(progress.total!=null && progress.total!>0)
            LinearProgressIndicator(value:(progress.done/progress.total!).clamp(0,1)),
          button(l.actionCancel,()async{await _confirmStop();}),
        ],
        // Keep the choice's extent while recovery runs: removing it clamps
        // the scroll offset and moves the already verified official receipt.
        if(coordinator.awaitingRecoveryChoice || (busy && official!=null))
          Visibility(visible:coordinator.awaitingRecoveryChoice,
            maintainSize:true,maintainAnimation:true,maintainState:true,
            child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Text(l.officialExportRecoveryQuestion,style:Theme.of(context).textTheme.titleMedium),
          Semantics(selected:true,child:button(l.officialExportYes,(){coordinator.chooseRecovery(true);setState((){});})),
          button(l.officialExportNo,(){coordinator.chooseRecovery(false);setState((){});}),
        ])),
        if(outcome is OfficialExportSaved)...[
          if(outcome.recoveryStatus==RecoveryStatus.declined)Text(l.officialExportNotSaved),
          if(outcome.recovery!=null)...[SelectableText(outcome.recovery!.file.name),button(l.officialExportShare,()=>_share(outcome.recovery!))],
          if(outcome.recoveryError!=null)...[
            Text(l.officialExportRecoveryFailed),Text(_failure(l,outcome.recoveryError!)),
            button(l.officialExportRetryRecovery,coordinator.active?null:_retryRecovery),
          ],
        ],
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
        final kept=[for(final g in groups)if(!kSkippedOmissionGroups.contains(g['reason']))g];
        final skipped=[for(final g in groups)if(kSkippedOmissionGroups.contains(g['reason']))g];
        String family(Map<String,Object?> group)=>switch(group['family']){'recordings'=>l.officialExportRecordings,'entries'=>l.officialExportEntries,'settings'=>l.officialExportSettings,_=>l.officialExportOther};
        String reason(Object? code)=>switch(code){
          'rebuilt'=>l.officialExportRebuilt,'space'=>l.officialExportSkippedSpace,'unfinished'=>l.officialExportSkippedUnfinished,
          'unreadable'=>l.officialExportSkippedUnreadable,'value'=>l.officialExportSkippedValue,_=>l.officialExportUnsupported};
        final outcome=widget.coordinator.outcome;
        // The saved-file header sits only above items the saved files cover.
        final head=widget.coordinator.progress.stage==ExportStage.recoveryChoice?l.officialExportRecoveryQuestion
          :outcome is OfficialExportSaved && outcome.recoveryStatus==RecoveryStatus.saved?l.officialExportSaved
          :outcome is OfficialExportSaved && outcome.recoveryError!=null?l.officialExportRecoveryFailed:l.officialExportNotSaved;
        Widget note(String text)=>Padding(padding:const EdgeInsets.all(16),child:Text(text));
        return ListView(children:[
          if(kept.isNotEmpty || skipped.isEmpty)note(head),
          for(final g in kept)ListTile(title:Text('${family(g)} · ${g['count']}'),subtitle:Text(reason(g['reason']))),
          if(skipped.isNotEmpty)note(l.officialExportSkippedHeader),
          for(final g in skipped)ListTile(title:Text('${family(g)} · ${g['count']}'),subtitle:Text(reason(g['reason']))),
        ]);
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
      return ListTile(title:Text('${day['day']}'),subtitle:Text('$coverage\n${l.officialExportRecordings}: ${day['source_live_parents']} + ${day['exact_archive_additions']}\n${l.officialExportBeats}: ${day['target_beats']}'));
    }));
  }
}
