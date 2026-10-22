import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/metric.dart';

String olderVersionNoteText(int version, String? reason) {
    final why = whyFromNote(reason);
  return 'From an older calculation (v$version)${why == null ? '' : ': $why'}';
}

String olderVersionSemantics(int version) => 'From an older calculation (v$version)';

class OlderVersionMark extends StatefulWidget {
  final String id;
  final int? version;
  final String? reason;
  const OlderVersionMark({super.key, required this.id, required this.version, this.reason});
  @override
  State<OlderVersionMark> createState() => _OlderVersionMarkState();
}

class _OlderVersionMarkState extends State<OlderVersionMark> {
  bool open = false;
  @override
  Widget build(BuildContext context) {
    final v = widget.version;
    if (v == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    return Semantics(
      label: l?.olderVersionSemantics(v) ?? olderVersionSemantics(v),
      child: GestureDetector(
        key: ValueKey('older-version-mark:${widget.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => open = !open),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('*'),
          if (open) OlderVersionNote(id: widget.id, version: v, reason: widget.reason),
        ]),
      ),
    );
  }
}

class OlderVersionNote extends StatelessWidget {
  final String id;
  final int? version;
  final String? reason;
  const OlderVersionNote({super.key, required this.id, required this.version, this.reason});
  @override
  Widget build(BuildContext context) => version == null
      ? const SizedBox.shrink()
      : _localizedNote(context);

  Widget _localizedNote(BuildContext context) {
    final v = version!;
    final l = AppLocalizations.of(context);
    final why = whyFromNote(reason);
    final note = why == null
        ? (l?.olderVersionNoteNoReason(v) ?? olderVersionNoteText(v, null))
        : (l?.olderVersionNote(v, why) ?? olderVersionNoteText(v, reason));
    return Semantics(
          key: ValueKey('older-version-note:$id'),
          label: l?.olderVersionSemantics(v) ?? olderVersionSemantics(v),
          child: Text(note),
        );
  }
}
