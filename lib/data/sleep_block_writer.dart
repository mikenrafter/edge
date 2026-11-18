// sleep_block_writer.dart — transaction-level sleep block writes: the spacing
// guard, the explicit merge, and history-preserving tombstones.
//
// ONE owner beneath the two table writers (`_ldbPutNapEdit` /
// `_ldbDeleteNapEdit` / `_ldbPutSleepOverride`), ActivityStore.confirm and the
// editor's `SleepEditorWrite.apply`. Nothing here opens its own transaction:
// every function takes the caller's [DatabaseExecutor] so the assertion,
// suppression origin, revisions and the job commit together.
//
// CLAIM(sleep-block-separation), CLAIM(sleep-block-explicit-merge),
// CLAIM(sleep-editor-nap-key).

import 'package:sqflite/sqflite.dart';

import 'activity_store.dart';
import 'nap_resolution.dart';
import 'sleep_edit_codec.dart';
import 'sleep_edit_store.dart';
import 'sleep_editor.dart';
import 'sleep_spacing.dart';

/// A stored sleep row as the writer reads it.
typedef StoredSleepRow = ({
  SleepBlockKind kind,
  String day,
  int startTs,
  int endTs,
  String source,
  String? payload,
});

class SleepBlockWriter {
  const SleepBlockWriter._();

  // ── Reads ───────────────────────────────────────────────────────────────

  /// Live blocks within the minimum gap of [s]..[e].
  static Future<List<SleepBlock>> liveNear(
      DatabaseExecutor tx, int s, int e) async => [
        for (final b in await NapResolver.near(tx, s, e, margin: kMinSleepGapSec))
          SleepBlock(
            kind: b.kind == 'main_sleep' ? SleepBlockKind.main : SleepBlockKind.nap,
            day: b.day,
            startTs: b.startTs,
            endTs: b.endTs,
          ),
      ];

  static Future<StoredSleepRow?> napRow(
      DatabaseExecutor tx, String day, int startTs) async {
    final rows = await tx.query('sleep_nap',
        where: 'day_id = ? AND start_ts = ?', whereArgs: [day, startTs]);
    if (rows.isEmpty) return null;
    final r = rows.single;
    return (
      kind: SleepBlockKind.nap,
      day: day,
      startTs: startTs,
      endTs: r['end_ts'] as int,
      source: r['source'] as String,
      payload: r['payload_json'] as String?,
    );
  }

  static Future<StoredSleepRow?> mainRow(DatabaseExecutor tx, String day) async {
    final rows =
        await tx.query('sleep_override', where: 'day_id = ?', whereArgs: [day]);
    if (rows.isEmpty) return null;
    final r = rows.single;
    return (
      kind: SleepBlockKind.main,
      day: day,
      startTs: r['onset_ts'] as int,
      endTs: r['offset_ts'] as int,
      source: r['source'] as String,
      payload: r['payload_json'] as String?,
    );
  }

  // ── The guard ────────────────────────────────────────────────────────────

  /// The merge [changes] would need, or null; writes nothing and never throws
  /// for spacing (UI preflight shares this with [guard]).
  static Future<SleepMergeProposal?> preflight(
    DatabaseExecutor tx, {
    required List<BlockChange> changes,
    required String editingDay,
  }) async {
    final afters = [for (final c in changes) if (c.after != null) c.after!];
    if (afters.isEmpty) return null; // removals only widen gaps
    var s = afters.first.startTs, e = afters.first.endTs;
    for (final b in afters) {
      if (b.startTs < s) s = b.startTs;
      if (b.endTs > e) e = b.endTs;
    }
    return SleepSpacing.evaluate(
        stored: await liveClosure(tx, s, e),
        changes: changes,
        editingDay: editingDay);
  }

