// The app-wide status line under a tab's title: one fixed-height row that says
// what long background work is doing, or how far the data reaches when nothing
// is. Always present, so a progress change swaps text inside the box and never
// moves anything (0 layout shift).
//
// First that applies: import progress > derive progress (running) > a sync
// running > "Synced through ...". Counts appear only where the source reported
// them. Tap opens the sync details, as Home's sync row does. With no AppState
// above (fixtures) the row keeps its height and shows nothing.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/day_label.dart' show todayLabel;
import '../data/import_progress.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/derive_progress.dart';
import 'grammar.dart';
import 'profile/import_progress_view.dart';
import 'screens/home_screen.dart' show syncedThroughLabel, syncedThroughShortLabel;
import 'shared_slot.dart';
import 'sync_control.dart';
import 'theme.dart';

class StatusLine extends StatelessWidget {
  /// The rendered day id for the idle "Synced through" clock-vs-date choice;
  /// null reads the local day. Injectable so tests never read the clock.
  final String? todayId;

  /// The "now" for the sync sentence; null is the wall clock.
  final DateTime? now;

  /// Home: while no import or recalculation is reported, the line is the sync
  /// row ([HomeSyncStatus]) with its "Sync now" / "Show details" actions, in
  /// the same fixed-height slot. The other tabs carry the text alone.
  final bool syncActions;
  const StatusLine({super.key, this.todayId, this.now, this.syncActions = false});

  static const _pad = EdgeInsets.symmetric(horizontal: S.x1, vertical: S.x1);

  /// One line of F.cap at the current text scale plus the padding.
  static double heightFor(BuildContext c) =>
      MediaQuery.textScalerOf(c).scale(F.cap.fontSize!) * F.cap.height! +
      _pad.vertical;

  /// The import's line: "Importing · Copying heart rate · step 4 of 9".
  static String importLine(AppLocalizations? l, ImportProgress s) {
    final status = ImportProgressView.statusOf(l, s);
    if (s is ImportCopying) {
      return l?.statusLineImportingStep(
              status, '${s.stageIndex}', '${s.stageCount}') ??
          'Importing · $status · step ${s.stageIndex} of ${s.stageCount}';
    }
    if (s is ImportRebuilding || s is ImportFailed) return status;
    return l?.statusLineImporting(status) ?? 'Importing · $status';
  }

  @override
  Widget build(BuildContext c) {
    AppState? app;
    try {
      app = c.read<AppState>();
    } on ProviderNotFoundException {
      app = null;
    }
    return SharedSlot('status-line', child: _line(c, app));
  }

  Widget _line(BuildContext c, AppState? app) {
    if (app == null) {
      // A golden: Home still says where the data ends ("No band data yet").
      if (!syncActions) return SizedBox(height: heightFor(c));
      final id = todayId ?? todayLabel();
      return SizedBox(
        height: heightFor(c),
        child: Align(
          alignment: Alignment.centerLeft,
          child: HomeSyncStatus(
            through: syncedThroughLabel(null, id),
            throughShort: syncedThroughShortLabel(null, id),
            inset: S.x1,
          ),
        ),
      );
    }
    return ValueListenableBuilder<ImportProgress?>(
      valueListenable: app.importProgress,
      builder: (c, imp, _) => ValueListenableBuilder<DeriveProgress?>(
        valueListenable: app.deriveProgress,
        builder: (c, der, _) => _text(c, app, imp, der),
      ),
    );
  }

  Widget _text(BuildContext c, AppState app, ImportProgress? imp,
      DeriveProgress? der) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    // Only the fields this line needs, so AppState's heartbeat does not
    // rebuild it. A record compares by value.
    final at = now ?? DateTime.now();
    final sync = c.select<AppState, (bool, String, DateTime?)>((a) {
      final s = a.syncPresentation;
      return (s.busy, s.busy ? syncStatusHeadline(s, at) : '', a.lastRecordAt);
    });
    final String text;
    if (imp != null && imp is! ImportDone) {
      text = importLine(l, imp);
    } else if (deriveProgressLine(der, l) case final d?) {
      text = d;
    } else if (sync.$1) {
      text = sync.$2;
    } else {
      text = syncedThroughLabel(sync.$3, todayId ?? todayLabel(), l);
    }
    if (syncActions &&
        (imp == null || imp is ImportDone) &&
        deriveProgressLine(der, l) == null) {
      // No wrapper box: the row's HitOverhang must be the render child of the
      // header Column so its 44 pt targets overhang the lines around it. It
      // reports [heightFor] itself (slot), the same as the text-only line.
      final id = todayId ?? todayLabel();
      return HomeSyncStatus(
        through: syncedThroughLabel(sync.$3, id, l),
        throughShort: syncedThroughShortLabel(sync.$3, id, l),
        inset: S.x1,
        slot: heightFor(c),
      );
    }
    return SizedBox(
      height: heightFor(c),
      child: Pressable(
        onTap: () => showSyncDetails(c, app),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: _pad,
            child: Text(text,
                style: F.cap.copyWith(color: p.ink3),
                strutStyle:
                    StrutStyle.fromTextStyle(F.cap, forceStrutHeight: true),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }
}
