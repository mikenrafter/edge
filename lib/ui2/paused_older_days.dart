import 'package:flutter/material.dart';

import '../data/read_paused.dart';
import '../l10n/app_localizations.dart';
import 'grammar.dart';
import 'theme.dart';
import '../sync/import_focus.dart';

/// A quiet placeholder for reads deferred while an import owns the database.
class PausedOlderDays extends StatelessWidget {
  const PausedOlderDays({super.key});

  @override
  Widget build(BuildContext context) => Text(
        AppLocalizations.of(context)?.importPausedOlderDays ??
            'Older days load when the import finishes',
        style: F.cap.copyWith(color: P.of(context).ink3),
        textAlign: TextAlign.center,
      );
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

/// Listens for the single transition that releases paused screen reads.
mixin PausedReadReload<T extends StatefulWidget> on State<T> {
  bool _watchingPausedRead = false;

  void watchPausedRead() {
    if (_watchingPausedRead) return;
    _watchingPausedRead = true;
    ImportFocus.active.addListener(_pausedReadFocusChanged);
  }

  void stopWatchingPausedRead() {
    if (!_watchingPausedRead) return;
    ImportFocus.active.removeListener(_pausedReadFocusChanged);
    _watchingPausedRead = false;
  }

  void _pausedReadFocusChanged() {
    if (!ImportFocus.active.value && mounted) reloadPausedRead();
  }

  void reloadPausedRead();
}
