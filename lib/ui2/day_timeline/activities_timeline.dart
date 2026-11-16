// Activities on the shared timeline (pilot day-timeline spec §4).
//
// The chart replaces the two-thumb range slider. Under it, the day's list is
// a scrolling VIEWPORT synced to the scrub line both ways: scrubbing scrolls
// it to the item nearest the line (and highlights it), scrolling it moves the
// line to the item in the middle of the viewport, and tapping an item glides
// the line there. The items themselves are the app's own rows (repeat events
// collapsed, Keep / Discard / Edit under a row awaiting review), unchanged.
// Every decision is staged until Save; Cancel applies none of them.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../chart_annotations.dart';
import '../grammar.dart';
import '../screens/day_review.dart';
import '../screens/day_timeline.dart';
import '../screens/home_screen.dart' show clockOfTs;
import '../theme.dart';
import 'timeline_chart.dart';
import 'timeline_model.dart';

enum ActivityVisibility { pending, saved, discarded }

class ActivitiesTimeline extends StatefulWidget {
  const ActivitiesTimeline({
    super.key,
    required this.data,
    required this.rows,
    required this.review,
    required this.editor,
    this.annotationListener,
    this.initialScrub,
  });

  final TimelineData data;

  /// The day's rows (stored moments and rows awaiting review), in order.
  final List<({String id, Moment moment})> rows;
  final DayReviewController? review;
  final DayRowEditListener editor;
  final AnnotationListener? annotationListener;
  final double? initialScrub;

  static const listKey = ValueKey('activities-list');
  static const zoomKey = ValueKey('activities-zoom');
  static const resetKey = ValueKey('activities-reset');
  static const filterButtonKey = ValueKey('activities-filter');
  static ValueKey<String> itemKey(String id) => ValueKey('activities-item:$id');
  static ValueKey<String> restoreKey(String id) => ValueKey('activities-restore:$id');

  @override
  State<ActivitiesTimeline> createState() => ActivitiesTimelineState();
}

/// One line of the list: a row, a collapsed group, or a discarded item.
class ActivitiesItem {
  const ActivitiesItem(this.id, this.moment, {this.group, this.discarded = false});
  final String id;
  final Moment moment;
  final MomentGroup? group;
  final bool discarded;
}

