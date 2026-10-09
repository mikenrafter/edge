// Result of `LocalDb.dayPayload` (design 02, step 2, P2.1).
//
// Sealed rather than a nullable string plus a flag (AGENTS.md section 6,
// "results, not booleans"): the three outcomes need three different reactions
// from the caller. `Stale` in particular is not an error. It means a newer write
// landed between the meta read and the payload read, so the caller restarts from
// the meta once.

/// Outcome of reading one `day_result` payload against an expected revision.
sealed class DayPayloadRead {
  const DayPayloadRead();
}

/// The row exists and its revision equals the one the caller expected.
final class DayPayloadOk extends DayPayloadRead {
  const DayPayloadOk({required this.payloadJson, required this.rev});

  /// The stored `payload_json` text, exactly as it is in the table.
  final String payloadJson;

  /// The revision the row held when the payload was read. Equals the
  /// `expectedRev` the caller passed.
  final int rev;
}

/// No row at that (day, version): deleted, wiped or never written.
final class DayPayloadAbsent extends DayPayloadRead {
  const DayPayloadAbsent();
}

/// The row exists but its revision is no longer the one expected.
final class DayPayloadStale extends DayPayloadRead {
  const DayPayloadStale({required this.currentRev});

  /// The revision the row holds now.
  final int currentRev;
}
