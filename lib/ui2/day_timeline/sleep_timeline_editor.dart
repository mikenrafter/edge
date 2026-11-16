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
import '../charts.dart' show Hypnogram, SleepStage, SleepStageX;
import '../grammar.dart';
import '../screens/day_timeline.dart' show DayGraph, dayGraph;
import '../theme.dart';
import 'preview_stager.dart';
import 'timeline_chart.dart';
import 'timeline_model.dart';

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

  int get domainEnd => domainStart + hr.length * 60;

  /// The night read from the repository: two calendar days' minutes stitched
  /// from 8 PM to 8 PM, the main window (or [fallback] when there is none) and
  /// naps intersecting that calendar interval, including overlapping entries.
  static Future<SleepEditorData> load(LocalRepository repo, String day,
      {(int, int)? window, (int, int)? fallback, (int, int)? usual}) async {
    final d = DateTime.parse(day);
    final prev = dayLabelOf(DateTime(d.year, d.month, d.day - 1));
    final baseStart = DateTime(d.year, d.month, d.day - 1, 20).millisecondsSinceEpoch ~/ 1000;
    final baseEnd = DateTime(d.year, d.month, d.day, 20).millisecondsSinceEpoch ~/ 1000;
    final w = window ?? fallback ??
        (DateTime(d.year, d.month, d.day - 1, 23).millisecondsSinceEpoch ~/ 1000,
            DateTime(d.year, d.month, d.day, 7).millisecondsSinceEpoch ~/ 1000);
    final night = await repo.getDaySleepV2(day);
    final graphs = <DayGraph>[];
    final naps = <SleepBlock>[];
    final sources = <String, String>{};
    for (final date in [prev, day]) {
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
        mainSource: night['sleep_source'] as String?, naps: naps,
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

class SleepTimelineEditorState extends State<SleepTimelineEditor> implements TimelineListener {
  late final TimelineController controller;
  late List<SleepBlock> blocks = [widget.data.main, ...widget.data.naps];
  String active = 'main';
  bool _askSide = false, _saving = false, _readoutScrub = false;
  String? _saveError;
  ({String id, SleepEntryEdit edit})? _action;
  SleepEntryEdit? get _entry => _action?.edit;
  bool _actionCancelled = false;
  double? _lastScrub;
  late List<SleepStage?> stages;
  int _napSeq = 0;

  /// The last preview update's cost, microseconds (the report reads it).
  int lastStageMicros = 0;

  SleepEditorData get d => widget.data;

  @override
  void initState() {
    super.initState();
    // CLAIM(sleep-editor-night-region): home is the exact union extent of
    // the main window and every nap [sleep_editor_fixes_test].
    controller = TimelineController(
      domainStart: _nightRegion.start < d.domainStart ? _nightRegion.start : d.domainStart.toDouble(),
      domainEnd: _nightRegion.end > d.domainEnd ? _nightRegion.end : d.domainEnd.toDouble(),
      home: _nightRegion,
      scrub: widget.initialScrub,
    );
    _lastScrub = controller.scrub;
    controller.addListener(_controllerChanged);
    _readoutScrub = widget.initialScrub != null;
    _restage();
  }

  @override
  void dispose() {
    controller.removeListener(_controllerChanged);
    controller.dispose();
    super.dispose();
  }

  TimelineView get _nightRegion {
    var start = blocks.first.start, end = blocks.first.end;
    for (final b in blocks.skip(1)) {
      if (b.start < start) start = b.start;
      if (b.end > end) end = b.end;
    }
    return TimelineView(start.toDouble(), end.toDouble());
  }

  // CLAIM(sleep-editor-stable-text): zoom ticks repaint only the chart.
  // Text changes only when its scrub value changes [sleep_editor_fixes_test].
  void _controllerChanged() {
    if (_lastScrub == controller.scrub) {
      return;
    }
    _lastScrub = controller.scrub;
    if (mounted) setState(() {});
  }

  void _restage() {
    final sw = Stopwatch()..start();
    stages = previewStages(domainStart: d.domainStart, hr: d.hr, movement: d.movement, blocks: blocks);
    lastStageMicros = sw.elapsedMicroseconds;
  }

  SleepBlock get _active => blocks.firstWhere((b) => b.id == active);

  @override
  void blocksChanged(List<SleepBlock> b) {
    // Staged entry actions and time edits are exclusive. The chart and
    // suggestions disable editing, and this guard covers other callers.
    if (_action != null || _saving) return;
    setState(() {
      blocks = b;
      controller.home = _nightRegion;
      _readoutScrub = false;
      _restage();
    });
  }

  void _cancelEntryAction({bool announce = false}) {
    if (_action == null) return;
    _action = null;
    if (announce) _actionCancelled = true;
  }

  @override
  void blockSelected(String id, {required bool zoom}) {
    if (_saving || !blocks.any((b) => b.id == id)) return;
    setState(() {
      // CLAIM(sleep-editor-visible-action): a different entry cancels the
      // unsaved action; scrub/zoom/same-entry selection keep it visible
      // [sleep_editor_review_r1_test].
      if (id != active) _cancelEntryAction(announce: true);
      active = id;
      _readoutScrub = false;
    });
  }

  @override
  void scrubbed(double t) {
    if (!_readoutScrub) setState(() => _readoutScrub = true);
  }

  @override
  void dragEnded() {}

  void _addNap(bool before) {
    if (_saving) return;
    final nap = placeNap(blocks, before: before, domainStart: d.domainStart,
        domainEnd: d.domainEnd, id: 'new:${_napSeq++}');
    setState(() => _askSide = false);
    if (nap == null) return;
    setState(() {
      blocks = [...blocks, nap];
      controller.home = _nightRegion;
      _cancelEntryAction(announce: true);
      active = nap.id;
      _readoutScrub = false;
      _restage();
    });
    final main = blocks.firstWhere((b) => b.kind == BlockKind.main);
    controller.glideTo(before
        ? TimelineView(d.domainStart.toDouble(), main.start + 1800.0)
        : TimelineView(main.end - 1800.0, d.domainEnd.toDouble()));
  }

  void _doneNap() {
    blockSelected('main', zoom: false);
    controller.reset();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_action != null && _action!.id != active) {
      setState(() => _cancelEntryAction(announce: true));
      return;
    }
    final plan = _entry == null ? planOf(d, blocks) : SleepEditPlan(day: d.day, entry: _entry);
    if (plan.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    ({Future<void> written, Future<SleepOperationResult> done})? receipt;
    try {
      receipt = widget.save.save(plan);
      await receipt.written;
    } catch (e) {
      // Not written: the edits stay on screen to try again.
      unawaited(receipt?.done.then((_) {}, onError: (_) {}));
      if (mounted) setState(() => (_saving = false, _saveError = '$e'));
      return;
    }
    if (mounted) Navigator.of(context).pop(SleepEditorResult(receipt.done));
  }

  String _clock(int t) => const AppClockText().of(t);

  List<ChartAnnotation> get _annotations => [
        if (d.usualBed case final b?)
          ChartAnnotation(id: 'usual-bed', kind: AnnotationKind.mainSleep,
              at: b.toDouble(), label: 'Usual bed', icon: LucideIcons.bed),
        if (d.usualWake case final w?)
          ChartAnnotation(id: 'usual-wake', kind: AnnotationKind.wake,
              at: w.toDouble(), label: 'Usual wake'),
      ];

  @override
  Widget build(BuildContext c) => _build(c);

  Widget _build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final a = _active;
    final isNap = a.kind == BlockKind.nap;
    final night = DateTime.parse(d.day);
    final from = DateTime(night.year, night.month, night.day - 1);
    final span = '${MaterialLocalizations.of(c).formatMediumDate(from)} → '
        '${MaterialLocalizations.of(c).formatMediumDate(night)}';
    return Scaffold(
      backgroundColor: p.bg,
      bottomNavigationBar: _action == null ? null : _pendingActionBar(c),
      body: SafeArea(
        child: Column(children: [
          NavBar(l.sleepEditorTitle, onBack: () => Navigator.of(c).maybePop()),
          if (_actionCancelled)
            Semantics(key: const ValueKey('sleep-editor-action-cancelled'), liveRegion: true,
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x2),
                child: Text(l.sleepEditorActionCancelled, style: F.cap.copyWith(color: p.ink)))),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x6), children: [
              Surface(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  TimelineTitleRow('Your sleep', pills: [
                    TimelinePill('Add sleep block', key: SleepTimelineEditor.addKey, icon: LucideIcons.plus,
                        on: _askSide, onTap: () => setState(() => _askSide = !_askSide)),
                  ]),
                  Text(span, style: F.over.copyWith(color: p.ink3)),
                  TextButton.icon(key: const ValueKey('sleep-editor-choose-entry'),
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () async {
                      final id = await _chooseEntry(blocks);
                      if (mounted && id != null) blockSelected(id, zoom: false);
                    },
                    icon: const Icon(LucideIcons.list, size: 18), label: Text(l.sleepEditorChooseEntry)),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    Expanded(child: TimelineZoomControls(controller: controller,
                      zoomLabel: l.sleepEditorZoom, resetLabel: l.sleepEditorResetZoom,
                      zoomKey: const ValueKey('sleep-editor-zoom'),
                      resetKey: SleepTimelineEditor.resetKey)),
                  ]),
                  if (_askSide)
                    _Banner(
                      text: 'Before or after the main sleep?',
                      actions: [
                        ('Before', () => _addNap(true)),
                        ('After', () => _addNap(false)),
                      ],
                    ),
                  if (isNap && _action == null)
                    _Banner(text: 'Adjusting nap: drag its ends', actions: [('Done', _doneNap)]),
                  const SizedBox(height: S.x2),
                  DayTimelineChart(
                    controller: controller,
                    hr: d.hr,
                    movement: d.movement,
                    stages: stages,
                    stagesArePreview: true,
                    annotations: _annotations,
                    blocks: blocks,
                    activeBlock: active,
                    chooseBlock: _chooseEntry,
                    blockEditingEnabled: _action == null && !_saving,
                    listener: this,
                    haptics: widget.haptics,
                  ),
                  RepaintBoundary(child: _readout(c, p, a)),
                  if (_action == null) Padding(
                    padding: const EdgeInsets.only(top: S.x2),
                    child: Text(
                        'Drag an end: it moves in 5-minute steps; hold still a moment and it '
                        'switches to single minutes. Drag elsewhere to read that moment.',
                        style: F.over.copyWith(color: p.ink3, height: 1.4)),
                  ),
                ]),
              ),
              const SizedBox(height: S.x3),
              _entryActions(c, a),
              const SizedBox(height: S.x3),
              _suggestions(c, p, a),
              if (_saveError != null)
                Padding(
                  padding: const EdgeInsets.only(top: S.x2),
                  child: Text('Not saved: $_saveError',
                      key: const ValueKey('sleep-editor-save-error'),
                      style: F.cap.copyWith(color: p.on(C.red))),
                ),
              const SizedBox(height: S.x3),
              if (_action == null) Row(children: [
                Expanded(
                    child: BigButton(l.actionCancel, key: SleepTimelineEditor.cancelKey, soft: true,
                        color: C.n500, dense: true, onTap: () => Navigator.of(c).pop())),
                const SizedBox(width: S.x2),
                Expanded(
                    child: BigButton(l.actionSave, key: SleepTimelineEditor.saveKey, dense: true,
                        color: C.green, onTap: _save)),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  String _entryKind(AppLocalizations l, SleepBlock block) =>
      block.kind == BlockKind.main ? l.sleepEditorMainEntry : l.sleepEditorNapEntry;

  String _provenance(AppLocalizations l, SleepBlock block) {
    if (![d.main, ...d.naps].any((b) => b.id == block.id)) return l.sleepEditorSourceDraft;
    final source = block.kind == BlockKind.main ? d.mainSource : d.napSources[block.id];
    return switch (source) {
      'manual' => l.sleepEditorSourceManual,
      'confirmed' => l.sleepEditorSourceConfirmed,
      'legacy' => l.sleepEditorSourceLegacy,
      'rejected' => l.sleepEditorSourceRejected,
      'auto' || 'auto_fallback' => l.sleepEditorSourceAutomatic,
      null when block.kind == BlockKind.nap => l.sleepEditorSourceAutomatic,
      _ => l.sleepEditorSourceUnknown,
    };
  }

  String _exactTime(int epoch) {
    final local = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    final offset = local.timeZoneOffset.inMinutes;
    final hours = (offset.abs() ~/ 60).toString().padLeft(2, '0');
    final minutes = (offset.abs() % 60).toString().padLeft(2, '0');
    final dateTime = local.toIso8601String().split('.').first.replaceFirst('T', ' ');
    return '$dateTime UTC${offset < 0 ? '-' : '+'}$hours:$minutes';
  }

  Future<String?> _chooseEntry(List<SleepBlock> choices) {
    final l = AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('en'));
    return showDialog<String>(context: context, builder: (dialog) => SimpleDialog(
      key: const ValueKey('sleep-editor-entry-chooser'), title: Text(l.sleepEditorChooseEntry),
      children: [for (final block in choices)
        Semantics(selected: block.id == active,
          child: TextButton(key: ValueKey('sleep-editor-entry:${block.id}'),
            autofocus: block.id == active,
            style: TextButton.styleFrom(minimumSize: const Size(double.infinity, 48),
              alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3)),
            onPressed: () => Navigator.of(dialog).pop(block.id),
            child: Text('${_entryKind(l, block)} · ${l.sleepEditorEntryNumber(blocks.indexWhere((b) => b.id == block.id) + 1)}'
              '\n${_provenance(l, block)}\n${_exactTime(block.start)} →\n${_exactTime(block.end)}'),
          )),
      ],
    ));
  }

  Widget _pendingActionBar(BuildContext c) {
    final l = AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final action = _action!;
    final block = blocks.firstWhere((b) => b.id == action.id);
    final label = switch (action.edit.action) {
      SleepEntryAction.recalculate => l.sleepEditorRecalculate,
      SleepEntryAction.automatic => l.sleepDetailBackToAutomatic,
      SleepEntryAction.notSleep => l.sleepDetailNotSleep,
    };
    return SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(S.x3),
      child: Surface(key: const ValueKey('sleep-editor-pending-action'),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('$label · ${_entryKind(l, block)} · ${l.sleepEditorEntryNumber(blocks.indexWhere((b) => b.id == block.id) + 1)}', style: F.body.copyWith(color: P.of(c).ink)),
          Text('${_provenance(l, block)} · ${_clock(action.edit.start)} – ${_clock(action.edit.end)}', style: F.cap),
          Semantics(key: const ValueKey('sleep-editor-action-edit-reason'), liveRegion: true,
            child: Text(l.sleepEditorActionEditReason, style: F.cap)),
          const SizedBox(height: S.x2),
          Row(children: [
            Expanded(child: BigButton(l.actionCancel, key: SleepTimelineEditor.cancelKey, soft: true,
              dense: true, color: C.n500, onTap: _saving ? null : () => setState(_cancelEntryAction))),
            const SizedBox(width: S.x2),
            Expanded(child: BigButton(l.actionSave, key: SleepTimelineEditor.saveKey,
              dense: true, color: C.green, onTap: _save)),
          ]),
        ]),
      ),
    ));
  }

  Widget _entryActions(BuildContext c, SleepBlock block) {
    final l = AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    final original = [d.main, ...d.naps].where((b) => b.id == block.id).firstOrNull;
    if (original == null) return const SizedBox.shrink();
    final main = original.kind == BlockKind.main;
    final source = main ? d.mainSource : d.napSources[original.id];
    // Legacy history is persisted/owned for writer validation, but only an
    // explicit override or rejection can be restored to automatic.
    // CLAIM(sleep-editor-legacy) [sleep_editor_legacy_contract_test].
    final mine = switch (source) {
      'manual' || 'confirmed' || 'rejected' => true,
      _ => false,
    };
    void stage(SleepEntryAction action) => setState(() {
      _actionCancelled = false;
      _action = (id: original.id, edit: SleepEntryEdit(start: original.start, end: original.end,
          main: main, source: source, action: action));
    });
    final dirty = !planOf(d, blocks).isEmpty;
    return Surface(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(main ? l.sleepEditorMainEntry : l.sleepEditorNapEntry,
          style: F.head.copyWith(color: P.of(c).ink)),
      Text('${_clock(original.start)} – ${_clock(original.end)}', style: F.cap),
      if (dirty) Text(l.sleepEditorSaveTimesFirst, style: F.cap),
      TextButton(onPressed: dirty || _saving ? null : () => stage(
          mine ? SleepEntryAction.automatic : SleepEntryAction.recalculate),
        child: Text(mine ? l.sleepDetailBackToAutomatic : l.sleepEditorRecalculate)),
      if (source != 'rejected') TextButton(
        onPressed: dirty || _saving ? null : () => stage(SleepEntryAction.notSleep),
        child: Text(l.sleepDetailNotSleep)),

    ]));
  }

  Widget _readout(BuildContext c, P p, SleepBlock a) {
    final cols = Hypnogram.cols(p);
    Widget cell(String k, String v, {Color? dot}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (dot != null) ...[
                Container(width: 8, height: 8,
                    decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                const SizedBox(width: 5),
              ],
              Flexible(child: Text(k, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: F.over.copyWith(color: p.ink3))),
            ]),
            const SizedBox(height: 2),
            Text(v, style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
          ],
        );
    final String head;
    final List<Widget> cells;
    final t = controller.scrub;
    if (_readoutScrub && t != null) {
      final i = ((t - d.domainStart) ~/ 60).clamp(0, d.hr.length - 1);
      final e = ((t - d.domainStart) ~/ kPreviewEpochSec).clamp(0, stages.length - 1);
      final s = stages[e];
      head = 'Selected · ${_clock(t.round())}';
      cells = [
        cell('Heart rate', d.hr[i] == null ? '—' : '${d.hr[i]!.round()} bpm', dot: p.on(C.red)),
        cell('Movement', d.movement[i] == null ? '—' : '${(d.movement[i]! * 100).round()}%',
            dot: p.on(C.purple)),
        cell('Stage · preview', s == null ? '—' : s.label(), dot: s == null ? p.line : cols[s]),
      ];
    } else {
      final tot = previewTotals(stages, d.domainStart, a);
      String hm(int? m) => m == null ? '—' : '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
      head = '${a.kind == BlockKind.main ? 'Main sleep' : 'Nap'} · '
          '${_clock(a.start)} – ${_clock(a.end)}';
      cells = [
        cell('Cycles · preview', tot.cycles == null ? '—' : '≈${tot.cycles}'),
        cell('Deep', hm(tot.deepMin), dot: cols[SleepStage.deep]),
        cell('REM', hm(tot.remMin), dot: cols[SleepStage.rem]),
        cell('Light', hm(tot.lightMin), dot: cols[SleepStage.light]),
        cell('Wake-ups', tot.wakeUps == null ? '—' : '${tot.wakeUps}', dot: cols[SleepStage.awake]),
        cell('Naps', '${blocks.where((b) => b.kind == BlockKind.nap).length}'),
      ];
    }
    return Container(
      key: SleepTimelineEditor.readoutKey,
      margin: const EdgeInsets.only(top: S.x2),
      padding: const EdgeInsets.fromLTRB(S.x3, S.x3, S.x3, S.x3),
      decoration: BoxDecoration(color: p.card2, borderRadius: R.rLg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (a.kind == BlockKind.nap) ...[
            Icon(annotationIcon(AnnotationKind.nap), size: 18, color: p.on(C.indigo)),
            const SizedBox(width: S.x2),
          ],
          Expanded(
            child: Text(head.toUpperCase(),
                style: F.over.copyWith(color: p.on(C.blue), fontWeight: FontWeight.w700,
                    letterSpacing: .6)),
          ),
          _PreviewTag(p: p),
        ]),
        const SizedBox(height: S.x2),
        // Two rows of three in both modes, so the panel keeps its height.
        for (var r = 0; r < 2; r++)
          Padding(
            padding: EdgeInsets.only(top: r == 0 ? 0 : S.x2),
            child: Row(children: [
              for (var k = 0; k < 3; k++)
                Expanded(child: r * 3 + k < cells.length ? cells[r * 3 + k]
                    : Opacity(opacity: 0, child: cell(' ', ' '))),
            ]),
          ),
      ]),
    );
  }

  Widget _suggestions(BuildContext c, P p, SleepBlock a) {
    final s = endSuggestions(d.movement, d.domainStart, a);
    return Surface(
      key: const ValueKey('sleep-editor-suggestions'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic,
            children: [
          Expanded(child: Text('Suggested times', style: F.head.copyWith(color: p.ink))),
          Text('from your signals', style: F.over.copyWith(color: p.ink3)),
        ]),
        const SizedBox(height: S.x1),
        if (s.isEmpty)
          _why(p, LucideIcons.info,
              d.movement.any((v) => v != null)
                  ? 'No clear changes near these ends'
                  : 'No movement recorded to suggest times', null, null)
        else
          for (final x in s)
            _why(
              p,
              x.which == BlockEnd.start ? LucideIcons.moon : LucideIcons.sun,
              '${x.which == BlockEnd.start ? (a.kind == BlockKind.main ? 'Fell asleep' : 'Nap started') : 'Woke'}'
                  ' at ${_clock(x.at)}?',
              x.reason == SuggestionReason.movementSettled
                  ? 'Movement settled here'
                  : 'Movement rose here',
              _action != null || _saving ? null : () => blocksChanged(moveBlockEnd(blocks, a.id, x.which, x.at,
                  domainStart: d.domainStart, domainEnd: d.domainEnd)),
              key: ValueKey('sleep-editor-suggestion:${x.which.name}'),
            ),
      ]),
    );
  }

  Widget _why(P p, IconData icon, String title, String? why, VoidCallback? use, {Key? key}) =>
      Pressable(
        key: key,
        onTap: use,
        semanticLabel: use == null ? title : '$title Use',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x2),
          child: Row(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
              alignment: Alignment.center,
              child: Icon(icon, size: 15, color: p.on(C.green)),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: F.body.copyWith(color: p.ink)),
                if (why != null) Text(why, style: F.over.copyWith(color: p.ink3)),
              ]),
            ),
            if (use != null)
              Text('Use', style: F.cap.copyWith(color: p.on(C.green), fontWeight: FontWeight.w700)),
          ]),
        ),
      );
}

class _PreviewTag extends StatelessWidget {
  const _PreviewTag({required this.p});
  final P p;
  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('preview-label'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: p.wash(C.orange), borderRadius: R.rPill),
        child: Text('PREVIEW',
            style: F.over.copyWith(color: p.on(C.orange), fontWeight: FontWeight.w800,
                fontSize: 9, letterSpacing: .5)),
      );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.actions});
  final String text;
  final List<(String, VoidCallback)> actions;
  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return Container(
      margin: const EdgeInsets.only(top: S.x2),
      padding: const EdgeInsets.fromLTRB(S.x3, S.x1, S.x1, S.x1),
      decoration: BoxDecoration(color: p.wash(C.orange), borderRadius: R.rMd),
      child: Row(children: [
        Expanded(child: Text(text, style: F.cap.copyWith(color: p.on(C.orange)))),
        for (final (label, tap) in actions)
          TextButton(
            key: ValueKey('sleep-editor-banner:$label'),
            onPressed: tap,
            child: Text(label, style: F.cap.copyWith(color: p.ink, fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }
}