class ActivitiesTimelineState extends State<ActivitiesTimeline> implements TimelineListener {
  late TimelineController controller;
  final list = ScrollController();
  final _keys = <String, GlobalKey>{};
  final _selectedKinds = <ActivityVisibility>{ActivityVisibility.pending,ActivityVisibility.saved};
  AppLocalizations get l=>AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));


  /// The item the line is on (highlighted).
  String? focus;

  /// True while the list is being scrolled by the line (not by the finger).
  bool _byLine = false;

  int get _dayStart => widget.data.graph.dayStart ?? 0;
  int get _slots => widget.data.graph.slots;

  @override
  void initState() {
    super.initState();
    controller = _controllerFor(widget.data);
    _lastScrub=controller.scrub;
    controller.addListener(_controllerChanged);
  }

  TimelineController _controllerFor(TimelineData d) {
    final s = (d.graph.dayStart ?? 0).toDouble();
    final e = s + d.graph.slots * 60;
    return TimelineController(domainStart: s, domainEnd: e, home: TimelineView(s, e),
        scrub: widget.initialScrub);
  }

  @override
  void didUpdateWidget(ActivitiesTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.day != widget.data.day ||
        oldWidget.data.graph.dayStart != widget.data.graph.dayStart) {
      final c = controller;
      c.removeListener(_controllerChanged);
      controller = _controllerFor(widget.data);
      _lastScrub=controller.scrub;
      controller.addListener(_controllerChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
    }
  }

  @override
  void dispose() {
    controller.removeListener(_controllerChanged);
    controller.dispose();
    list.dispose();
    super.dispose();
  }

  double? _lastScrub;

  // CLAIM(sleep-editor-stable-text): day-list text has no dependency on zoom
  // animation frames [day_timeline_activities_test].
  void _controllerChanged() {
    if (_lastScrub == controller.scrub) return;
    _lastScrub = controller.scrub;
    if (mounted) setState(() {});
  }

  bool _awaiting(String id) {
    final r = widget.review;
    return r != null && !r.loading && r.needsReview(id) && r.choice(id) == null;
  }

  ActivityVisibility _kind(String id)=>widget.review?.needsReview(id)==true
      ?ActivityVisibility.pending:ActivityVisibility.saved;

  List<ActivitiesItem> get items {
    final r = widget.review;
    final out = <ActivitiesItem>[];
    final visibleRows=[for(final x in widget.rows)
      if(_selectedKinds.contains(_kind(x.id)))x];
    {
      for (final g in groupRepeatedEvents([for (final x in visibleRows) x.moment])) {
        final row = widget.rows.firstWhere((x) => identical(x.moment, g.first));
        out.add(ActivitiesItem(row.id, row.moment, group: g.count > 1 || g.isWake ? g : null));
      }
    }
    if (_selectedKinds.contains(ActivityVisibility.discarded) && r != null) {
      for (final d in r.discardedRows(context)) {
        out.add(ActivitiesItem(d.id, d.moment, discarded: true));
      }
    }
    out.sort((a, b) => a.moment.at.compareTo(b.moment.at));
    return out;
  }

  // ── sync ──

  ActivitiesItem? _nearest(List<ActivitiesItem> xs, double t) {
    ActivitiesItem? best;
    for (final x in xs) {
      if (best == null || (x.moment.at - t).abs() < (best.moment.at - t).abs()) best = x;
    }
    return best;
  }

  @override
  void scrubbed(double t) {
    final near = _nearest(items, t);
    if (near == null) return;
    if (focus != near.id) setState(() => focus = near.id);
    _scrollTo(near.id, animate: false);
  }

  void _scrollTo(String id, {required bool animate}) {
    final ctx = _keys[id]?.currentContext;
    if (ctx == null) return;
    _byLine = true;
    Scrollable.ensureVisible(ctx,
            alignment: .5,
            duration: animate ? const Duration(milliseconds: 350) : Duration.zero,
            curve: Curves.easeInOut)
        .whenComplete(() => _byLine = false);
  }

  /// The finger scrolled the list: the line follows the item in its middle.
  bool _onScroll(ScrollNotification n) {
    if (_byLine || n is! ScrollUpdateNotification || n.dragDetails == null) return false;
    final viewport = context.findRenderObject();
    final listBox = (ActivitiesTimeline.listKey.currentContextOf(context))?.findRenderObject();
    if (viewport == null || listBox is! RenderBox) return false;
    final mid = listBox.localToGlobal(Offset(0, listBox.size.height / 2)).dy;
    String? best;
    double bestD = double.infinity;
    for (final e in _keys.entries) {
      final box = e.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final y = box.localToGlobal(Offset(0, box.size.height / 2)).dy;
      if ((y - mid).abs() < bestD) {
        bestD = (y - mid).abs();
        best = e.key;
      }
    }
    final x = best == null ? null : items.where((i) => i.id == best).firstOrNull;
    if (x == null) return false;
    controller.setScrub(x.moment.at.toDouble());
    final v = controller.view;
    if ((x.moment.at < v.start || x.moment.at > v.end) && !controller.animating) {
      controller.glideScrub(x.moment.at.toDouble());
    }
    if (focus != x.id) setState(() => focus = x.id);
    return false;
  }

  void _tapItem(ActivitiesItem x) {
    setState(() => focus = x.id);
    controller.glideScrub(x.moment.at.toDouble());
    _scrollTo(x.id, animate: true);
  }

  @override
  void blocksChanged(List<SleepBlock> blocks) {}
  @override
  void blockSelected(String id, {required bool zoom}) {}
  @override
  void dragEnded() {}

  // ── chart inputs ──

  List<ChartAnnotation> get _annotations {
    final r = widget.review;
    final stored = _selectedKinds.contains(ActivityVisibility.saved) ? dayAnnotations(widget.data.moments) : <ChartAnnotation>[];
    final waiting = [
      for (final x in widget.rows)
        if (r != null && r.needsReview(x.id) &&
            _selectedKinds.contains(_kind(x.id)))
          ChartAnnotation(
            id: x.id,
            kind: x.id.startsWith('activity:')
                ? (x.moment.icon == LucideIcons.bedDouble ? AnnotationKind.nap : AnnotationKind.workout)
                : x.id.startsWith('glass:') ? AnnotationKind.assumedWater : AnnotationKind.moment,
            at: x.moment.at.toDouble(),
            label: x.moment.title,
            icon: x.moment.icon,
          ),
    ];
    final discarded = _selectedKinds.contains(ActivityVisibility.discarded)&&r!=null
      ? [for(final x in r.discardedRows(context))ChartAnnotation(id:x.id,
          kind:x.moment.icon==LucideIcons.bedDouble?AnnotationKind.nap:AnnotationKind.workout,
          at:x.moment.at.toDouble(),until:x.moment.until?.toDouble(),label:x.moment.title,icon:x.moment.icon)]
      : <ChartAnnotation>[];
    return [...stored, ...waiting,...discarded];
  }

  /// Review emphasis: while items await review, they are bold and outlined
  /// and every other annotation is dimmed; with none left, no emphasis.
  Set<String>? get emphasis {
    final ids = {for (final x in widget.rows) if (_selectedKinds.contains(ActivityVisibility.pending)&&_awaiting(x.id)) x.id};
    return ids.isEmpty ? null : ids;
  }

  @override
  Widget build(BuildContext c) => _build(c);

  Widget _build(BuildContext c) {
    final p = P.of(c);
    final g = widget.data.graph;
    final hr = g.hr, mv = g.movement;
    final t = controller.scrub;
    final i = t == null ? null : ((t - _dayStart) ~/ 60).clamp(0, _slots - 1);
    final xs = items;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Surface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TimelineTitleRow('Your day'),
          const SizedBox(height: S.x2),
          DayTimelineChart(
            controller: controller,
            hr: hr,
            movement: mv,
            annotations: _annotations,
            emphasis: emphasis,
            annotationListener: widget.annotationListener,
            listener: this,
            plotHeight: 150,
          ),
          Container(key:const ValueKey('activities-scrub-detail'),
            margin: const EdgeInsets.only(top: S.x2),
            padding: const EdgeInsets.fromLTRB(S.x3, S.x2, S.x3, S.x2),
            decoration: BoxDecoration(color: p.card2, borderRadius: R.rLg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: Text(
                      (t == null ? 'Drag across the day' : 'Selected · ${clockOfTs(t.round())}')
                          .toUpperCase(),
                      style: F.over.copyWith(color: p.on(C.blue), fontWeight: FontWeight.w700,
                          letterSpacing: .6)),
                ),
                ListenableBuilder(listenable:controller,builder:(context,child)=>
                  controller.zoomSelection==null?const SizedBox.shrink():
                    Text('choosing zoom',style:F.over.copyWith(color:p.ink3))),
              ]),
              const SizedBox(height: S.x1),
              Wrap(spacing: S.x4, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('Heart rate ', style: F.cap.copyWith(color: p.ink3)),
                  Text(i == null || i >= hr.length || hr[i] == null ? '—' : '${hr[i]!.round()} bpm',
                      style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
                ]),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('Movement ', style: F.cap.copyWith(color: p.ink3)),
                  Text(i == null || i >= mv.length || mv[i] == null ? '—' : '${(mv[i]! * 100).round()}%',
                      style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
                ]),
              ]),
              const SizedBox(height: S.x2),
              Wrap(alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,children:[
                TimelineZoomControls(controller:controller,singleButton:true,
                  zoomLabel:l.sleepEditorZoomIn,resetLabel:l.sleepEditorResetZoom,
                  zoomKey:ActivitiesTimeline.zoomKey,resetKey:ActivitiesTimeline.resetKey),
                TextButton(key:ActivitiesTimeline.filterButtonKey,onPressed:_showFilter,
                  style:TextButton.styleFrom(minimumSize:const Size(48,48)),
                  child:Semantics(label:l.dayActivitiesFilterCount(_selectedKinds.length),excludeSemantics:true,
                    child:Row(mainAxisSize:MainAxisSize.min,children:[
                      Container(width:22,height:22,alignment:Alignment.center,
                        decoration:BoxDecoration(color:p.on(C.blue),shape:BoxShape.circle),
                        child:Text('${_selectedKinds.length}',style:F.cap.copyWith(color:p.card))),
                      const SizedBox(width:S.x2),Text(l.dayActivitiesFilter)]))),
              ]),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: S.x2),
      Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(S.x3, S.x1, S.x3, S.x1),
          decoration: BoxDecoration(color: p.card, borderRadius: R.rLg, boxShadow: p.el(1)),
          alignment: Alignment.topCenter,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: xs.isEmpty
                ? Center(child: Text(_selectedKinds.length==1&&_selectedKinds.contains(ActivityVisibility.discarded) ? 'Nothing discarded on this day'
                    : 'Nothing here', style: F.cap.copyWith(color: p.ink3)))
                : SingleChildScrollView(
                    key: ActivitiesTimeline.listKey,
                    controller: list,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final x in xs) _item(c, p, x),
                    ]),
                  ),
          ),
        ),
      ),
    ]);
  }

  void _toggleKind(ActivityVisibility kind,bool value){
    if(!mounted||(!value&&_selectedKinds.length==1&&_selectedKinds.contains(kind)))return;
    setState((){if(value){_selectedKinds.add(kind);}else{_selectedKinds.remove(kind);}});
  }
  Future<void> _showFilter() async {
    await showModalBottomSheet<void>(context:context,isScrollControlled:true,
      builder:(_)=>_ActivityFilterSheet(owner:this));
  }

  Widget _item(BuildContext c, P p, ActivitiesItem x) {
    final r = widget.review;
    final key = _keys.putIfAbsent(x.id, GlobalKey.new);
    final Widget body;
    if (x.group != null) {
      body = MomentGroupRow(x.group!);
    } else if (x.discarded) {
      final staged = r?.isRestoreStaged(x.id) == true;
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Opacity(
          opacity: staged ? 1 : .6,
          child: DefaultTextStyle.merge(
            style: TextStyle(decoration: staged ? null : TextDecoration.lineThrough),
            child: MomentRow(Moment(at: x.moment.at, title: x.moment.title,
                detail: staged ? 'Restored · unsaved' : 'Discarded',
                icon: x.moment.icon, color: x.moment.color)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: S.x2),
          child: reviewButton(c, ActivitiesTimeline.restoreKey(x.id).value,
              staged ? 'Restoring · undo' : 'Restore',
              r != null && r.canEdit ? () => r.toggleRestore(x.id) : null,
              selected: staged, glyph: LucideIcons.undo2),
        ),
      ]);
    } else if (DayReviewActions.shows(r, x.id, x.moment, widget.editor)) {
      final waiting = _awaiting(x.id);
      body = Container(
        margin: const EdgeInsets.symmetric(vertical: S.x1),
        padding: const EdgeInsets.symmetric(horizontal: S.x3),
        decoration: BoxDecoration(
          color: p.card2,
          borderRadius: R.rMd,
          // Review emphasis in the list too: an outline while it waits.
          border: Border.all(color: waiting ? p.on(C.orange) : Colors.transparent, width: 1.2),
        ),
        child: MomentRow(x.moment,
            below: DayReviewActions(controller: r, id: x.id, moment: x.moment, editor: widget.editor)),
      );
    } else {
      body = MomentRow(x.moment);
    }
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.translucent,
      onTap: () => _tapItem(x),
      child: AnimatedContainer(
        key: ActivitiesTimeline.itemKey(x.id),
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: focus == x.id ? p.wash(C.domMind) : Colors.transparent,
          borderRadius: R.rMd,
        ),
        child: body,
      ),
    );
  }
}

