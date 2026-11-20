import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../data/import_progress.dart';
import '../l10n/app_localizations.dart';
import '../l10n/date_text.dart' show localizedDate;
import '../notify/notification_prefs.dart';
import '../pilot/pilot_flags.dart';
import '../settings/settings_repository.dart';
import '../state/app_state.dart';
import '../state/clock_format.dart';
import '../state/prefs.dart';
import 'calendar_day.dart';
import 'day_navigation.dart';
import 'grammar.dart' show Pressable;
import 'profile/profile.dart' show ProfileAvatar;
import 'status_line.dart';
import 'sync_control.dart';
import 'theme.dart';

const _avatar = ProfileAvatar(accent: C.greenD, diameter: 34);
const _gap = SizedBox(width: 8);
const _missing = '—';

Color headerBatteryColor(int percent, int alertAt) => switch (percent) {
  _ when percent < alertAt => C.syncWarning,
  _ when percent < alertAt + 10 => C.batteryAmber,
  >= 80 => C.green,
  >= 60 => C.batteryMint,
  _ => C.batteryGrey,
};

/// The shell owns one opening sequence, including across lazily built tabs.
class HomeHeaderOpening extends StatefulWidget {
  const HomeHeaderOpening({super.key, required this.child, this.play = true});
  final Widget child;
  final bool play;

  static bool enabledIn(BuildContext c) {
    c.dependOnInheritedWidgetOfExactType<_HeaderPilotRevision>();
    return PilotFlag.homeHeader.enabled;
  }

  @override
  State<HomeHeaderOpening> createState() => _HomeHeaderOpeningState();
}

class _HomeHeaderOpeningState extends State<HomeHeaderOpening>
    with SingleTickerProviderStateMixin {
  late final _opening = AnimationController(vsync: this, duration: Motion.syncOpening);
  final _downloadWindow = _DownloadWindow();
  HomeHeaderTab? _firstTab;

  bool _opensOn(HomeHeaderTab tab) => (_firstTab ??= tab) == tab;
  late final _openedAt = clock.now();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.play || !PilotFlag.homeHeader.enabled || !Motion.enabled(context)) {
      _opening.value = 1;
    } else if (_opening.isDismissed) {
      _opening.forward();
    }
  }

  @override
  void dispose() {
    _opening.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Opening(
    animation: _opening,
    openedAt: _openedAt,
    downloadWindow: _downloadWindow,
    opensOn: _opensOn,
    child: _HeaderPilotRevision(
      notifier: PilotFlags.revision,
      child: widget.child,
    ),
  );
}

class _HeaderPilotRevision extends InheritedNotifier<ValueNotifier<int>> {
  const _HeaderPilotRevision({required super.notifier, required super.child});
}

class _Opening extends InheritedWidget {
  const _Opening({
    required this.animation,
    required this.openedAt,
    required this.downloadWindow,
    required this.opensOn,
    required super.child,
  });
  final Animation<double> animation;
  final DateTime openedAt;
  final _DownloadWindow downloadWindow;
  final bool Function(HomeHeaderTab) opensOn;

  static _Opening? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Opening>();

  @override
  bool updateShouldNotify(_Opening oldWidget) => animation != oldWidget.animation;
}

({String word, IconData icon, Color color}) homeGreeting(int hour, AppLocalizations? l) {
  if (hour < 5) {
    return (word: l?.homeGreetingStillUp ?? 'Still up', icon: LucideIcons.moon, color: C.indigo);
  }
  if (hour < 12) {
    return (word: l?.homeGreetingMorning ?? 'Good morning', icon: LucideIcons.sun, color: C.yellow);
  }
  if (hour < 18) {
    return (word: l?.homeGreetingAfternoon ?? 'Good afternoon', icon: LucideIcons.sun, color: C.orange);
  }
  return (word: l?.homeGreetingEvening ?? 'Good evening', icon: LucideIcons.moon, color: C.indigo);
}

