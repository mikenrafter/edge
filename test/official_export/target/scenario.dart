// Literals shared by the fork-side fixture writer and the tagged-receiver
// probes. Plain Dart with NO package imports: the receiver probes are copied
// into the immutable v0.12.2 source package, which has none of the fork's code.
//
// All instants are UTC and the process zone must be UTC (the probes assert it).
// Epochs were computed with an independent zone database (python zoneinfo).

const d1Epoch = 1792454400; // 2026-10-20T00:00:00Z
const secondsPerDay = 86400;
int dayStartEpoch(int n) => d1Epoch + (n - 1) * secondsPerDay;

/// Day labels used by the boundary scenario.
const d3 = '2026-10-22', d4 = '2026-10-23', d5 = '2026-10-24';

/// The fork's live prune cursor in the rich fixture: d9 00:00Z.
final int fixtureForkCursor = dayStartEpoch(9);

/// The oldest exact second in the mapped decoded rows: d3 12:00Z, so d3 is a
/// partial first day and d4..d8 are complete archive-restored days.
final int fixtureOldestExact = dayStartEpoch(3) + 12 * 3600;

/// The carried cursor the spec requires: first midnight at or after the oldest
/// exact second, below the fork cursor, so d4 00:00Z.
final int fixtureExpectedCursor = dayStartEpoch(4);

/// What the unchanged v0.12.2 receiver must report after importing a payload
/// that carries [fixtureExpectedCursor] into a fresh target:
/// `decodedPrunedFor` (day wholly below the cut, so labelled deleted) and
/// `windowTruncatedByPrune` (day's derive window starts 12 h before its midnight,
/// below the cut, so the day abstains).
const expectedDeletedStatus = {d3: true, d4: false, d5: false};
const expectedAbstains = {d3: true, d4: true, d5: false};

/// The populated official target's own definition and the fork's different one.
const unitKeyCollision = 'custom_caffeine';
