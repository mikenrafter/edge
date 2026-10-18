// heavy.dart — markers for the heavy-calculation guard (design 02).
//
// Pure Dart on purpose: the guard (test/guards/heavy_calc_guard_test.dart)
// resolves these annotations with package:analyzer, including in synthetic
// fixture packages, so this file must not import Flutter or dart:ui.
//
// Heavy = work whose cost grows with stored data (loops over decoded rows,
// decoding or encoding any stored payload, calling an analytics compute
// function). Heavy work runs only inside a registered worker entry
// (lib/util/worker_entries.dart), never on the UI isolate.

/// Marks a function whose cost grows with stored data. The function must be
/// named `…Heavy`, be top-level or static, take sendable arguments, and be
/// reachable only from an approved dispatcher (if it is a registered worker
/// entry) or from other heavy functions.
class Heavy {
  const Heavy();
}

const Heavy heavy = Heavy();

/// Marks bounded, per-packet / per-sample O(1) work that stays on the UI
/// isolate. A `@live` function must not call a heavy function or loop over an
/// unbounded collection, and has a budget test.
class Live {
  const Live();
}

const Live live = Live();

/// Marks a value class that may cross an isolate boundary: every field is
/// itself sendable (checked transitively by the guard).
class Sendable {
  const Sendable();
}

const Sendable sendable = Sendable();

/// Escape hatch on a type that cannot satisfy the closed sendable grammar
/// (for example a payload that carries `Map<String, dynamic>` JSON). The guard
/// requires a round-trip test named `sendable_<entry>_test` for every worker
/// entry whose argument or result type carries this annotation.
class SendableShape {
  final String reason;
  const SendableShape(this.reason);
}