enum HomeHeaderTab { today, sleep, activity }

typedef _Band = ({
  SyncPresentationState sync,
  DateTime? heldEdge,
  DateTime? edge,
  bool? connected,
  int? battery,
});

class HomeHeader extends StatefulWidget {
  const HomeHeader({
    super.key,
    required this.tab,
    required this.day,
    required this.days,
    required this.onDay,
    this.dateLabel,
    this.labels = const {},
    this.now,
    this.greeting,
  });

  static const compactKey = 'ui.home_header_compact';
  static final compactRevision = ValueNotifier<int>(0);
  static bool get compact => Prefs.getBool(compactKey, false);

  static Future<bool> setCompact(bool value) async {
    final saved = await Prefs.setBoolAcked(compactKey, value);
    if (saved) compactRevision.value++;
    return saved;
  }

  final HomeHeaderTab tab;
  final String? day;
  final List<String> days;
  final ValueChanged<String> onDay;
  final String? dateLabel;
  final Map<String, String> labels;
  final DateTime? now;
  final String? greeting;

  @override
  State<HomeHeader> createState() => _HomeHeaderState();
}

class _HomeHeaderState extends State<HomeHeader> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this, duration: Motion.syncPhasePulse,
  );
  bool _expanded = false;
  final _standaloneDownloadWindow = _DownloadWindow();
  Timer? _downloadClock;
  late final _alertChanges =
      SettingsRepository.instance.changes.where((change) => change.alerts != null);

  void _tickDownload(bool active) {
    if (active) {
      _downloadClock ??= Timer.periodic(Motion.slowTick, (_) {
        if (mounted) setState(() {});
      });
    } else {
      _downloadClock?.cancel();
      _downloadClock = null;
    }
  }

  @override
  void dispose() {
    _downloadClock?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  void _toggle() => setState(() => _expanded = !_expanded);

  static _Band _readBand(AppState? app) => (
    sync: app?.syncPresentation ?? const SyncPresentationState(),
    heldEdge: app?.headerSyncedThrough,
    edge: app?.lastRecordAt,
    connected: app?.isConnected,
    battery: app?.device.batteryPct?.round(),
  );

  @override
  Widget build(BuildContext c) {
    final app = c.read<AppState?>();
    final band = c.select<AppState?, _Band>(_readBand);
    final listeners = Listenable.merge([
      app?.deriveProgress, app?.importProgress, app?.indexMaintenanceActive,
      HomeHeader.compactRevision, Prefs.settingsAsTabRevision, settingsRestoredSignal, CalendarDay.instance,
    ]);
    return StreamBuilder<SettingsChange>(
      stream: _alertChanges,
      builder: (c, _) => ListenableBuilder(
        listenable: listeners,
        builder: (c, _) => _buildHeader(c, app, band),
      ),
    );
  }

  Widget _buildHeader(BuildContext c, AppState? app, _Band band) {
    final now = widget.now ?? clock.now();
    final s = band.sync;
    final download = s.download;
    final opening = _Opening.of(c);
    final window = opening?.downloadWindow ?? _standaloneDownloadWindow;
    final openingHere = opening?.opensOn(widget.tab) == true ? opening : null;
    window.observe(s, band.heldEdge);
    final downloadStep = s.step(SyncStepId.download);
    final derive = app?.deriveProgress.value;
    final import = app?.importProgress.value;
    final l = AppLocalizations.of(c);
    final problem = syncProblem(s, l);
    final maintainingIndex = app?.indexMaintenanceActive.value == true;
    final importing = import != null && import is! ImportDone && import is! ImportFailed;
    final phase = switch ((maintainingIndex, importing, s.phase, derive)) {
      (true, _, _, _) => _Phase.other,
      (_, true, _, _) when import is! ImportCalculating => _Phase.other,
      (_, _, 'downloading', _) => _Phase.download,
      (_, _, 'failed', _) => _Phase.error,
      (_, _, _, final d?) when !d.waiting && !d.crossDay && d.dayTotal != 0 => _Phase.calculate,
      (_, _, 'deriving', null) when s.calculate?.waiting != true => _Phase.calculate,
      (_, _, _, _) when s.busy || derive != null || problem != null => _Phase.other,
      _ => _Phase.idle,
    };
    final motion = Motion.enabled(c);
    final visible = TickerMode.valuesOf(c).enabled;
    Motion.configureSyncPulse(_pulse, enabled: motion && visible &&
        (phase == _Phase.download || phase == _Phase.calculate));
    _tickDownload(visible && phase == _Phase.download && widget.now == null);
    final calculated = derive == null ? s.calculate?.dayIndex : derive.dayIndex;
    final dayTotal = derive == null ? s.calculate?.dayTotal : derive.dayTotal;
    final dayActive = phase == _Phase.calculate &&
        (dayTotal == null || (calculated ?? 0) < dayTotal);
    final calcProgress = calculated == null || dayTotal == null || dayTotal <= 0
        ? null : (calculated / dayTotal).clamp(0.0, 1.0);
    final end = downloadStep.endedAt ?? (s.busy ? now : s.finishedAt);
    final downloadFinished = downloadStep.status == SyncStepStatus.done;
    final downloadComplete = downloadFinished && downloadStep.noteCode != SyncNote.moreRemains;
    final downloadProgress = downloadComplete ? 1.0 : window.fraction(download, end);
    final time = download == null ? null : _window(download.syncedThrough ?? window.start, end);
    final syncAt = s.lastSuccess ?? (s.busy ? band.heldEdge : band.edge);
    final lastSync = syncAt == null
        ? l?.syncStatusNotYet ?? 'Not synced yet'
        : '${l?.syncStatusSyncedLower == null ? 'Synced' : _capitalize(l!.syncStatusSyncedLower)} ${formatClockOf(syncAt.toLocal())}';
    final details = _HeaderStatus(
      phase: phase,
      battery: band.battery,
      connected: band.connected,
      batteryColor: band.battery == null
          ? _inkSecondary(c)
          : headerBatteryColor(band.battery!, Prefs.getInt(NotificationPrefs.batteryPctPrefKey, 20)
              .clamp(NotificationPrefs.batteryPctMin, NotificationPrefs.batteryPctMax)),
      records: download?.records,
      downloadProgress: downloadProgress,
      downloadFinishedThisSync: s.busy && downloadFinished,
      downloadTime: time,
      day: calculated,
      total: dayTotal,
      calculateProgress: calcProgress,

      dayActive: dayActive,
      lastSync: lastSync,
      message: phase == _Phase.error
          ? problem?.text ?? l?.syncStatusFailed ?? 'Sync failed'
          : maintainingIndex
              ? l?.statusLineUpdatingDatabaseIndex ?? 'Updating the database index (one time)'
              : importing
                  ? StatusLine.importLine(l, import)
                  : deriveProgressLine(derive, l) ?? syncStatusHeadline(s, now, l),
    );

    final compact = HomeHeader.compact;
    final showAvatar = !Prefs.settingsAsTabOn;
    final date = DateTime.tryParse(widget.dateLabel ?? widget.day ?? '') ?? now;
    final locale = l?.localeName ?? 'en';
    final shortDate = localizedDate(date, locale, pattern: 'MMMd');
    final weekdayDate = localizedDate(date, locale, pattern: 'MMMEd');
    final label = compact ? weekdayDate : switch (widget.tab) {
      HomeHeaderTab.today => 'Cycle of $shortDate',
      HomeHeaderTab.sleep => 'Night of $shortDate',
      HomeHeaderTab.activity => weekdayDate,
    };
    final dayBar = DayNav(
      day: widget.day,
      days: widget.days,
      labels: widget.labels,
      onDay: widget.onDay,
      alwaysShow: true,
      buildBar: (actions) => _dayBar(c, actions, details, label, openingHere, compact: compact),
    );

    return TapRegion(
      onTapOutside: compact && _expanded ? (_) => _toggle() : null,
      child: Column(
        key: const ValueKey('home-header'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (compact)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: dayBar),
              if (showAvatar) ...[
                const SizedBox(width: 3),
                const Padding(padding: EdgeInsets.only(top: 2), child: _avatar),
              ],
            ])
          else ...[
            _standardPill(c, details, showAvatar: showAvatar),
            const SizedBox(height: 12),
            dayBar,
          ],
        ],
      ),
    );
  }

  Widget _standardPill(BuildContext c, _HeaderStatus status, {required bool showAvatar}) =>
      _box(c, radius: R.syncPill, child: Column(children: [
        SizedBox(
          key: const ValueKey('home-header-pill'),
          height: 44,
          child: Row(children: [
            Expanded(child: Semantics(
              button: true, expanded: _expanded,
              child: Pressable(
                onTap: _toggle,
                child: Padding(
                  padding: EdgeInsets.only(left: 14, right: showAvatar ? 6 : 14),
                  child: _headline(c, status, compact: false),
                ),
              ),
            )),
            if (showAvatar) _avatar,
          ]),
        ),
        _animatedDetails(c, status, compact: false),
      ]));

  Widget _dayBar(BuildContext c, DayStepBar actions, _HeaderStatus status,
      String label, _Opening? opening, {required bool compact}) {
    final l = AppLocalizations.of(c);
    final greeting = widget.greeting ?? homeGreeting((opening?.openedAt ?? clock.now()).hour, l).word;
    final chooseLabel = l?.metricDetailChooseDayShowing(label) ?? 'Choose a day. Showing $label';
    return _box(c, radius: R.rMd, child: Column(children: [
      SizedBox(
        key: const ValueKey('home-header-day-bar'),
        height: 48,
        child: Stack(fit: StackFit.expand, children: [
          _dayFill(c, status),
          Row(children: [
            _arrow(c, actions.previousKey, LucideIcons.chevronLeft, actions.previousLabel,
                actions.onPrevious, compact),
            Expanded(child: Semantics(
              expanded: compact ? _expanded : null,
              child: Pressable(
                key: const ValueKey('day-nav-choose'),
                semanticLabel: chooseLabel,
                onTap: actions.onChoose,
                onLongPress: compact ? _toggle : null,
                child: compact
                    ? Row(children: [
                        Expanded(child: _text(c, label, style: F.body.copyWith(fontWeight: FontWeight.w600))),
                        const SizedBox(width: 2),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 88),
                          child: _headline(c, status, compact: true),
                        ),
                      ])
                    : Center(child: _dayTitle(c, opening, label, greeting)),
              ),
            )),
            _arrow(c, actions.nextKey, LucideIcons.chevronRight, actions.nextLabel,
                actions.onNext, compact),
          ]),
        ]),
      ),
      if (compact) _animatedDetails(c, status, compact: true),
    ]));
  }

  Widget _dayTitle(BuildContext c, _Opening? opening, String label, String greeting) {
    Widget title(String text) => _text(c, text, style: F.syncDate);
    if (opening == null || !Motion.enabled(c)) return title(label);
    return AnimatedBuilder(animation: opening.animation, builder: (c, _) {
      final ms = opening.animation.value * Motion.syncOpening.inMilliseconds;
      if (ms < 2520) {
        return Opacity(
          opacity: (1 - ((ms - 1960) / 560)).clamp(0.0, 1.0),
          child: title(greeting),
        );
      }
      if (ms < 2940) return const SizedBox.shrink();
      return Opacity(
        opacity: ((ms - 2940) / 560).clamp(0.0, 1.0),
        child: title(label),
      );
    });
  }

  Widget _dayFill(BuildContext c, _HeaderStatus status) {
    if (status.phase != _Phase.download && status.phase != _Phase.calculate &&
        status.phase != _Phase.error) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(builder: (c, box) => Stack(children: [
      if (status.phase == _Phase.calculate && status.downloadFinishedThisSync)
        _fill(c, 'download', box.maxWidth, C.green.withValues(alpha: .20))
      else if (status.phase != _Phase.calculate && status.downloadProgress != null)
        _fill(c, 'download', box.maxWidth * status.downloadProgress!, C.green.withValues(alpha: .20)),
      if (status.calculateProgress case final progress?)
        _fill(c, 'calculate', box.maxWidth * progress, C.syncCalculate.withValues(alpha: .32)),
    ]));
  }

  Widget _fill(BuildContext c, String phase, double width, Color color) => AnimatedContainer(
    key: ValueKey('home-header-fill:$phase'),
    duration: motion(c, Motion.syncProgress),
    curve: Curves.easeOut,
    width: width,
    height: double.infinity,
    color: color,
  );

  Widget _arrow(BuildContext c, Key key, IconData icon, String label,
      VoidCallback? onTap, bool compact) => SizedBox(
    key: key,
    width: compact ? 48 : 44,
    height: 48,
    child: Pressable(
      semanticLabel: label, onTap: onTap,
      child: Icon(icon, size: 18, color: _inkMuted(c)
          .withValues(alpha: onTap == null ? .35 : 1)),
    ),
  );

  Widget _headline(BuildContext c, _HeaderStatus s, {required bool compact}) {
    final l = AppLocalizations.of(c);
    final muted = _inkSecondary(c);
    final style = compact ? F.cap : F.syncPill;
    final iconSize = compact ? 16.0 : 17.0;
    final children = <Widget>[];
    String? trailing;

    switch (s.phase) {
      case _Phase.download:
        children.add(_icon(LucideIcons.download, C.green, size: iconSize, pulse: true));
        final n = s.records;
        final text = n == null
            ? (compact ? _missing : l?.syncStatusDownloading ?? 'Downloading…')
            : (compact ? '$n' : l?.syncCountRecords(n) ?? '$n ${n == 1 ? 'record' : 'records'}');
        children.add(Flexible(child: _text(c, text, style: style, color: compact ? muted : null)));
        trailing = s.downloadTime;
      case _Phase.calculate:
        children.add(Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (index, icon) in _metricIcons.indexed) ...[
            if (index != 0) const SizedBox(width: 2),
            _icon(icon, s.dayActive || s.calculateProgress == 1 ? C.syncCalculate : C.syncQueued,
                size: iconSize, pulse: s.dayActive),
          ],
        ]));
        final day = s.day;
        final total = s.total;
        children.add(Flexible(child: _text(c,
          day == null || total == null
              ? (compact ? _missing : l?.syncStatusCalculating ?? 'Calculating…')
              : (compact ? '$day/$total' : l?.syncLineDay('$day', '$total', '') ?? 'Day $day of $total'),
          style: style, color: compact ? muted : null,
        )));

      case _Phase.idle:
        if (!compact && !_expanded && s.connected != null) {
          children.add(Semantics(
            label: s.connected == true ? l?.devicesConnected ?? 'Connected'
                : l?.devicesNotConnected ?? 'Not connected',
            child: DecoratedBox(
              key: const ValueKey('home-header-connection-dot'),
              decoration: BoxDecoration(
                shape: BoxShape.circle, color: s.connected == true ? C.green : C.n500,
              ),
              child: const SizedBox.square(dimension: 8),
            ),
          ));
        }
        if (s.battery != null) {
          final color = s.connected == false ? _inkMuted(c) : _batteryInk(c, s.batteryColor);
          children.add(_icon(LucideIcons.batteryMedium, color, size: iconSize));
          children.add(Flexible(child: _text(c, '${s.battery}%', style: style, color: color)));
        }
        trailing = s.lastSync;
      case _Phase.error:
        final warning = _icon(LucideIcons.triangleAlert, C.syncWarning, size: iconSize);
        children.add(compact ? Semantics(label: s.message, child: warning) : warning);
        if (!compact) {
          children.add(Flexible(child: _text(c, s.message, style: style, color: P.of(c).dark ? C.syncError : P.of(c).on(C.syncWarning))));
        }
      case _Phase.other:
        children.add(Flexible(child: _text(c, s.message, style: style, color: muted)));
    }

    return Row(
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      mainAxisAlignment: compact ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (!compact && !_expanded && trailing != null)
          Expanded(child: Row(children: _spaced(children, 8)))
        else
          ..._spaced(children, compact ? 4 : 8),
        if (!compact && !_expanded && trailing != null) ...[
          if (children.isNotEmpty) _gap,
          Flexible(
            flex: children.isEmpty ? 2 : 1,
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _text(c, trailing, style: style, color: muted),
            ),
          ),
        ],
      ],
    );
  }

  Widget _animatedDetails(BuildContext c, _HeaderStatus status, {required bool compact}) =>
      AnimatedSize(
        alignment: Alignment.topCenter,
        duration: motion(c, Motion.syncDetails),
        curve: Curves.easeInOut,
        child: _expanded
            ? Padding(
                padding: EdgeInsets.fromLTRB(14, 0, 14, compact ? 12 : 10),
                child: Column(children: [
                  if (compact) ...[
                    const Divider(height: 1, thickness: 1, color: C.syncDivider),
                    const SizedBox(height: 10),
                  ],
                  _detailRows(c, status),
                ]),
              )
            : const SizedBox(width: double.infinity),
      );

  Widget _detailRows(BuildContext c, _HeaderStatus s) {
    final muted = _inkSecondary(c);
    final battery = s.battery;
    return LayoutBuilder(builder: (c, box) {
      // Let the time column claim its natural width. The count gives up
      // space first so a large count never pushes an endpoint off the row.
      final countWidth = math.min(68.0, box.maxWidth * .26);
      TableRow row({
        required Widget icon, required Color color,
        double? progress, IconData? countIcon, String? count, String? time,
        Color? countColor,
      }) => TableRow(children: [
        icon,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _progress(c, progress, color),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (countIcon != null) ...[_icon(countIcon, color, size: 14), const SizedBox(width: 4)],
            Flexible(child: _text(c, count ?? _missing, style: F.syncDetail, color: countColor)),
          ]),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: _text(c, time ?? _missing, style: F.syncDetailTime, color: muted),
        ),
      ]);
      return Table(
        key: const ValueKey('home-header-details'),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        columnWidths: {
          0: const FixedColumnWidth(20),
          1: const FlexColumnWidth(),
          2: FixedColumnWidth(countWidth),
          3: const IntrinsicColumnWidth(),
        },
        children: [
          row(icon: _icon(LucideIcons.download, C.green, size: 18,
                  pulse: s.phase == _Phase.download),
              color: C.green, progress: s.downloadProgress,
              countIcon: LucideIcons.package, count: s.records?.toString(), time: s.downloadTime),
          const TableRow(children: [SizedBox(height: 6), SizedBox(), SizedBox(), SizedBox()]),
          row(icon: _icon(LucideIcons.moon,
                  s.dayActive || s.calculateProgress == 1 ? C.syncCalculate : C.syncQueued,
                  size: 18, pulse: s.dayActive),
              color: C.syncCalculate, progress: s.calculateProgress,
              countIcon: LucideIcons.calendarDays,
              count: s.day == null || s.total == null ? null : '${s.day} / ${s.total}',
              ),
          const TableRow(children: [SizedBox(height: 6), SizedBox(), SizedBox(), SizedBox()]),
          row(icon: _icon(LucideIcons.batteryMedium, _batteryInk(c, s.batteryColor), size: 18),
              color: s.batteryColor, progress: battery == null ? null : battery / 100,
              count: battery == null ? null : '$battery%', time: s.lastSync,
              countColor: _batteryInk(c, s.batteryColor)),
        ],
      );
    });
  }

  Widget _progress(BuildContext c, double? progress, Color color) => ClipRRect(
    borderRadius: R.syncTrack,
    child: SizedBox(
      height: 8,
      child: ColoredBox(
        color: _track(c),
        child: FractionallySizedBox(
          widthFactor: (progress ?? 0).clamp(0.0, 1.0),
          alignment: AlignmentDirectional.centerStart,
          child: DecoratedBox(decoration: BoxDecoration(
            color: color, borderRadius: R.syncTrack,
          )),
        ),
      ),
    ),
  );

  Widget _icon(IconData icon, Color color, {required double size, bool pulse = false}) {
    final glyph = Icon(icon, color: color, size: size);
    if (!pulse) return glyph;
    return AnimatedBuilder(animation: _pulse, child: glyph, builder: (c, child) {
      final opacity = 1 - .7 * (1 - math.cos(_pulse.value * 2 * math.pi)) / 2;
      return Opacity(opacity: opacity, child: child);
    });
  }
}

