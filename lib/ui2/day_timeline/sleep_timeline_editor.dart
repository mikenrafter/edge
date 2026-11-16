// Mutable horizontal editor for one night. This State owns staged blocks and
// entry actions; SleepEditSaver owns the durable acknowledgement.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/day_label.dart';
import '../../data/local_repository.dart';
import '../../data/sleep_edit_write.dart';
import '../../l10n/app_localizations.dart';
import '../../state/control_operations.dart' show SleepOperationResult;
import '../chart_annotations.dart';
import '../charts.dart' show SleepStage;
import '../grammar.dart';
import '../screens/day_timeline.dart' show DayGraph, dayGraph;
import '../theme.dart';
import 'preview_stager.dart';
import 'timeline_chart.dart';
import 'timeline_model.dart';

/// A calendar day offset by noon, with the owner's containing-midnight fallback.
/// Calendar constructors preserve DST; extension is only the missing interval.
TimelineView sleepEditorDay(int start, int end) {
  final local = DateTime.fromMillisecondsSinceEpoch(start * 1000);
  final noon = DateTime(local.year,local.month,local.day-(local.hour<12?1:0),12);
  final noonEnd = DateTime(noon.year,noon.month,noon.day+1,12);
  double sec(DateTime d)=>d.millisecondsSinceEpoch/1000;
  if (end<=sec(noonEnd)) return TimelineView(sec(noon),sec(noonEnd));
  final midnight = DateTime(local.year,local.month,local.day);
  final midnightEnd = DateTime(local.year,local.month,local.day+1);
  if(end<=sec(midnightEnd)) return TimelineView(sec(midnight),sec(midnightEnd));
  return TimelineView(sec(noon),end.toDouble());
}

/// Everything the editor draws, for one night.
class SleepEditorData {
  const SleepEditorData({
    required this.day,
    required this.domainStart,
    required this.hr,
    required this.movement,
    required this.main,
    this.mainSource,
    this.naps = const [],
    this.napSources = const {},
    this.usualBed,
    this.usualWake,
    this.detected = const {}, this.restorable = const {},
  });

  /// The night, by its wake date.
  final String day;

  /// First signal minute, epoch seconds. Calendar boundaries include DST.
  final int domainStart;
  final List<double?> hr, movement;
  final SleepBlock main;
  final String? mainSource;
  final List<SleepBlock> naps;

  /// A stored nap's `source` by block id (absent: a detected nap).
  final Map<String, String> napSources;
  final int? usualBed, usualWake;
  final Map<String,SleepBlock> detected, restorable;

  int get domainEnd => domainStart + hr.length * 60;

