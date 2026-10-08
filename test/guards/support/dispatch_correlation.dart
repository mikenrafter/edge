// dispatch_correlation.dart — the per-dispatch audit check.
//
// Every dispatch must be matched by the entry reports IT caused (the worker
// echoes the dispatch's id in `EntryEvent.dispatchId`), not by the set of
// entries that ran anywhere in the run:
//   * for each dispatch: the entries reported under its id contain the entry its
//     label maps to (`entryOfLabel`), whose registered dispatcher kind is the
//     dispatch's kind (`dispatcherOf`); an unmapped dispatch must be cancellable
//     and have a cancellable entry under ITS id, unless its label starts with
//     one of `legacyInlineLabels`: dispatches whose closure runs inline code, no
//     registered entry (baselined `dispatcherClosureContract` keys; listing one
//     here is the debt, and it shrinks out when the closure becomes an entry);
//   * every entry report carries a dispatch id, and that id is one of the
//     dispatches (an entry that ran under no token, or under a token no dispatch
//     has, is a problem).
// An entry may legitimately report under a dispatch it was not mapped to (an
// inner heavy call in the worker, e.g. kcalMinutesForDayHeavy inside the
// day-blocks worker); only the dispatch -> entry direction is required.
// Returns one message per problem; empty = correlated.

import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:openstrap_edge/util/worker_entries.dart';

List<String> dispatchCorrelationProblems(
  List<DispatchEvent> dispatches,
  List<EntryEvent> entries, {
  required Map<String, String> entryOfLabel,
  required Map<String, Dispatcher> dispatcherOf,
  required Set<String> cancellableEntries,
  List<String> legacyInlineLabels = const [],
}) {
  final problems = <String>[];
  final ids = {for (final d in dispatches) d.id};
  for (final e in entries) {
    final id = e.dispatchId;
    if (id == null) {
      problems.add('entry ${e.entry} reported under no dispatch token');
    } else if (!ids.contains(id)) {
      problems.add('entry ${e.entry} reported under dispatch $id, which was '
          'never dispatched');
    }
  }
  for (final d in dispatches) {
    final mine = {
      for (final e in entries)
        if (e.dispatchId == d.id) e.entry
    };
    final tag = 'dispatch ${d.id} "${d.label}" (${d.kind.name})';
    final want = entryOfLabel[d.label];
    if (want != null) {
      if (!mine.contains(want)) {
        problems.add('$tag ran no $want under its own token (saw $mine)');
      }
      if (dispatcherOf[want] != d.kind) {
        problems.add('$tag: $want is registered as ${dispatcherOf[want]?.name}');
      }
    } else {
      if (d.kind != Dispatcher.cancellable) {
        problems.add('$tag is unmapped and not cancellable');
      }
      final legacy = legacyInlineLabels.any(d.label.startsWith);
      if (!legacy && mine.intersection(cancellableEntries).isEmpty) {
        problems.add('$tag ran no cancellable pipeline entry under its own '
            'token (saw $mine)');
      }
    }
  }
  return problems;
}