  /// [liveNear] widened until no further live block is within the minimum gap
  /// of what was found, so a chain (A near B near C) is seen whole.
  static Future<List<SleepBlock>> liveClosure(
      DatabaseExecutor tx, int s, int e) async {
    var lo = s, hi = e;
    while (true) {
      final found = await liveNear(tx, lo, hi);
      var nlo = lo, nhi = hi;
      for (final b in found) {
        if (b.startTs < nlo) nlo = b.startTs;
        if (b.endTs > nhi) nhi = b.endTs;
      }
      if (nlo == lo && nhi == hi) return found;
      lo = nlo;
      hi = nhi;
    }
  }

  /// Decides whether [changes] need an explicit Merge. Returns null when the
  /// change is clear, the approved proposal when [merge] matches it, and throws
  /// [SleepMergeRequiredException] (nothing written) otherwise.
  static Future<SleepMergeProposal?> guard(
    DatabaseExecutor tx, {
    required List<BlockChange> changes,
    required String editingDay,
    SleepMergeAuthorization? merge,
  }) async {
    final proposal =
        await preflight(tx, changes: changes, editingDay: editingDay);
    if (proposal == null) return null;
    if (merge != null && merge == proposal.authorization) return proposal;
    throw SleepMergeRequiredException(proposal);
  }

  // ── Envelope helpers ────────────────────────────────────────────────────

  /// The retained measurement keys and envelope of [row], capturing the
  /// detected snapshot the first time an automatic/retained entry is changed.
  static Future<({Map<String, Object?> retained, SleepEditEnvelope envelope})>
      historyOf(StoredSleepRow row) async {
    final read = await SleepEditCodec.read(row.payload);
    if (read is EnvelopeOk) {
      return (retained: read.retained, envelope: read.envelope);
    }
    final retained = read.retained;
    final DetectedHistory detected;
    if (row.source == 'manual') {
      detected = const DetectedAbsent();
    } else if (row.source == 'rejected' && retained.isEmpty) {
      detected = const DetectedUnavailable('no history recorded');
    } else if (retained.isNotEmpty ||
        row.source == 'confirmed' ||
        row.source == 'legacy' ||
        row.kind == SleepBlockKind.main) {
      detected = DetectedKnown(
        startTs: row.startTs,
        endTs: row.endTs,
        sourceDay: row.day,
        measures: retained,
      );
    } else {
      detected = const DetectedUnavailable('no history recorded');
    }
    return (retained: retained, envelope: SleepEditEnvelope(detected: detected));
  }

  /// [env] with [interval] added to its suppression list (deduplicated).
  static SleepEditEnvelope suppressing(
      SleepEditEnvelope env, SuppressedInterval interval) {
    final all = [...env.origin.suppressed];
    if (!all.any((s) =>
        s.day == interval.day &&
        s.startTs == interval.startTs &&
        s.endTs == interval.endTs)) {
      all.add(interval);
    }
    return SleepEditEnvelope(
      origin: OriginRef(suppressed: all, mergedInto: env.origin.mergedInto),
      detected: env.detected,
      stages: env.stages,
    );
  }

  /// Whether [env] remembers a real detection (so its old window must stay
  /// suppressed when the entry moves or is replaced).
  static bool _hasDetection(SleepEditEnvelope env) =>
      env.detected is DetectedKnown;

  // ── Nap rows ─────────────────────────────────────────────────────────────