  /// Signals and separate entries in the containing day, including all local
  /// dates crossed by a long main sleep. Missing signal minutes stay absent.
  static Future<SleepEditorData> load(LocalRepository repo, String day,
      {(int, int)? window, (int, int)? fallback, (int, int)? usual}) async {
    final d = DateTime.parse(day);

    var w = window ?? fallback ??
        (DateTime(d.year, d.month, d.day - 1, 23).millisecondsSinceEpoch ~/ 1000,
            DateTime(d.year, d.month, d.day, 7).millisecondsSinceEpoch ~/ 1000);
    final night = await repo.getSleepEditorMain(day);
    final savedStart=night['onset_ts'],savedEnd=night['wake_ts'];
    if(night['sleep_source']!='rejected'&&savedStart is num&&savedEnd is num&&savedEnd>savedStart){
      w=(savedStart.round(),savedEnd.round());
    }
    if(night['sleep_source']=='rejected'&&night['restore_start'] is num&&night['restore_end'] is num) {
      w=((night['restore_start'] as num).round(),(night['restore_end'] as num).round());
    }
    final home = sleepEditorDay(w.$1,w.$2);
    final baseStart = home.start.round(), baseEnd = home.end.round();
    final detected = <String,SleepBlock>{}, restorable = <String,SleepBlock>{};
    void remember(String id, BlockKind kind, Map value) {
      for(final (prefix,into) in [('detected',detected),('restore',restorable)]) {
        final a=value['${prefix}_start'], b=value['${prefix}_end'];
        if(a is num && b is num && b>a) into[id]=SleepBlock(id,kind,a.round(),b.round());
      }
    }
    remember('main',BlockKind.main,night);
    final graphs = <DayGraph>[];
    final naps = <SleepBlock>[];
    final sources = <String, String>{};
    final first = DateTime.fromMillisecondsSinceEpoch(baseStart * 1000);
    final last = DateTime.fromMillisecondsSinceEpoch((baseEnd - 1) * 1000);
    for (var dateTime = DateTime(first.year,first.month,first.day);
        !dateTime.isAfter(DateTime(last.year,last.month,last.day));
        dateTime = DateTime(dateTime.year,dateTime.month,dateTime.day+1)) {
      final date = dayLabelOf(dateTime);
      graphs.add(dayGraph(await repo.getDayTimeline(date)));
      final n = await repo.getSleepEditorNaps(date);
      for (final x in (n['naps'] as List?) ?? const []) {
        if (x is! Map) continue;
        final a = (x['start'] as num?)?.round(), b = (x['end'] as num?)?.round();
        if (a == null || b == null || b <= a || b <= baseStart || a >= baseEnd) continue;
        // Display keeps even overlapping entries separate. Their stored identity
        // is passed back to the writer, never merged by the chart.
        final id = 'nap:$date:$a:$b:${x['source'] ?? 'detected'}';
        naps.add(SleepBlock(id, BlockKind.nap, a, b));
        remember(id,BlockKind.nap,x);
        if (x['source'] != null) sources[id] = x['source'] as String;
      }
    }
    var start = w.$1 < baseStart ? w.$1 : baseStart;
    var end = w.$2 > baseEnd ? w.$2 : baseEnd;
    for (final n in naps) {
      if (n.start < start) start = n.start;
      if (n.end > end) end = n.end;
    }
    final slots = (end - start + 59) ~/ 60;
    final hr = List<double?>.filled(slots, null), mv = List<double?>.filled(slots, null);
    for (final g in graphs) {
      final int? signalStart = g.dayStart;
      if (signalStart == null) continue;
      for (var i = 0; i < slots; i++) {
        final offset = start + i * 60 - signalStart;
        if (offset < 0) continue;
        final m = offset ~/ 60;
        if (m < 0 || m >= g.slots) continue;
        if (m < g.hr.length && g.hr[m] != null) hr[i] = g.hr[m];
        if (m < g.movement.length && g.movement[m] != null) mv[i] = g.movement[m];
      }
    }
    return SleepEditorData(day: day, domainStart: start, hr: hr, movement: mv,
        main: SleepBlock('main', BlockKind.main, w.$1, w.$2),
        mainSource: night['sleep_source'] as String?,
      detected: detected, restorable: restorable, naps: naps,
        napSources: sources, usualBed: usual?.$1, usualWake: usual?.$2);
  }
}

/// Save's acknowledgement: [written] is the durable write; [done] the
/// background recalculation.
abstract interface class SleepEditSaver {
  ({Future<void> written, Future<SleepOperationResult> done}) save(SleepEditPlan plan);
}

/// What the editor hands back to the night card after a Save.
class SleepEditorResult {
  const SleepEditorResult(this.done);
  final Future<SleepOperationResult> done;
}

/// The plan Save writes: the main window when it moved, the naps that are new
/// or moved. Pure.
SleepEditPlan planOf(SleepEditorData d, List<SleepBlock> blocks) {
  final main = blocks.firstWhere((b) => b.kind == BlockKind.main);
  final before = {for (final n in d.naps) n.id: n};
  return SleepEditPlan(
    day: d.day,
    window: main.start != d.main.start || main.end != d.main.end ? (main.start, main.end) : null,
    naps: [
      for (final n in blocks.where((b) => b.kind == BlockKind.nap))
        if (before[n.id] case final was?)
          if (was.start != n.start || was.end != n.end)
            NapWrite(start: n.start, end: n.end, fromStart: was.start, fromEnd: was.end,
                fromSource: d.napSources[n.id])
          else ...[]
        else
          NapWrite(start: n.start, end: n.end),
    ],
  );
}

/// Owns the asynchronous read inside the editor route, so entering and leaving
/// the editor never waits on storage. Disposed reads cannot navigate.
class SleepTimelineEditorRoute extends StatefulWidget {
  const SleepTimelineEditorRoute({super.key, required this.load, required this.save});
  final Future<SleepEditorData> Function() load;
  final SleepEditSaver save;

  @override
  State<SleepTimelineEditorRoute> createState() => _SleepTimelineEditorRouteState();
}

