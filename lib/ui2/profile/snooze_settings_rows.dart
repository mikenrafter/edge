// snooze_settings_rows.dart — the alarm settings rows for the main alarm's
// dismiss/snooze: double taps to dismiss, the dismiss window, the snooze
// length, and where escalation stops. A choice applies at once.
//
// Pinned by test/alarm_snooze/snooze_ui_test.dart.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../alarm/snooze/snooze_settings.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'profile.dart' show SetRow;

/// The copy that says what [taps] double taps do, with the live value: "2 double
/// taps to dismiss — fewer is a snooze" ("1 double tap" when it is 1).
String snoozeDismissCopy(int taps, [AppLocalizations? l]) =>
    l?.snoozeDismissCopy(taps) ??
    '$taps double tap${taps == 1 ? '' : 's'} to dismiss — fewer is a snooze';

class SnoozeSettingsRows extends StatelessWidget {
  const SnoozeSettingsRows({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final SnoozeSettings settings;

  /// A choice, already clamped; applied at once (these are not part of the
  /// alarm schedule's Save draft).
  final ValueChanged<SnoozeSettings>? onChanged;

  static String _taps(AppLocalizations? l, int n) =>
      l?.snoozeValueTaps(n) ?? '$n double tap${n == 1 ? '' : 's'}';
  static String _secs(AppLocalizations? l, int s) =>
      l?.snoozeValueSeconds(s) ?? '$s s';
  static String _mins(AppLocalizations? l, int m) =>
      l?.snoozeValueMinutes(m) ?? '$m min';
  static String _cap(AppLocalizations? l, int n) =>
      l?.snoozeValueCap(n) ?? '$n snooze${n == 1 ? '' : 's'}';

  Future<void> _choose(BuildContext c, String title, List<(int, String)> options,
      void Function(int) apply) async {
    final v = await showDialog<int>(
      context: c,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, o.$1),
              child: Text(o.$2),
            ),
        ],
      ),
    );
    if (v != null) apply(v);
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final on = onChanged;
    final p = P.of(c);
    String title(String? localized, String english) => localized ?? english;
    final tapsTitle = title(l?.snoozeRowTaps, 'Double taps to dismiss');
    final windowTitle = title(l?.snoozeRowWindow, 'Dismiss window');
    final minutesTitle = title(l?.snoozeRowMinutes, 'Snooze for');
    final capTitle = title(l?.snoozeRowCap, 'Stop escalating after');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x2),
          child: Text(snoozeDismissCopy(settings.requiredTaps, l),
              key: const ValueKey('snooze-dismiss-copy'),
              style: F.cap.copyWith(color: p.ink2)),
        ),
        SetRow(LucideIcons.hand, C.blue, tapsTitle,
            value: _taps(l, settings.requiredTaps),
            onTap: on == null
                ? null
                : () => _choose(c, tapsTitle, [
                      for (var n = kSnoozeTapsMin; n <= kSnoozeTapsMax; n++)
                        (n, _taps(l, n)),
                    ], (n) => on(settings.copyWith(requiredTaps: n)))),
        SetRow(LucideIcons.timer, C.blue, windowTitle,
            value: _secs(l, settings.windowMs ~/ 1000),
            onTap: on == null
                ? null
                : () => _choose(c, windowTitle, [
                      for (final s in const [2, 3, 4, 5, 6, 8, 10, 15])
                        (s * 1000, _secs(l, s)),
                    ], (ms) => on(settings.copyWith(windowMs: ms)))),
        SetRow(LucideIcons.alarmClockPlus, C.blue, minutesTitle,
            value: _mins(l, settings.minutes),
            onTap: on == null
                ? null
                : () => _choose(c, minutesTitle, [
                      for (final m in const [1, 2, 3, 5, 10, 15, 20, 30])
                        (m, _mins(l, m)),
                    ], (m) => on(settings.copyWith(minutes: m)))),
        SetRow(LucideIcons.trendingUp, C.blue, capTitle,
            value: _cap(l, settings.cap),
            onTap: on == null
                ? null
                : () => _choose(c, capTitle, [
                      for (final n in const [1, 2, 3, 4, 6, 8, 10, 20])
                        (n, _cap(l, n)),
                    ], (n) => on(settings.copyWith(cap: n)))),
      ],
    );
  }
}
