import 'dart:async';
import 'package:clock/clock.dart' as pc;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../data/day_label.dart';
import '../l10n/app_localizations.dart';
import 'grammar.dart';
import 'theme.dart';
import 'skeleton/pending_scope.dart';
import '../l10n/date_text.dart' show prettyDay;

// This module owns the midnight timer and date-picker latch. Pages own their
// selected date and read generation; this control never waits for a repository.
// CLAIM(day-navigation-immediate): today's action stays available during reads
// [sleep-structural/spec §2.1; day_navigation_shared_test].
Widget backToTodayControl({required String selectedDay,
    required ValueChanged<String> onSelect}) =>
  _BackToTodayControl(selectedDay: selectedDay, onSelect: onSelect);

class _BackToTodayControl extends StatefulWidget {
  const _BackToTodayControl({required this.selectedDay, required this.onSelect});
  final String selectedDay;
  final ValueChanged<String> onSelect;
  @override
  State<_BackToTodayControl> createState() => _BackToTodayState();
}

class _BackToTodayState extends State<_BackToTodayControl>
    with WidgetsBindingObserver {
  Timer? _midnight;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _armMidnight();
  }

  /// The longest the control trusts its own day-end estimate: a time-zone
  /// change while resumed moves midnight with no event, so it looks again.
  static const _recheck = Duration(minutes: 15);

  void _armMidnight() {
    _midnight?.cancel();
    final now = pc.clock.now();
    final end = localDayEndSec(todayLabel(now))!;
    final untilEnd =
        Duration(milliseconds: end * 1000 - now.millisecondsSinceEpoch);
    _midnight = Timer(untilEnd < _recheck ? untilEnd : _recheck, () {
      if (!mounted) return;
      setState(() {});
      _armMidnight();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() {});
      _armMidnight();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Inactive is still on screen (split screen, notification shade).
      _midnight?.cancel();
    }
  }

  @override
  void dispose() {
    _midnight?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    if (widget.selectedDay == todayLabel(pc.clock.now())) {
      return const SizedBox.shrink();
    }
    final p = P.of(c);
    final label = AppLocalizations.of(c)?.homeBackToToday ?? 'Back to today';
    // Extracted from Home. Keep its pill presentation, with a 48 dp target.
    // Pushed pages put the frame outside their Scaffold, so nothing above this
    // pill gives it a text style: without a Material it draws MaterialApp's
    // error underline.
    return Material(type: MaterialType.transparency, child: PendingStatic(child: Pressable(
      key: const ValueKey('home-back-to-today'),
      semanticLabel: label,
      onTap: () => widget.onSelect(todayLabel(pc.clock.now())),
      child: Container(constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
        decoration: ShapeDecoration(color: p.card2,
          shape: StadiumBorder(side: BorderSide(color: p.line))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(LucideIcons.calendarDays, size: 16, color: p.on(C.blue)),
          const SizedBox(width: S.x2),
          // The Pressable already names the control; the text is not read again.
          Flexible(child: ExcludeSemantics(child: Text(label,
            style: F.cap.copyWith(color: p.on(C.blue))))),
        ])),
    )));
  }
}

/// A failed stored read is retryable; it must not look like an empty day.
Widget dayReadFailure(BuildContext c, VoidCallback retry) {
  final l = AppLocalizations.of(c);
  return StatusCard(
    l?.wellnessLoadFailedTitle ?? 'This could not be read',
    l?.wellnessLoadFailedBody ??
        'Reading your stored data failed. Nothing was deleted — this is '
        'a read that went wrong, not missing data.',
    fix: l?.homeTryAgain ?? 'Try again',
    icon: LucideIcons.databaseZap,
    onFix: retry,
  );
}

/// Floats Home's pill over the page. Existing list/footer padding reserves its
/// ordinary height; measured extra height reserves room when its text wraps.
class DayNavigationFrame extends StatelessWidget {
  const DayNavigationFrame({super.key, required this.selectedDay,
    required this.onSelect, required this.child});
  static const clearance = 48.0 + S.x2;
  final String selectedDay;
  final ValueChanged<String> onSelect;
  final Widget child;

  @override
  Widget build(BuildContext c) => ColoredBox(color: P.of(c).bg,
    child: Stack(children: [Positioned.fill(
      child: CustomMultiChildLayout(
        delegate: _DayNavigationLayout(MediaQuery.paddingOf(c).bottom),
        children: [
          LayoutId(id: _DayNavigationSlot.page, child: child),
          LayoutId(id: _DayNavigationSlot.control,
            child: SafeArea(top: false, child: Padding(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x2),
              child: Align(alignment: Alignment.bottomCenter, heightFactor: 1,
                child: backToTodayControl(
                  selectedDay: selectedDay, onSelect: onSelect)),
            ))),
        ],
      ),
    )]));
}

enum _DayNavigationSlot { page, control }

class _DayNavigationLayout extends MultiChildLayoutDelegate {
  _DayNavigationLayout(this.safeBottom);
  final double safeBottom;

  @override
  void performLayout(Size size) {
    final control = layoutChild(_DayNavigationSlot.control,
      BoxConstraints.loose(size));
    // Reserve the actual wrapped height above the ordinary 48 dp pill, so
    // large text cannot cover a footer or the last scrollable row.
    final extra = (control.height - safeBottom - DayNavigationFrame.clearance)
        .clamp(0.0, size.height).toDouble();
    layoutChild(_DayNavigationSlot.page,
      BoxConstraints.tight(Size(size.width, size.height - extra)));
    positionChild(_DayNavigationSlot.page, Offset.zero);
    positionChild(_DayNavigationSlot.control,
      Offset(0, size.height - control.height));
  }

