// raw_readers.dart — registry of the LocalDb methods that read raw rows or
// stored payloads (design 02, rev 4/5/7), and the RowBatch type they return.
//
// The registry is the sole authority: no SQL-name fallback. The guard walks
// every LocalDb method; one whose body reaches a raw table name through
// resolvable literals/constants, or calls a registered reader, must itself be
// registered. Iterating a RowBatch outside an @heavy function is flagged.

/// A decoded-row / payload batch. Zero-cost wrapper over an unmodifiable list;
/// the only way to get one is [RowBatch.wrap], so a reader that returns a bare
/// `List<Map<String, Object?>>` is a guard finding.
extension type RowBatch<T extends Map<String, Object?>>._(List<T> _rows)
    implements Iterable<T> {
  /// Wraps [rows] as an unmodifiable snapshot.
  factory RowBatch.wrap(List<T> rows) {
    return RowBatch._(List<T>.unmodifiable(rows));
  }
}

/// A registered raw-row reader. [symbol] is `#LocalDb.getOnehz` style.
class RawReader {
  final Symbol symbol;
  final String reason;
  const RawReader(this.symbol, {required this.reason});
}

/// Registered readers. Step 1 (RED): empty; GREEN lists the real LocalDb
/// readers.
const List<RawReader> kRawReaders = <RawReader>[];
