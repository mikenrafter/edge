// read_paused.dart — what a repository read throws while an import has the
// database to itself (see lib/sync/import_focus.dart). Thrown, not returned:
// callers that already catch a failed read keep working, and a screen that
// wants the message catches this type.
library;

class ReadPaused implements Exception {
  const ReadPaused(this.reason);

  /// Why reads are paused. 'import' is the only reason today.
  final String reason;

  @override
  String toString() => 'ReadPaused($reason)';
}