  @override
  bool shouldRelayout(_DayNavigationLayout old) => old.safeBottom != safeBottom;
}

final _openPickers = Expando<bool>();

/// Runs [open] (a date picker) unless one is already open on this navigator,
/// so a double tap never stacks two dialogs. The latch is released on return
/// or failure.
Future<T?> openPickerOnce<T>(BuildContext c, Future<T?> Function() open) async {
  final navigator = Navigator.of(c);
  if (_openPickers[navigator] == true) return null;
  _openPickers[navigator] = true;
  try {
    return await open();
  } finally {
    _openPickers[navigator] = false;
  }
}

/// The day a single-day screen should load: the one it was OPENED with when
/// that day exists, else the screen's own idea of now, else the newest day on
/// disk.
///
/// [want] is the day the caller asked for and [prefer] the screen's own
/// resolution (`today_day`, a held-over night). With no [want] this is exactly
/// what every loader did inline, which is why passing no day changes nothing.
String? pickDay(List<String> days, String? want, [String? prefer]) {
  final d = want ?? prefer;
  // No derived days at all: there is nothing to fall back TO, so the caller's
  // own answer stands or the screen renders its absence.
  if (days.isEmpty) return d;
  // An explicit request for today stands even before today has derived (the
  // screen shows its empty day). Ordinary landing (no [want]) stays on the
  // newest day with data, as it always did.
  if (want != null && want == todayLabel(pc.clock.now())) return want;
  if (d != null && days.contains(d)) return d;
  return days.first;
}

/// 'Today' when it is, otherwise the day itself. Never "N days ago" — a
/// control you steer with needs the name of the place, not the distance to it.
String dayNavLabel(String? day, [AppLocalizations? l]) =>
    day == todayLabel(pc.clock.now())
        ? l?.healthToday ?? 'Today'
        : prettyDay(day, l);

/// The calendar, restricted to the days that exist. A picker that offers an
/// empty day is a dead end, so [days] greys out everything it does not contain.
Future<String?> chooseDay(
    BuildContext c, List<String> days, String? current) async {
  if (days.isEmpty) return null;
  final have = days.toSet();
  final sorted = [...days]..sort(); // oldest → newest
  final first = DateTime.parse(sorted.first);
  final last = DateTime.parse(sorted.last);
  final want = DateTime.tryParse(current ?? '') ?? last;
  final picked = await openPickerOnce(c, () => showDatePicker(
    context: c,
    initialDate: want.isBefore(first) ? first : (want.isAfter(last) ? last : want),
    firstDate: first,
    lastDate: last,
    selectableDayPredicate: (d) => have.contains(dayLabelOf(d)),
    helpText: AppLocalizations.of(c)?.metricDetailChooseDayHelp ?? 'Choose a day',
  ));
  return picked == null ? null : dayLabelOf(picked);
}

/// The day stepper every single-day screen wears under its nav bar.
///
/// [days] is `availableDays()` — NEWEST FIRST, and only days that derived. Both
/// arrows and the picker walk that list, so there is no way to steer onto a day
/// this install has no record of. With fewer than two days there is nowhere to
/// go and the control renders nothing rather than two dead arrows.
class DayNav extends StatelessWidget {
  final String? day;
  final List<String> days;
  final ValueChanged<String> onDay;

  /// Draws the bar (both arrows dimmed) with fewer than two days, for a screen
  /// that must not gain a row when the second day arrives.
  final bool alwaysShow;

  const DayNav({
    super.key,
    required this.day,
    required this.days,
    required this.onDay,
    this.alwaysShow = false,
  });

  @override
  Widget build(BuildContext c) {
    if (days.length < 2 && !alwaysShow) return const SizedBox.shrink();
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final i = days.indexOf(day ?? '');
    // days is newest first: the OLDER day is further down the list.
    final older = i < 0 ? days.firstOrNull : (i + 1 < days.length ? days[i + 1] : null);
    final newer = i > 0 ? days[i - 1] : null;

    Widget arrow(IconData icon, String label, String? to) => Opacity(
          key: ValueKey(icon == LucideIcons.chevronLeft ? 'day-nav-previous' : 'day-nav-next'),
          opacity: to == null ? .35 : 1,
          child: Pressable(
            onTap: to == null ? null : () => onDay(to),
            semanticLabel: label,
            child: Icon(icon, size: 20, color: p.ink),
          ),
        );

    return PendingStatic(
      child: GuideBox(child: Container(
      decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
      child: Row(children: [
        arrow(LucideIcons.chevronLeft, l?.metricDetailPreviousDay ?? 'Previous day',
            older),
        Expanded(
          child: Pressable(
            key: const ValueKey('day-nav-choose'),
            onTap: () async {
              final picked = await chooseDay(c, days, day);
              if (c.mounted && picked != null && picked != day) {
                PendingUserAction.run(() => onDay(picked));
              }
            },
              semanticLabel:
                  l?.metricDetailChooseDayShowing(dayNavLabel(day, l)) ??
                  'Choose a day. Showing ${dayNavLabel(day, l)}',
              child: SizedBox(width: double.infinity, child: Text(
                dayNavLabel(day, l),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600),
              )),
            ),
          ),
        arrow(LucideIcons.chevronRight, l?.metricDetailNextDay ?? 'Next day', newer),
      ],
          ),
        ),
    ));
  }
}

/// [DayNav] and the gap under it, spread into a `detailScaffold` body — or
/// nothing at all when there is only one day to look at.
List<Widget> dayNavRow(
        String? day, List<String> days, ValueChanged<String> onDay) =>
    [
      DayNav(day: day, days: days, onDay: onDay, alwaysShow: true),
      const SizedBox(height: S.x3),
    ];