class _DownloadWindow {
  DateTime? _run;
  DateTime? start;

  void observe(SyncPresentationState sync, DateTime? heldEdge) {
    if (_run != sync.startedAt) {
      _run = sync.startedAt;
      start = null;
    }
    if (sync.busy) start = heldEdge;
  }

  double? fraction(SyncDownloadDetail? d, DateTime? now) {
    if (d == null) return null;
    final start = this.start;
    final newest = d.bandNewest;
    final end = newest != null && (now == null || !newest.isAfter(now)) ? newest : now;
    final through = d.syncedThrough;
    if (start != null && end != null && through != null && end.isAfter(start)) {
      final total = end.difference(start).inMilliseconds;
      return (through.difference(start).inMilliseconds / total).clamp(0.0, 1.0);
    }
    return null;
  }
}

enum _Phase { download, calculate, idle, error, other }

const _metricIcons = [LucideIcons.moon, LucideIcons.batteryCharging, LucideIcons.zap];

class _HeaderStatus {
  const _HeaderStatus({
    required this.phase, required this.battery, required this.connected,
    required this.batteryColor, required this.records, required this.downloadProgress,
    required this.downloadFinishedThisSync,
    required this.downloadTime, required this.day, required this.total,
    required this.calculateProgress, required this.dayActive,
    required this.lastSync, required this.message,
  });

