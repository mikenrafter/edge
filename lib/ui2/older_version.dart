// RED STUB. The one shared marker and note for a value served from an older
// calculation (owner decision 2026-10-22, RULES B.2). Bodies are empty on
// purpose; the green phase replaces them. Keys and texts are pinned by
// test/ui2_older_version_*_test.dart.
import 'package:flutter/widgets.dart';

/// "From an older calculation (v104): <reason sentence>"; without a reason,
/// "From an older calculation (v104)".
String olderVersionNoteText(int version, String? reason) => '';

/// Spoken form, always containing "from an older calculation".
String olderVersionSemantics(int version) => '';

/// The asterisk beside a number. Key: ValueKey('older-version-mark:$id').
/// Renders nothing when [version] is null. Tapping it reveals the note text.
class OlderVersionMark extends StatelessWidget {
  final String id;
  final int? version;
  final String? reason;
  const OlderVersionMark(
      {super.key, required this.id, required this.version, this.reason});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The visible note. Key: ValueKey('older-version-note:$id').
/// Renders nothing when [version] is null.
class OlderVersionNote extends StatelessWidget {
  final String id;
  final int? version;
  final String? reason;
  const OlderVersionNote(
      {super.key, required this.id, required this.version, this.reason});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