class _ActivityFilterSheet extends StatefulWidget {
  const _ActivityFilterSheet({required this.owner});
  final ActivitiesTimelineState owner;
  @override
  State<_ActivityFilterSheet> createState()=>_ActivityFilterSheetState();
}
class _ActivityFilterSheetState extends State<_ActivityFilterSheet> {
  @override
  Widget build(BuildContext context){
    final owner=widget.owner,l=owner.l;
    return SafeArea(child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,
      crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Padding(padding:const EdgeInsets.all(S.x4),child:Text(l.dayActivitiesShow,style:F.head)),
      for(final (kind,title,detail) in [
        (ActivityVisibility.pending,l.dayActivitiesPending,l.dayActivitiesPendingDetail),
        (ActivityVisibility.saved,l.dayActivitiesSaved,l.dayActivitiesSavedDetail),
        (ActivityVisibility.discarded,l.dayActivitiesDiscarded,l.dayActivitiesDiscardedDetail)])
        CheckboxListTile(key:ValueKey('activity-kind:${kind.name}'),title:Text(title),subtitle:Text(detail),
          value:owner._selectedKinds.contains(kind),
          onChanged:owner._selectedKinds.length==1&&owner._selectedKinds.contains(kind)?null:(value){
            owner._toggleKind(kind,value==true);setState((){});
          }),
    ])));
  }
}