class _SleepTimelineEditorRouteState extends State<SleepTimelineEditorRoute> {
  late Future<SleepEditorData> _data = Future.sync(widget.load);

  @override
  Widget build(BuildContext context) => FutureBuilder<SleepEditorData>(
    future: _data,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return SleepTimelineEditor(data: snapshot.requireData, save: widget.save);
      }
      final l = AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('en'));
      final p = P.of(context);
      return Scaffold(backgroundColor: p.bg, body: SafeArea(child: Column(children: [
        NavBar(l.sleepEditorTitle, onBack: () => Navigator.of(context).maybePop()),
        if (snapshot.connectionState == ConnectionState.done && snapshot.hasError)
          Padding(padding: const EdgeInsets.all(S.x4), child: Column(children: [
            Semantics(liveRegion: true, child: Text(l.sleepEditorLoadFailed)),
            TextButton(onPressed: () => setState(() { _data = Future.sync(widget.load); }),
              child: Text(l.sleepEditorRetry)),
          ]))
        else
          Expanded(child: ListView(key: const ValueKey('sleep-editor-loading'),
            padding: const EdgeInsets.all(S.x4), children: [
              Semantics(liveRegion: true, child: Text(l.sleepEditorLoading,
                style: F.body.copyWith(color: p.ink))),
              const SizedBox(height: S.x4),
              Container(height: 240, decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.circular(12))),
              const SizedBox(height: S.x4),
              Container(height: 100, decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.circular(12))),
            ])),
      ])));
    },
  );
}

class SleepTimelineEditor extends StatefulWidget {
  const SleepTimelineEditor({super.key, required this.data, required this.save,
      this.haptics = const PhoneTimelineHaptics(), this.initialScrub});
  final SleepEditorData data;
  final SleepEditSaver save;
  final TimelineHaptics haptics;
  final double? initialScrub;

  static const saveKey = ValueKey('sleep-editor-save');
  static const cancelKey = ValueKey('sleep-editor-cancel');
  static const addKey = ValueKey('sleep-editor-add');
  static const resetKey = ValueKey('sleep-editor-reset');
  static const readoutKey = ValueKey('sleep-editor-readout');

  @override
  State<SleepTimelineEditor> createState() => SleepTimelineEditorState();
}

