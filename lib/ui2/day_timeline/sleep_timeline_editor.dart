// The sleep timeline editor, "Not sure?" (pilot day-timeline spec §3).
//
// The shared timeline over the night (default 8 PM -> 12 PM; the data runs 24
// hours, 8 PM to 8 PM, for naps). Exactly one block is active and has
// handles; every other block is a labelled band. Blocks never overlap. The
// stage wave and the readout's totals come from the PREVIEW stager and say
// so; Save stores the window and naps durably and the full calculation
// stages the night afterwards.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/day_label.dart';
import '../../data/local_repository.dart';
import '../../data/sleep_edit_write.dart';
import '../../state/control_operations.dart' show SleepOperationResult;
import '../chart_annotations.dart';
import '../charts.dart' show Hypnogram, SleepStage, SleepStageX;
import '../grammar.dart';
import '../screens/day_timeline.dart' show dayGraph;
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
    this.naps = const [],
    this.napSources = const {},
    this.usualBed,
    this.usualWake,
  });

  /// The night, by its wake date.
  final String day;

  /// 8 PM the evening before, epoch seconds; the data runs 24 hours on.
  final int domainStart;
  final List<double?> hr, movement;
  final SleepBlock main;
  final List<SleepBlock> naps;

  /// A stored nap's `source` by block id (absent: a detected nap).
  final Map<String, String> napSources;
  final int? usualBed, usualWake;

  int get domainEnd => domainStart + hr.length * 60;

  /// The night read from the repository: two calendar days' minutes stitched
  /// from 8 PM to 8 PM, the main window (or [fallback] when there is none) and
  /// the naps inside the 24 hours.
  static Future<SleepEditorData> load(LocalRepository repo, String day,
      {(int, int)? window, (int, int)? fallback, (int, int)? usual}) async {
    final d = DateTime.parse(day);
    final prev = dayLabelOf(DateTime(d.year, d.month, d.day - 1));
    final start = DateTime(d.year, d.month, d.day - 1, 20).millisecondsSinceEpoch ~/ 1000;
    final hr = List<double?>.filled(1440, null), mv = List<double?>.filled(1440, null);
    final naps = <SleepBlock>[];
    final sources = <String, String>{};
    for (final date in [prev, day]) {
      final g = dayGraph(await repo.getDayTimeline(date));
      final s = g.dayStart;
      if (s != null) {
        for (var i = 0; i < 1440; i++) {
          final m = (start + i * 60 - s) ~/ 60;
          if (m < 0 || m >= g.slots) continue;
          if (m < g.hr.length && g.hr[m] != null) hr[i] = g.hr[m];
          if (m < g.movement.length && g.movement[m] != null) mv[i] = g.movement[m];
        }
      }
      final n = await repo.getDayNaps(date);
      for (final x in (n['naps'] as List?) ?? const []) {
        if (x is! Map) continue;
        final a = x['start'] as int, b = x['end'] as int;
        if (b <= start || a >= start + 86400) continue;
        final id = 'nap:$a';
        naps.add(SleepBlock(id, BlockKind.nap, a, b));
        if (x['source'] != null) sources[id] = x['source'] as String;
      }
    }
    final w = window ?? fallback ??
        (DateTime(d.year, d.month, d.day - 1, 23).millisecondsSinceEpoch ~/ 1000,
            DateTime(d.year, d.month, d.day, 7).millisecondsSinceEpoch ~/ 1000);
    final main = SleepBlock('main', BlockKind.main, w.$1, w.$2);
    return SleepEditorData(day: day, domainStart: start, hr: hr, movement: mv,
        main: main,
        naps: [for (final n in naps) if (n.end <= main.start || n.start >= main.end) n],
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
  late List<SleepStage?> stages;
  int _napSeq = 0;

  /// The last preview update's cost, microseconds (the report reads it).
  int lastStageMicros = 0;

  SleepEditorData get d => widget.data;

  @override
  void initState() {
    super.initState();
    // 8 PM -> 12 PM by default (16 hours of the 24).
    controller = TimelineController(
      domainStart: d.domainStart.toDouble(),
      domainEnd: d.domainEnd.toDouble(),
      home: TimelineView(d.domainStart.toDouble(), d.domainStart + 16 * 3600.0),
      scrub: widget.initialScrub,
    );
    _readoutScrub = widget.initialScrub != null;
    _restage();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _restage() {
    final sw = Stopwatch()..start();
    stages = previewStages(domainStart: d.domainStart, hr: d.hr, movement: d.movement, blocks: blocks);
    lastStageMicros = sw.elapsedMicroseconds;
  }

  SleepBlock get _active => blocks.firstWhere((b) => b.id == active);

  @override
  void blocksChanged(List<SleepBlock> b) => setState(() {
        blocks = b;
        _readoutScrub = false;
        _restage();
      });

  @override
  void blockSelected(String id, {required bool zoom}) => setState(() {
        active = id;
        _readoutScrub = false;
      });

  @override
  void scrubbed(double t) {
    if (!_readoutScrub) setState(() => _readoutScrub = true);
  }

  @override
  void dragEnded() {}

  void _addNap(bool before) {
    final nap = placeNap(blocks, before: before, domainStart: d.domainStart,
        domainEnd: d.domainEnd, id: 'new:${_napSeq++}');
    setState(() => _askSide = false);
    if (nap == null) return;
    setState(() {
      blocks = [...blocks, nap];
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
    setState(() => active = 'main');
    controller.reset();
  }

  Future<void> _save() async {
    if (_saving) return;
    final plan = planOf(d, blocks);
    if (plan.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final r = widget.save.save(plan);
    try {
      await r.written;
    } catch (e) {
      // Not written: the edits stay on screen to try again.
      unawaited(r.done.then((_) {}, onError: (_) {}));
      if (mounted) setState(() => (_saving = false, _saveError = '$e'));
      return;
    }
    if (mounted) Navigator.of(context).pop(SleepEditorResult(r.done));
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
  Widget build(BuildContext c) => AnimatedBuilder(
    animation: controller,
    builder: (c, _) => _build(c),
  );

  Widget _build(BuildContext c) {
    final p = P.of(c);
    final a = _active;
    final isNap = a.kind == BlockKind.nap;
    final night = DateTime.parse(d.day);
    final from = DateTime(night.year, night.month, night.day - 1);
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final span = '${wd[from.weekday - 1]} ${from.day} → ${wd[night.weekday - 1]} '
        '${night.day} ${mo[night.month - 1]}';
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          NavBar('Sleep timeline', onBack: () => Navigator.of(c).maybePop()),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x6), children: [
              Surface(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  TimelineTitleRow('Your sleep', subtitle: span, pills: [
                    TimelinePill('Add sleep block', key: SleepTimelineEditor.addKey, icon: LucideIcons.plus,
                        on: _askSide, onTap: () => setState(() => _askSide = !_askSide)),
                    if (controller.zoomed)
                      TimelinePill('Reset zoom', key: SleepTimelineEditor.resetKey,
                          onTap: () {
                        setState(() => active = 'main');
                        controller.reset();
                      }),
                  ]),
                  if (_askSide)
                    _Banner(
                      text: 'Before or after the main sleep?',
                      actions: [
                        ('Before', () => _addNap(true)),
                        ('After', () => _addNap(false)),
                      ],
                    ),
                  if (isNap)
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
                    listener: this,
                    haptics: widget.haptics,
                  ),
                  _readout(c, p, a),
                  Padding(
                    padding: const EdgeInsets.only(top: S.x2),
                    child: Text(
                        'Drag an end: it moves in 5-minute steps; hold still a moment and it '
                        'switches to single minutes. Drag elsewhere to read that moment.',
                        style: F.over.copyWith(color: p.ink3, height: 1.4)),
                  ),
                ]),
              ),
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
              Row(children: [
                Expanded(
                    child: BigButton('Cancel', key: SleepTimelineEditor.cancelKey, soft: true,
                        color: C.n500, dense: true, onTap: () => Navigator.of(c).pop())),
                const SizedBox(width: S.x2),
                Expanded(
                    child: BigButton('Save', key: SleepTimelineEditor.saveKey, dense: true,
                        color: C.green, onTap: _save)),
              ]),
            ]),
          ),
        ]),
      ),
    );
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
              () => blocksChanged(moveBlockEnd(blocks, a.id, x.which, x.at,
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
