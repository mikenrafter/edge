import 'dart:async';

import 'package:flutter/material.dart';

import '../data/read_paused.dart';
import '../l10n/app_localizations.dart';
import '../sync/import_focus.dart';
import 'theme.dart';

/// A quiet placeholder for reads deferred while an import owns the database.
/// It stands IN the slot of the content it replaces: give it that content's
/// [height] and nothing below it moves.
class PausedOlderDays extends StatelessWidget {
  const PausedOlderDays({super.key, this.height});

  final double? height;

  @override
  Widget build(BuildContext context) => _PausedLine(
        AppLocalizations.of(context)?.importPausedOlderDays ??
            'Older days load when the import finishes',
        height: height,
      );
}

/// The same, for a surface that is about TODAY and has nothing published yet.
class PausedToday extends StatelessWidget {
  const PausedToday({super.key, this.height});

  final double? height;

  @override
  Widget build(BuildContext context) => _PausedLine(
        pausedTodayText(context),
        height: height,
      );
}

String pausedTodayText(BuildContext context) =>
    AppLocalizations.of(context)?.importPausedTodayPending ??
    'Today appears as soon as it’s ready';

String pausedOlderDaysText(BuildContext context) =>
    AppLocalizations.of(context)?.importPausedOlderDays ??
    'Older days load when the import finishes';

/// What a blocked save says. Quiet: no error styling.
String pausedSavingText(BuildContext context) =>
    AppLocalizations.of(context)?.importPausedSaving ??
    'Saving is paused until the import finishes';

class _PausedLine extends StatelessWidget {
  const _PausedLine(this.text, {this.height});

  final String text;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final line = Text(
      text,
      style: F.cap.copyWith(color: P.of(context).ink3),
      textAlign: TextAlign.center,
    );
    return height == null
        ? line
        : SizedBox(height: height, child: Center(child: line));
  }
}

class PausedReadResult<T> {
  const PausedReadResult.value(this.value) : paused = false;
  const PausedReadResult.paused()
      : value = null,
        paused = true;

  final T? value;
  final bool paused;
}

/// Converts a repository's typed pause into a renderable load result.
Future<PausedReadResult<T>> pausedRead<T>(Future<T> read) async {
  try {
    return PausedReadResult<T>.value(await read);
  } on ReadPaused {
    return PausedReadResult<T>.paused();
  }
}

/// The ONE place a screen learns about import focus.
///
///  * focus STARTS ([focusStarted]): what is on screen was read before the
///    pause; the screen drops it and shows the paused state.
///  * focus ENDS ([reloadPausedRead]): one reload.
///  * while paused, revisions are ignored ([absorbRevision]): they would only
///    read again what cannot be read.
///  * a model published while focus is active ([published]): a screen that
///    shows today or yesterday refreshes from it.
///
/// Reloads run through [trackReload]: at most ONE is in flight; a revision
/// that arrives meanwhile only marks the screen dirty, and when the reload in
/// flight completes exactly one trailing reload runs. A burst reads at most
/// twice, and a revision is never dropped: whatever it announced is read by
/// the trailing reload.
mixin PausedReadReload<T extends StatefulWidget> on State<T> {
  bool _watching = false;
  bool _inFlight = false;
  bool _dirty = false;

  /// Whether the screen is showing the paused state now.
  bool get pausedContent;

  /// The one reload after focus ends. Completes when the read has landed.
  Future<void> reloadPausedRead();

  /// Focus just started under a screen that is already showing content.
  void focusStarted() {}

  /// ImportFocus.days changed while focus is active.
  void published() {}

  /// Call first in `reload()` (the revision hook): true means skip this one
  /// (the screen is paused; focus end reads it).
  bool absorbRevision() => ImportFocus.active.value && pausedContent;

  /// Runs [run] unless one is in flight, in which case one trailing run is
  /// queued for when it completes.
  void trackReload(Future<void> Function() run) {
    if (_inFlight) {
      _dirty = true;
      return;
    }
    _inFlight = true;
    Future<void>.sync(run).catchError((Object _) {}).whenComplete(() {
      _inFlight = false;
      if (_dirty && mounted) {
        _dirty = false;
        trackReload(run);
      }
    });
  }

  void watchPausedRead() {
    if (_watching) return;
    _watching = true;
    ImportFocus.active.addListener(_onActive);
    ImportFocus.days.addListener(_onDays);
  }

  void stopWatchingPausedRead() {
    if (!_watching) return;
    ImportFocus.active.removeListener(_onActive);
    ImportFocus.days.removeListener(_onDays);
    _watching = false;
  }

  void _onActive() {
    if (!mounted) return;
    if (ImportFocus.active.value) {
      focusStarted();
    } else {
      trackReload(reloadPausedRead);
    }
  }

  void _onDays() {
    // leave() empties the map just before it clears `active`: not a publish.
    if (mounted && ImportFocus.active.value && ImportFocus.days.value.isNotEmpty) {
      published();
    }
  }
}