class SleepTimelineEditorState extends State<SleepTimelineEditor>
    implements TimelineListener, AnnotationListener {
  late final TimelineController controller;
  late List<SleepBlock> blocks = [widget.data.main,...widget.data.naps];
  String active='main';
  late Set<String> _removed={for(final b in blocks) if(_source(b)=='rejected') b.id};
  late List<SleepStage?> stages;
  bool _saving=false, _readoutScrub=false, _adding=false, _actionCancelled=false;
  int? _addStart;
  TimelineView? _addHalf;
  int _napSeq=0, lastStageMicros=0;
  final _messages=GlobalKey<ScaffoldMessengerState>();
  String? _saveError;
  SleepEntryEdit? _action;
  ({List<SleepBlock> blocks,Set<String> removed})? _actionOrigin;
  SleepEditorData get d=>widget.data;
  AppLocalizations get l=>AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
  SleepBlock get _active=>blocks.firstWhere((b)=>b.id==active);
  SleepBlock? _original(String id)=>[d.main,...d.naps].where((b)=>b.id==id).firstOrNull;
  String? _source(SleepBlock b)=>b.kind==BlockKind.main?d.mainSource:d.napSources[b.id];
  SleepBlock? _detected(SleepBlock b)=>d.detected[b.id]??
    (_source(b)==null||_source(b)=='auto'||_source(b)=='auto_fallback'||_source(b)=='legacy'
      ?_original(b.id):null);
  SleepBlock? _restore(SleepBlock b)=>_detected(b)??d.restorable[b.id]??_original(b.id)??(_removed.contains(b.id)?b:null);
  String _name(SleepBlock b)=>_removed.contains(b.id)
      ? b.kind==BlockKind.nap?l.sleepEditorRemovedNap:l.sleepEditorRemovedMain
      :b.kind==BlockKind.main?l.sleepEditorMainEntry:l.sleepEditorNapEntry;
  TimelineView get _day=>sleepEditorDay(blocks.first.start,blocks.first.end);

  @override
  void initState(){
    super.initState();
    _readoutScrub=widget.initialScrub!=null;
    final edge=DateTime.fromMillisecondsSinceEpoch(_day.end.round()*1000);
    controller=TimelineController(domainStart:_day.start<d.domainStart?_day.start:d.domainStart.toDouble(),
      domainEnd:DateTime(edge.year,edge.month,edge.day+1,edge.hour).millisecondsSinceEpoch/1000,
      home:_day,scrub:widget.initialScrub);
    _lastScrub=controller.scrub;
    controller.addListener(_changed);
    _restage();
  }
  double? _lastScrub;
  @override
  void dispose(){controller.removeListener(_changed);controller.dispose();super.dispose();}
  void _changed(){
    if(_lastScrub==controller.scrub)return;
    _lastScrub=controller.scrub;
    if(mounted)setState(()=>_readoutScrub=true);
  }
  void _restage(){
    final clock=Stopwatch()..start();
    stages=previewStages(domainStart:d.domainStart,hr:d.hr,movement:d.movement,
      blocks:blocks.where((b)=>!_removed.contains(b.id)).toList());
    controller.home=_day;
    lastStageMicros=clock.elapsedMicroseconds;
  }
  @override
  void blocksChanged(List<SleepBlock> next){
    if(_saving||_action!=null||_adding)return;
    setState((){blocks=next;_readoutScrub=false;_restage();});
  }
  @override
  void blockSelected(String id,{required bool zoom}){
    if(_saving||_adding||!blocks.any((b)=>b.id==id))return;
    setState((){
      if(active!=id&&_action!=null){
        final before=_actionOrigin;
        if(before!=null){blocks=before.blocks;_removed=before.removed;}
        _action=null;_actionOrigin=null;_actionCancelled=true;
        _messages.currentState?.removeCurrentSnackBar();
        _restage();
      }
      active=id;_readoutScrub=false;
    });
  }
  @override
  void scrubbed(double t){if(!_readoutScrub)setState(()=>_readoutScrub=true);}
  @override
  void dragEnded(){}
  void _undoable(String message,VoidCallback change){
    final before=List<SleepBlock>.of(blocks), removed=Set<String>.of(_removed);
    final action=_action, origin=_actionOrigin;
    setState((){change();_readoutScrub=false;_restage();});
    final messenger=_messages.currentState!;
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(duration:const Duration(seconds:5),content:Text(message),
      action:SnackBarAction(label:l.sleepEditorUndo,onPressed:(){
        if(!mounted||_saving)return;
        setState((){blocks=before;_removed=removed;_action=action;_actionOrigin=origin;_restage();});
      })));
  }
  void _stage(SleepEntryAction action){
    final original=_original(active);
    if(original==null)return;
    _actionOrigin??=(blocks:List.of(blocks),removed:Set.of(_removed));
    _action=SleepEntryEdit(start:original.start,end:original.end,main:original.kind==BlockKind.main,
      source:_source(original),action:action);
    _actionCancelled=false;
  }
  bool get _dirty=>!planOf(d,blocks.where((b)=>!_removed.contains(b.id)||b.kind==BlockKind.main).toList()).isEmpty;
  bool get _otherDirty=>blocks.where((b)=>!_removed.contains(b.id)).any((b){final old=_original(b.id);return b.id!=active&&(old==null||old!=b);});
  void _remove(){
    _undoable(l.sleepEditorRemovedNotice,(){
      final old=_original(active);
      if(old!=null)_stage(SleepEntryAction.remove);
      _removed.add(active);
    });
  }
  void _resetDetected(){
    final target=_restore(_active);if(target==null)return;
    _undoable(l.sleepEditorResetNotice,(){
      final original=_original(active);
      if(original!=null&&(original!=target||_source(original)=='rejected')) { _stage(SleepEntryAction.resetDetected); }
      else{_action=null;_actionOrigin=null;}
      blocks=[for(final b in blocks)if(b.id==active)target else b];
      _removed.remove(active);
    });
  }
  Future<void> _ghost(BlockEnd which)async{
    if(_action!=null||_saving||_adding)return;
    final selected=_active, target=_detected(_active);if(target==null)return;
    final from=which==BlockEnd.start?selected.start:selected.end;
    final to=which==BlockEnd.start?target.start:target.end;
    final confirmed=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
      title:Text(which==BlockEnd.start?l.sleepEditorGhostStartTitle:l.sleepEditorGhostEndTitle),
      content:Text(which==BlockEnd.start
        ?l.sleepEditorGhostStartBody(_clock(from),_clock(to),_clock(selected.end))
        :l.sleepEditorGhostEndBody(_clock(from),_clock(to),_clock(selected.start))),
      actions:[TextButton(onPressed:()=>Navigator.of(c).pop(false),child:Text(l.actionCancel)),
        TextButton(key:const ValueKey('sleep-editor-ghost-confirm'),onPressed:()=>Navigator.of(c).pop(true),
          child:Text(l.sleepEditorResetDetected))]));
    if(!mounted||confirmed!=true||active!=selected.id)return;
    _applyTime(which,to);
  }
  void _applyTime(BlockEnd which,int at){
    if(_saving||_action!=null||_adding)return;
    final next=moveBlockEnd(blocks.where((b)=>!_removed.contains(b.id)).toList(),active,which,at,
      domainStart:controller.domainStart.round(),domainEnd:controller.domainEnd.round());
    final moved=next.firstWhere((b)=>b.id==active);
    if((which==BlockEnd.start?moved.start:moved.end)!=at){
      setState(()=>_saveError=l.sleepEditorOverlapError);return;
    }
    _undoable(l.sleepEditorResetNotice,(){blocks=[for(final b in blocks)if(b.id==active)moved else b];});
  }
  void _cancelAdd(){setState((){_adding=false;_addStart=null;_addHalf=null;});controller.reset();}
  void _pick(double time){
    if(!_adding||_saving)return;
    final at=(time/60).round()*60, main=blocks.first;
    if(_addStart==null){
      if(blocks.any((b)=>!_removed.contains(b.id)&&b.contains(at.toDouble())))return;
      final half=at<main.start?TimelineView(controller.home.start,main.start.toDouble())
        :TimelineView(main.end.toDouble(),controller.home.end);
      if(at<half.start||at>=half.end)return;
      setState((){_addStart=at;_addHalf=half;});controller.setScrub(at.toDouble());controller.glideTo(half);
    }else{
      final start=_addStart!, half=_addHalf!;
      if(at<=start||at>half.end||at-start<300||at-start>6*3600||
          blocks.any((b)=>!_removed.contains(b.id)&&start<b.end&&at>b.start)){
        setState(()=>_saveError=l.sleepEditorOverlapError);return;
      }
      final nap=SleepBlock('new:${_napSeq++}',BlockKind.nap,start,at);
      setState((){blocks=[...blocks,nap];active=nap.id;_adding=false;_addStart=null;_addHalf=null;
        _readoutScrub=false;_saveError=null;_restage();});
    }
  }
  bool _tapGhost(double time){
    if(_action!=null||_adding||_removed.contains(active))return false;
    final original=_detected(_active);if(original==null)return false;
    final reach=controller.view.span*.025;
    if(original.start!=_active.start&&(time-original.start).abs()<reach){unawaited(_ghost(BlockEnd.start));return true;}
    if(original.end!=_active.end&&(time-original.end).abs()<reach){unawaited(_ghost(BlockEnd.end));return true;}
    return false;
  }
  @override
  void annotationTapped(String id){
    if(_adding&&id.startsWith('add-gap:')){
      final gap=_annotations.where((a)=>a.id==id).firstOrNull;
      if(gap!=null)_pick(gap.at);
      return;
    }
    if(id=='ghost:$active:start'){unawaited(_ghost(BlockEnd.start));return;}
    if(id=='ghost:$active:end'){unawaited(_ghost(BlockEnd.end));return;}
    for(final s in endSuggestions(d.movement,d.domainStart,_active)){
      if(id=='suggestion:${s.which.name}')_applyTime(s.which,s.at);
    }
  }
  List<TimelineView> get _availableGaps {
    final ordered=blocks.where((b)=>!_removed.contains(b.id)&&b.end>controller.home.start&&b.start<controller.home.end).toList()
      ..sort((a,b)=>a.start.compareTo(b.start));
    final gaps=<TimelineView>[];var cursor=controller.home.start;
    for(final block in ordered){
      final start=block.start.toDouble().clamp(controller.home.start,controller.home.end);
      if(start>cursor)gaps.add(TimelineView(cursor,start));
      if(block.end>cursor)cursor=block.end.toDouble().clamp(controller.home.start,controller.home.end);
    }
    if(cursor<controller.home.end)gaps.add(TimelineView(cursor,controller.home.end));
    return gaps;
  }
  List<ChartAnnotation> get _annotations{
    final a=_active, detected=_detected(a), scrub=controller.scrub;
    return [
      if(_adding)
        for(final (i,gap) in _availableGaps.indexed)
          if(_addStart==null||(_addStart!>=gap.start&&_addStart!<gap.end&&gap.end>=_addStart!+300))
            ChartAnnotation(id:'add-gap:$i',kind:AnnotationKind.review,
              at:_addStart==null?gap.start:(_addStart!+300).toDouble(),
              until:_addStart==null?gap.end:gap.end.clamp((_addStart!+300).toDouble(),(_addStart!+21600).toDouble()),
              label:_addStart==null?l.sleepEditorAddStart:l.sleepEditorAddEnd(_clock(_addStart!)),icon:LucideIcons.plus),
      if(!_adding&&_action==null&&!_removed.contains(a.id)&&detected!=null) ...[
        if(detected.start!=a.start)ChartAnnotation(id:'ghost:${a.id}:start',kind:AnnotationKind.mainSleep,
          at:detected.start.toDouble(),label:l.sleepEditorGhostStartTitle,icon:LucideIcons.undo2),
        if(detected.end!=a.end)ChartAnnotation(id:'ghost:${a.id}:end',kind:AnnotationKind.wake,
          at:detected.end.toDouble(),label:l.sleepEditorGhostEndTitle,icon:LucideIcons.undo2)],
      if(!_adding&&_action==null&&!_removed.contains(a.id)&&scrub!=null)
        for(final suggestion in endSuggestions(d.movement,d.domainStart,a))
          if((scrub-suggestion.at).abs()<=15*60)ChartAnnotation(id:'suggestion:${suggestion.which.name}',
            kind:suggestion.which==BlockEnd.start?AnnotationKind.mainSleep:AnnotationKind.wake,
            at:suggestion.at.toDouble(),label:l.sleepEditorSuggestedTime(_clock(suggestion.at))),
    ];
  }
  String _clock(int at)=>const AppClockText().of(at);
  Future<void> _save()async{
    if(_saving||_adding)return;
    final live=blocks.where((b)=>!_removed.contains(b.id)||b.kind==BlockKind.main).toList();
    final plan=_action==null?planOf(d,live):SleepEditPlan(day:d.day,entry:_action);
    if(plan.isEmpty){Navigator.of(context).pop();return;}
    _messages.currentState?.removeCurrentSnackBar();
    setState((){_saving=true;_saveError=null;});
    ({Future<void> written,Future<SleepOperationResult> done})? receipt;
    try{receipt=widget.save.save(plan);await receipt.written;}
    catch(error){unawaited(receipt?.done.then((_) {},onError:(_) {}));
      if(mounted)setState((){_saving=false;_saveError=l.sleepEditorSaveFailed;});return;}
    if(mounted)Navigator.of(context).pop(SleepEditorResult(receipt.done));
  }
  @override
  Widget build(BuildContext context){
    final p=P.of(context), a=_active;
    final annotations=_annotations;
    return ScaffoldMessenger(key:_messages,child:Scaffold(backgroundColor:p.bg,bottomNavigationBar:SafeArea(top:false,
      child:Padding(padding:const EdgeInsets.all(S.x3),child:Column(mainAxisSize:MainAxisSize.min,children:[Row(children:[
        Expanded(child:_styledButton(l.actionCancel,SleepTimelineEditor.cancelKey,
          _saving?null:()=>Navigator.of(context).pop(),color:C.n500)),
        const SizedBox(width:S.x2),Expanded(child:_styledButton(l.actionSave,SleepTimelineEditor.saveKey,
          _saving||_adding?null:_save,color:C.green,soft:false))])]))),
      body:SafeArea(child:Column(children:[
        NavBar(l.sleepEditorTitle,onBack:()=>Navigator.of(context).maybePop()),
        Expanded(child:SingleChildScrollView(key:const ValueKey('sleep-editor-scroll'),
          padding:const EdgeInsets.symmetric(horizontal:S.x3),child:Column(children:[
          Surface(key:const ValueKey('sleep-editor-chart-card'),pad:const EdgeInsets.all(S.x3),
            child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
              Text(l.sleepEditorYourSleep,style:F.head.copyWith(color:p.ink)),
              Text(MaterialLocalizations.of(context).formatMediumDate(DateTime.parse(d.day)),style:F.cap),
              DayTimelineChart(controller:controller,signalStart:d.domainStart.toDouble(),hr:d.hr,movement:d.movement,
                stages:stages,stagesArePreview:true,plotHeight:112,
                annotations:annotations,annotationListener:this,showAnnotationLabel:!_adding,
                emphasis:{for(final n in annotations)if(!n.id.startsWith('ghost:'))n.id},
                blocks:blocks,activeBlock:active,chooseBlock:_chooseEntry,
                blockLabels:{for(final b in blocks)b.id:_name(b)},
                blockSemanticLabels:{for(final b in blocks)b.id:_entryLabel(b)},
                blockEditingEnabled:!_saving&&_action==null&&!_adding&&!_removed.contains(active),
                pickTime:_adding?_pick:null,interceptTap:_tapGhost,listener:this,haptics:widget.haptics),
              _detail(p,a),
            ])),
          const SizedBox(height:S.x2),
          Surface(key:const ValueKey('sleep-editor-actions-card'),pad:const EdgeInsets.all(S.x3),
            child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
              Text(l.sleepEditorSelectedBlock(_name(a)),style:F.body.copyWith(color:p.ink)),
              if(_actionCancelled)Semantics(key:const ValueKey('sleep-editor-action-cancelled'),liveRegion:true,
                child:Text(l.sleepEditorActionCancelled,style:F.cap)),
              if(_action!=null)Semantics(key:const ValueKey('sleep-editor-pending-action'),liveRegion:true,
                child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text(switch(_action!.action){SleepEntryAction.stages=>l.sleepEditorCalculate,
                    SleepEntryAction.remove=>l.sleepEditorRemove,_=>_detected(a)==null?l.sleepEditorRestoreBlock:l.sleepEditorResetDetected},style:F.cap),
                  Text(l.sleepEditorActionEditReason,key:const ValueKey('sleep-editor-action-edit-reason'),style:F.cap)])),
              if(_dirty&&_action==null)Text(l.sleepEditorSaveTimesFirst,style:F.cap),
              _button('calculate',l.sleepEditorCalculate,
                _saving||_adding||_removed.contains(active)||_dirty||_original(active)==null?null:
                  ()=>setState(()=>_stage(SleepEntryAction.stages))),
              _button('detected',_removed.contains(active)&&_detected(a)==null?l.sleepEditorRestoreBlock:
                _removed.contains(active)&&a.kind==BlockKind.nap?l.sleepEditorRestoreNap:l.sleepEditorResetDetected,
                _saving||_adding||_otherDirty||_restore(a)==null||
                  (!_removed.contains(active)&&(_detected(a)==null||a==_detected(a)))?null:_resetDetected),
              _button('remove',l.sleepEditorRemove,
                _saving||_adding||_removed.contains(active)||_otherDirty||(_dirty&&_original(active)!=null)?null:_remove,color:C.red),
            ])),
          if(_saveError!=null)Semantics(liveRegion:true,child:Text(_saveError!,
            key:const ValueKey('sleep-editor-save-error'),style:F.cap.copyWith(color:p.on(C.red)))),
          const SizedBox(height:S.x2),
        ]))),
      ]))));
  }
  Widget _styledButton(String label,Key key,VoidCallback? tap,{Color color=C.blue,bool soft=true})=>
    TextButton(key:key,onPressed:tap,
      style:TextButton.styleFrom(padding:EdgeInsets.zero,minimumSize:const Size(48,48)),
      child:Semantics(label:label,excludeSemantics:true,child:Opacity(opacity:tap==null ? 0.4 : 1.0,
        child:BigButton(label,soft:soft,dense:true,color:color))));
  Widget _button(String id,String label,VoidCallback? tap,{Color color=C.blue})=>Padding(
    padding:const EdgeInsets.only(top:4),child:_styledButton(label,ValueKey('sleep-editor-$id'),tap,color:color));
  Widget _detail(P p,SleepBlock a){
    final totals=previewTotals(stages,d.domainStart,a);
    String minutes(int? value)=>value==null?'—':l.sleepEditorMinutes(value);
    final scrub=controller.scrub;
    final index=scrub==null?null:((scrub-d.domainStart)~/60);
    final hr=index==null||index<0||index>=d.hr.length?null:d.hr[index];
    final movement=index==null||index<0||index>=d.movement.length?null:d.movement[index];
    Widget stat(String label,String value)=>Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,
      children:[Text(label,style:F.over.copyWith(color:p.ink3)),Text(value,style:F.body.copyWith(color:p.ink))]));
    return Container(key:SleepTimelineEditor.readoutKey,padding:const EdgeInsets.all(S.x2),
      decoration:BoxDecoration(color:p.card2,borderRadius:R.rMd),
      child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        if(_adding) ...[
          Semantics(liveRegion:true,child:Text(_addStart==null?l.sleepEditorAddStart:l.sleepEditorAddEnd(_clock(_addStart!)),
            key:ValueKey(_addStart==null?'sleep-editor-add-start':'sleep-editor-add-end'),style:F.body)),
          TextButton(key:const ValueKey('sleep-editor-add-cancel'),onPressed:_cancelAdd,child:Text(l.actionCancel)),
        ]else ...[
          Row(children:[if(a.kind==BlockKind.nap)const Padding(padding:EdgeInsets.only(right:4),child:Icon(LucideIcons.bedDouble,size:16)),
            Expanded(child:Text('${_name(a)} · ${_clock(a.start)} – ${_clock(a.end)}',style:F.cap))]),
          if(!_removed.contains(active)) ...[
            Text(l.sleepEditorPreview,key:const ValueKey('sleep-editor-preview-label'),style:F.over.copyWith(color:p.on(C.orange))),
            const SizedBox(height:4),
            Row(children:_readoutScrub&&scrub!=null?[
              stat(l.sleepEditorHeartRate,hr==null?'—':'${hr.round()} bpm'),
              stat(l.sleepEditorMovement,movement==null?'—':'${(movement*100).round()}%'),
              stat(l.sleepEditorAt,_clock(scrub.round())),
            ]:[stat(l.sleepEditorDeep,minutes(totals.deepMin)),stat(l.sleepEditorRem,minutes(totals.remMin)),
              stat(l.sleepEditorLight,minutes(totals.lightMin))]),
          ],
          Wrap(alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,children:[
            TimelineZoomControls(controller:controller,singleButton:true,
              zoomLabel:l.sleepEditorZoomIn,resetLabel:l.sleepEditorResetZoom,
              zoomKey:const ValueKey('sleep-editor-zoom'),resetKey:SleepTimelineEditor.resetKey),
            TextButton.icon(key:SleepTimelineEditor.addKey,onPressed:_saving||_action!=null?null:
              ()=>setState((){_adding=true;_addStart=null;_saveError=null;controller.reset();}),
              icon:const Icon(LucideIcons.plus,size:16),label:Text(l.sleepEditorAddBlock)),
          ]),
        ],
      ]));
  }
  String _exactTime(int epoch){
    final time=DateTime.fromMillisecondsSinceEpoch(epoch*1000),offset=DateTime.fromMillisecondsSinceEpoch(epoch*1000).timeZoneOffset.inMinutes;
    return '${time.toIso8601String().split('.').first.replaceFirst('T',' ')} UTC${offset<0?'-':'+'}${(offset.abs()~/60).toString().padLeft(2,'0')}:${(offset.abs()%60).toString().padLeft(2,'0')}';
  }
  String _provenance(SleepBlock b)=>switch(_source(b)){
    'manual'=>l.sleepEditorSourceManual,'confirmed'=>l.sleepEditorSourceConfirmed,
    'legacy'=>l.sleepEditorSourceLegacy,'rejected'=>l.sleepEditorSourceRejected,
    null when _original(b.id)==null=>l.sleepEditorSourceDraft,
    _=>l.sleepEditorSourceAutomatic,
  };
  String _entryLabel(SleepBlock b)=>'${_name(b)} · ${l.sleepEditorEntryNumber(blocks.indexOf(b)+1)}\n${_provenance(b)}\n${_exactTime(b.start)} → ${_exactTime(b.end)}';
  Future<String?> _chooseEntry(List<SleepBlock> choices)=>showDialog<String>(context:context,
    builder:(c)=>SimpleDialog(key:const ValueKey('sleep-editor-entry-chooser'),title:Text(l.sleepEditorChooseEntry),
      children:[for(final b in choices)TextButton(key:ValueKey('sleep-editor-entry:${b.id}'),
        autofocus:b.id==active,style:TextButton.styleFrom(minimumSize:const Size(double.infinity,48)),
        onPressed:()=>Navigator.of(c).pop(b.id),child:Text(_entryLabel(b)))]));
}