  final _Phase phase;
  final int? battery, records, day, total;
  final bool? connected;
  final bool dayActive, downloadFinishedThisSync;
  final Color batteryColor;
  final double? downloadProgress, calculateProgress;
  final String? downloadTime;
  final String lastSync, message;
}

String? _window(DateTime? start, DateTime? end) =>
    start == null || end == null
        ? null
        : '${formatClockOf(start.toLocal())} → ${formatClockOf(end.toLocal())}';

String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

List<Widget> _spaced(List<Widget> children, double spacing) => [
  for (final (index, child) in children.indexed) ...[
    if (index != 0) SizedBox(width: spacing),
    child,
  ],
];

Color _track(BuildContext c) => P.of(c).bg;
Color _inkSecondary(BuildContext c) => P.of(c).ink2;
Color _inkMuted(BuildContext c) => P.of(c).ink3;
Color _batteryInk(BuildContext c, Color color) {
  final p = P.of(c);
  return p.dark ? color : p.on(color);
}

Widget _box(BuildContext c, {required BorderRadius radius, required Widget child}) =>
    Material(
      color: P.of(c).card2,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: child,
    );

Widget _text(BuildContext c, String text, {
  required TextStyle style, Color? color,
}) => Text(
  text,
  maxLines: 1,
  softWrap: false,
  overflow: TextOverflow.ellipsis,
  style: style.copyWith(color: color ?? P.of(c).ink),
);