  /// Writes the live nap [day]/[startTs]..[endTs] with [source], CARRYING the
  /// history of whatever the key held: a tombstone's detected snapshot and
  /// suppression survive the replacement (remove detected -> add manual at the
  /// same start -> remove manual keeps the original). [incoming] is the
  /// retained payload and envelope of a block that moves here from another key.
  static Future<void> putNapRow(
    DatabaseExecutor tx, {
    required String day,
    required int startTs,
    required int endTs,
    required String source,
    Map<String, Object?> retained = const {},
    SleepEditEnvelope? envelope,
    int? createdAt,
  }) async {
    final existing = await napRow(tx, day, startTs);
    var env = envelope;
    var keep = retained;
    if (existing != null) {
      final h = await historyOf(existing);
      if (env == null) {
        env = h.envelope;
        // An unchanged live row keeps its own measurements; a replaced
        // tombstone's measurement belongs to the DETECTION, which the
        // envelope's snapshot already holds.
        if (existing.source != 'rejected' &&
            existing.endTs == endTs &&
            retained.isEmpty) {
          keep = h.retained;
        }
      }
      if (existing.source == 'rejected') {
        // Never silently REPLACE a tombstone: its interval stays suppressed.
        env = suppressing(env,
            SuppressedInterval(day, existing.startTs, existing.endTs));
      }
    }
    final payload = (env == null && keep.isEmpty)
        ? null
        : env == null
            ? await SleepEditCodec.write(keep, const SleepEditEnvelope())
            : await SleepEditCodec.write(keep, env);
    await tx.insert(
      'sleep_nap',
      {
        'day_id': day,
        'start_ts': startTs,
        'end_ts': endTs,
        'source': source,
        'created_at': createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'payload_json': payload,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Turns the live nap at [day]/[startTs] into a tombstone that keeps its
  /// pre-removal bounds in the row and its prior payload plus detected
  /// snapshot in the envelope. [mergedInto] marks an absorbed block.
  static Future<void> tombstoneNap(
    DatabaseExecutor tx, {
    required String day,
    required int startTs,
    int? endTs,
    String? mergedInto,
  }) async {
    final row = await napRow(tx, day, startTs);
    if (row == null) {
      // Suppressing a detection that has no stored row yet.
      if (endTs == null) return;
      await tx.insert(
        'sleep_nap',
        {
          'day_id': day,
          'start_ts': startTs,
          'end_ts': endTs,
          'source': 'rejected',
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'payload_json': null,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return;
    }
    final h = await historyOf(row);
    var env = h.envelope;
    if (mergedInto != null) {
      env = SleepEditEnvelope(
        origin: OriginRef(
            suppressed: env.origin.suppressed, mergedInto: mergedInto),
        detected: env.detected,
        stages: env.stages,
      );
      if (_hasDetection(env)) {
        env = suppressing(env, SuppressedInterval(day, row.startTs, row.endTs));
      }
    }
    await tx.insert(
      'sleep_nap',
      {
        'day_id': day,
        'start_ts': startTs,
        'end_ts': row.endTs,
        'source': 'rejected',
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        // An existing tombstone keeps its payload byte for byte.
        'payload_json': row.source == 'rejected' && mergedInto == null
            ? row.payload
            : await SleepEditCodec.write(h.retained, env),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ── Main rows ────────────────────────────────────────────────────────────

  static Future<void> putMainRow(
    DatabaseExecutor tx, {
    required String day,
    required int onsetTs,
    required int offsetTs,
    required String source,
    SleepEditEnvelope? envelope,
  }) async {
    final existing = await mainRow(tx, day);
    var env = envelope;
    if (env == null) {
      if (existing != null) {
        env = (await historyOf(existing)).envelope;
      } else {
        // First accepted mutation of an automatic main: capture the served
        // detected window before the override replaces it.
        final near = await liveNear(tx, onsetTs, offsetTs);
        final det = near
            .where((b) => b.kind == SleepBlockKind.main && b.day == day)
            .firstOrNull;
        env = SleepEditEnvelope(
          detected: det == null
              ? const DetectedAbsent()
              : DetectedKnown(
                  startTs: det.startTs, endTs: det.endTs, sourceDay: day),
        );
      }
    }
    await tx.insert(
      'sleep_override',
      {
        'day_id': day,
        'onset_ts': onsetTs,
        'offset_ts': offsetTs,
        'source': source,
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'payload_json': await SleepEditCodec.write(
            existing == null ? const {} : (await historyOf(existing)).retained,
            env),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await tx.delete('wake_confirmation', where: 'day_id = ?', whereArgs: [day]);
  }

  // ── Explicit merge ───────────────────────────────────────────────────────

  /// Commits an APPROVED [proposal]: the survivor takes the union, every
  /// absorbed block becomes a tombstone naming the survivor, and every
  /// affected ownership date is queued, all in the caller's transaction.
  /// Returns the affected days.
  static Future<Set<String>> applyMerge(
      DatabaseExecutor tx, SleepMergeProposal proposal) async {
    final survivor = proposal.survivor;
    final stored = <SleepBlock, StoredSleepRow?>{};
    for (final b in proposal.participants) {
      stored[b] = b.kind == SleepBlockKind.main
          ? await mainRow(tx, b.day)
          : await napRow(tx, b.day, b.startTs);
    }
    // The survivor's detected history: the union of every participant's
    // snapshot when ALL are known, otherwise explicitly unavailable.
    var union = <DetectedKnown>[];
    var allKnown = true;
    final suppressed = <SuppressedInterval>[];
    for (final b in proposal.participants) {
      final row = stored[b];
      final SleepEditEnvelope env;
      if (row != null) {
        env = (await historyOf(row)).envelope;
      } else {
        // An automatic main without an override: its detection is its window.
        env = SleepEditEnvelope(
            detected: DetectedKnown(
                startTs: b.startTs, endTs: b.endTs, sourceDay: b.day));
      }
      suppressed.addAll(env.origin.suppressed);
      final d = env.detected;
      if (d is DetectedKnown) {
        union.add(d);
        suppressed.add(SuppressedInterval(b.day, b.startTs, b.endTs));
      } else {
        allKnown = false;
      }
    }
    final detected = allKnown && union.isNotEmpty
        ? DetectedKnown(
            startTs: union.map((d) => d.startTs).reduce((a, b) => a < b ? a : b),
            endTs: union.map((d) => d.endTs).reduce((a, b) => a > b ? a : b),
            sourceDay: survivor.day,
          )
        : const DetectedUnavailable('a merged block had no detection');
    final env = SleepEditEnvelope(
      origin: OriginRef(suppressed: suppressed),
      detected: detected,
    );

    // Absorbed first, so a survivor moving onto an absorbed key replaces a
    // tombstone that already carries its origin.
    for (final b in proposal.absorbed) {
      if (b.kind == SleepBlockKind.nap) {
        await tombstoneNap(tx,
            day: b.day, startTs: b.startTs, mergedInto: survivor.key);
      } else {
        final row = stored[b];
        final h = row == null
            ? SleepEditEnvelope(
                detected: DetectedKnown(
                    startTs: b.startTs, endTs: b.endTs, sourceDay: b.day))
            : (await historyOf(row)).envelope;
        await tx.insert(
          'sleep_override',
          {
            'day_id': b.day,
            'onset_ts': b.startTs,
            'offset_ts': b.endTs,
            'source': 'rejected',
            'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'payload_json': await SleepEditCodec.write(const {},
                SleepEditEnvelope(
                  origin: OriginRef(
                      suppressed: h.origin.suppressed,
                      mergedInto: survivor.key),
                  detected: h.detected,
                )),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }
    if (survivor.kind == SleepBlockKind.main) {
      await putMainRow(tx,
          day: survivor.day,
          onsetTs: proposal.startTs,
          offsetTs: proposal.endTs,
          source: 'manual',
          envelope: env);
    } else {
      if (proposal.startTs != survivor.startTs) {
        await tx.delete('sleep_nap',
            where: 'day_id = ? AND start_ts = ?',
            whereArgs: [survivor.day, survivor.startTs]);
      }
      await putNapRow(tx,
          day: survivor.day,
          startTs: proposal.startTs,
          endTs: proposal.endTs,
          source: 'manual',
          envelope: env);
    }
    final days = proposal.affectedDays;
    for (final d in days) {
      await ActivityStore.markDayChanged(tx, d);
      await SleepEditStore.enqueue(tx, d);
    }
    return days;
  }
}