extension on ValueKey<String> {
  BuildContext? currentContextOf(BuildContext root) {
    BuildContext? found;
    void visit(Element e) {
      if (found != null) return;
      if (e.widget.key == this) {
        found = e;
        return;
      }
      e.visitChildElements(visit);
    }
    root.visitChildElements(visit);
    return found;
  }
}

/// The pilot's Save bar: "N unsaved changes", Cancel and Save.
class ActivitiesSaveBar extends StatelessWidget {
  const ActivitiesSaveBar({super.key, required this.controller});
  final DayReviewController? controller;

  static const cancelKey = ValueKey('activities-cancel');
  static const saveKey = ValueKey('activities-save');
  static const countKey = ValueKey('activities-unsaved');

  Future<void> _cancel(BuildContext c, DayReviewController r) async {
    final ok = await showDialog<bool>(
      context: c,
      builder: (d) => AlertDialog(
        key: const ValueKey('activities-cancel-dialog'),
        scrollable: true,
        title: const Text('Cancel these changes?'),
        content: const Text('Nothing is deleted. Your Keep, Discard, Edit and Restore '
            'choices are just not applied.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep editing')),
          TextButton(
              key: const ValueKey('activities-cancel-confirm'),
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Cancel changes')),
        ],
      ),
    );
    if (ok == true) await r.cancelStaged();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c), r = controller;
    final n = r == null || r.loading ? 0 : r.stagedCount;
    final can = r != null && r.canEdit && r.hasChanges;
    return Container(
      decoration: BoxDecoration(color: p.card, border: Border(top: BorderSide(color: p.line))),
      padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x2),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
              children: [
            Text(n == 0 ? 'No changes' : '$n unsaved change${n == 1 ? '' : 's'}',
                key: countKey,
                style: F.body.copyWith(color: n == 0 ? p.ink3 : p.on(C.orange),
                    fontWeight: FontWeight.w600)),
            if (r?.saveFailed == true)
              Text('Could not save. Try again.', style: F.cap.copyWith(color: p.on(C.red))),
          ]),
        ),
        SizedBox(width: 96, child: reviewButton(c, cancelKey.value, 'Cancel',
            can ? () => _cancel(c, r) : null, color: C.n500)),
        const SizedBox(width: S.x2),
        SizedBox(width: 104, child: reviewButton(c, saveKey.value, 'Save',
            can ? () => r.save(c) : null, primary: true, glyph: LucideIcons.save)),
      ]),
    );
  }
}
