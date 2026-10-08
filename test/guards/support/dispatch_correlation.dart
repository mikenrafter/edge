// dispatch_correlation.dart — RED STUB: the per-dispatch audit check.
//
// Every dispatch must be matched by the entry reports IT caused (the worker
// echoes the dispatch's id in `EntryEvent.dispatchId`), not by the set of
// entries that ran anywhere in the run. GREEN implements [dispatchCorrelationProblems]:
//   * for each dispatch: the entries reported under its id contain the entry its
//     label maps to (`entryOfLabel`), whose registered dispatcher kind is the
//     dispatch's kind (`dispatcherOf`); an unmapped dispatch must be cancellable
//     and have a cancellable entry under ITS id;
//   * every entry report carries a dispatch id, and that id is one of the
//     dispatches (an entry that ran under another dispatch's token, or under
//     none, is a problem).
// Returns one message per problem; empty = correlated.

import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:openstrap_edge/util/worker_entries.dart';

List<String> dispatchCorrelationProblems(
  List<DispatchEvent> dispatches,
  List<EntryEvent> entries, {
  required Map<String, String> entryOfLabel,
  required Map<String, Dispatcher> dispatcherOf,
  required Set<String> cancellableEntries,
}) =>
    const <String>[];
