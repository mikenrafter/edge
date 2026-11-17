part of 'ble_engine.dart';

// Session accounting keeps its existing owner and semantics; moved intact
// so the transport coordinator stays within the file-size limit.


class _SessionPacketCounts {
  final Map<int, int> dataPacketCountsByRevision;
  final int revision16Count;
  final int consoleLogPacketCount;
  final int unknownRevisionCount;
  final int revision19Count;
  final int revision22Count;
  final int revision25Count;
  final int revision26Count;

  const _SessionPacketCounts({
    required this.dataPacketCountsByRevision,
    required this.revision16Count,
    required this.consoleLogPacketCount,
    required this.unknownRevisionCount,
    required this.revision19Count,
    required this.revision22Count,
    required this.revision25Count,
    required this.revision26Count,
  });

  static const zero = _SessionPacketCounts(
    dataPacketCountsByRevision: <int, int>{},
    revision16Count: 0,
    consoleLogPacketCount: 0,
    unknownRevisionCount: 0,
    revision19Count: 0,
    revision22Count: 0,
    revision25Count: 0,
    revision26Count: 0,
  );
}

class _SessionGapSummary {
  final int intraBurst;
  final int crossBurst;
  final int missing;
  final int backward;

  const _SessionGapSummary({
    required this.intraBurst,
    required this.crossBurst,
    required this.missing,
    required this.backward,
  });

  static const zero = _SessionGapSummary(
    intraBurst: 0,
    crossBurst: 0,
    missing: 0,
    backward: 0,
  );

  bool get isEmpty =>
      intraBurst == 0 && crossBurst == 0 && missing == 0 && backward == 0;

  @override
  String toString() {
    if (isEmpty) return 'none';
    final parts = <String>[];
    if (intraBurst > 0) parts.add('intraBurst=$intraBurst');
    if (crossBurst > 0) parts.add('crossBurst=$crossBurst');
    if (missing > 0) parts.add('missing=$missing');
    if (backward > 0) parts.add('backward=$backward');
    return '{${parts.join(', ')}}';
  }
}

class _Session {
  final BluetoothDevice device;
  BluetoothCharacteristic? cmdTo;

  /// Set synchronously at the top of `_teardownSession`, before any await.
  /// The session is still `connected` until its own teardown runs, so
  /// anything holding a reference to it — a live-stream pass that just
  /// discarded a stale completion, a receive callback already in flight —
  /// checks this to stay off the link being closed. Ingress is frozen on it.
  bool closing = false;

  /// Which registered band this link speaks. Defaults to gen4 (WHOOP 4) and is
  /// pinned once during service discovery via [applyBand] — everything that
  /// differs by band (frame header/CRC, GATT UUIDs, command envelope, history
  /// ACK, record field offsets) reads from here.
  BandEntry entry = kWhoopGen4;

  /// This link's frame envelope profile. Owned by [entry]; kept as a getter
  /// because the wire format is `protocol`'s to define, not edge's.
  ///
  /// Non-null by construction: this engine only ever drives framed bands
  /// ([kFramedBands] is what the scan and the discovery match filter on), and
  /// [applyBand] asserts it at the one place an entry gets pinned.
  BandProfile get band => entry.wire!;

  final Map<String, FrameReassembler> asm = {
    'cmd_from': FrameReassembler(),
    'events': FrameReassembler(),
    'data': FrameReassembler(),
  };

  /// Pin this session's band and rebuild the reassemblers with the matching
  /// header shape. Called once, at discovery, before any frame is fed.
  void applyBand(BandEntry e) {
    final w = e.wire;
    // A notify-only sensor has no envelope to reassemble and no command
    // characteristic to write. It reaches the phone through `hrs_link.dart`,
    // never through this engine — see the registry header.
    assert(w != null, 'the offload engine only drives framed bands, not ${e.id}');
    entry = e;
    asm['cmd_from'] = FrameReassembler(profile: w!);
    asm['events'] = FrameReassembler(profile: w);
    asm['data'] = FrameReassembler(profile: w);
  }
  final List<StreamSubscription> subs = [];
  Timer? heartbeat;
  // Session-owned timers; a disconnect cancels them.
  Timer? keepAlive; // 30s: liveness watchdog + battery poll + realtime re-arm
  Timer? periodicBackfill; // 900s: re-trigger the historical offload
  Timer? idleWatchdog; // 60s: strap went silent mid-offload
  Timer? historicalRetry; // explicit abort→retry settle
  /// Armed once opcode 22 went out; ended by the band's first answer for that
  /// task (see [FirstStartWatchdogPolicy]). The idle watchdog only arms on
  /// received traffic, so without this an unanswered request stays "active"
  /// — refusing every later trigger — for as long as the link lives.
  Timer? firstStartWatchdog;
  /// First-START retries this session ([kHistoryNoStartRetriesPerSession]).
  /// Reset by an accepted HISTORY_START.
  int noStartRetries = 0;
  /// Banks the foreign buffer once another client's transfer goes quiet
  /// ([BleEngine._flushForeignBuffer]); re-armed per drained batch with a
  /// foreign record in it.
  Timer? foreignFlushTimer;
  /// Re-requests history once another client's transfer goes quiet, after a
  /// claim of ours stood down for it ([BleEngine._armForeignRetrigger]).
  Timer? foreignRetrigger;
  /// History markers seen for transfers this engine did not request
  /// (diagnostics; the first one logs).
  int foreignMarkersSeen = 0;
  /// The history task generation THIS link requested (opcode 22 / INIT), or
  /// null while no task of ours is open. Compared to the engine's task
  /// generation, so every terminal that bumps it ends ownership without a
  /// reset call; bound to the session, so a reconnect starts with none.
  int? ownedTaskGen;
  /// The generation whose HISTORY_COMPLETE has ARRIVED on this link (set at
  /// receipt, before its handler runs). Until the next claim or abort bumps
  /// the generation, an END may be that task re-offered.
  int? completeReceivedGen;
  /// Our last task on this link is over (its COMPLETE arrived, or it ended
  /// by abort) and no new request of ours has gone out since. Until one
  /// does, the band may still re-offer that task's END or deliver its last
  /// in-flight records — across a claim's pre-request waits too — so they
  /// must not read as another client starting.
  bool ownTaskTail = false;
  /// Another client's transfer on THIS link, judged from the markers we did
  /// not request. Dies with the link like the rest of the ownership state.
  final ForeignHistoryWindow foreignHistory = ForeignHistoryWindow();
  /// No further history task may start on this link
  /// ([BleEngine.endHistoryForLink]): its owner is about to write
  /// configuration and close it. Session-scoped, so the next link starts
  /// unheld without a reset path to forget.
  bool historyHeld = false;
  /// Abort→retry attempts THIS session. The cycle re-arms the 60 s idle
  /// watchdog, which can re-fire the abort, so without a cap a band that
  /// connects but never drains cycles at a fixed period for the life of the
  /// session — every other retry in this engine is bounded, this one was not.
  int historicalRetries = 0;
  // Starts false: we are NOT connected until connect() resolves / the OS
  // connectionState stream reports `connected`. (It was previously initialised
  // true, which combined with the stream replaying a spurious initial
  // `disconnected` aborted setup before the bond-triggering write.)
  bool connected = false;
  // True once we've actually observed a `connected` state. Used to ignore the
  // initial `disconnected` that flutter_blue_plus replays on listen.
  bool sawConnected = false;
  bool intentionalClose = false;
  /// Whether the doc-01 charging follow-up (GET_BATTERY_PACK_INFO) has already
  /// been launched for THIS session. Session-scoped so a second bootstrap on
  /// the same link cannot start a second retry loop against the same band.
  bool batteryPackFollowUpStarted = false;

  /// Terminal `Stuck` latch: set when a burst has
  /// failed validation [kBurstValidationAttemptLimit] times and the abort went
  /// out. From then on this session's history is OVER — no further drain
  /// trigger, and no re-validating a burst the band keeps re-offering.
  /// "Failed validation 15 → terminal Stuck, no same-session retry;
  /// continuation comes from a later connection or scheduler event." Being
  /// session-scoped is the whole mechanism: a reconnect builds a new [_Session]
  /// and the next connection drains normally from the band's checkpoint.
  bool historyStuck = false;

  /// When [historyStuck] latched. Drives [historyStuckActive].
  DateTime? historyStuckAt;

  /// Whether the latch is still refusing work.
  ///
  /// Read this, never [historyStuck] directly, on any path that decides whether
  /// to refuse a drain, drop a marker or suppress a terminal. [historyStuck]
  /// stays true as a session diagnostic ("this connection hit Stuck at least
  /// once") after the window has passed.
  bool get historyStuckActive {
    final at = historyStuckAt;
    if (!historyStuck || at == null) return false;
    return DateTime.now().difference(at) < kHistoryStuckCooldown;
  }

  /// Markers dropped, and drain triggers refused, by [historyStuck]
  /// (diagnostics). Each kind logs its FIRST occurrence and then stays silent:
  /// the band re-offers roughly every 2.5 s, and the whole point of the latch
  /// is to stop that from generating traffic and log noise.
  int stuckMarkersDropped = 0;
  int stuckRefreshesRefused = 0;

  /// The CURRENT history task ended through the abort boundary
  /// ([BleEngine._endHistoryTaskWithAbort]). While set, straggler markers and
  /// frames from that task are inert: they must not re-arm the idle watchdog,
  /// re-raise `_offloadActive` or trigger another abort — a duplicate
  /// HISTORY_END used to keep a wedged task alive indefinitely. Cleared when
  /// the next task is explicitly claimed ([BleEngine._startHistoricalRefresh]);
  /// unlike [historyStuck] it does NOT refuse that claim, so a later
  /// explicit/scheduled task starts cleanly.
  bool historyTaskEnded = false;

  /// Markers dropped by [historyTaskEnded] (diagnostics; first one logs).
  int endedMarkersDropped = 0;

  /// HISTORY_END markers dropped as doc-05 duplicates because they arrived
  /// before the current task's first HISTORY_START (diagnostics; first logs).
  int preStartHistoryEndsDropped = 0;

  _Session(this.device);

  void cancelFirstStartWatchdog() {
    firstStartWatchdog?.cancel();
    firstStartWatchdog = null;
  }

  Future<void> teardown() async {
    heartbeat?.cancel();
    heartbeat = null;
    keepAlive?.cancel();
    keepAlive = null;
    periodicBackfill?.cancel();
    periodicBackfill = null;
    idleWatchdog?.cancel();
    idleWatchdog = null;
    historicalRetry?.cancel();
    historicalRetry = null;
    cancelFirstStartWatchdog();
    foreignFlushTimer?.cancel();
    foreignFlushTimer = null;
    foreignRetrigger?.cancel();
    foreignRetrigger = null;
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    cmdTo = null;
    connected = false;
  }

  /// Inbound notification tally + the post-request capture window (logs only).
  final NotifyDiag rx = NotifyDiag();
}

@visibleForTesting
class BurstStats {
  static const Set<int> _ordinaryHistoricalRevisions = <int>{
    7,
    9,
    10,
    11,
    12,
    18,
    20,
    21,
    24,
  };

  final Map<int, int> _dataPacketCountsByRevision = <int, int>{};
  final Map<int, SequenceState> _sequenceByRevision = <int, SequenceState>{};
  int _eventCount = 0;
  int _consoleCount = 0;
  int _unknownCount = 0;
  int _revision16Count = 0;
  int _revision19Count = 0;
  int _revision22Count = 0;
  int _revision25Count = 0;
  int _revision26Count = 0;

  Map<int, int> get dataPacketCountsByRevision =>
      Map<int, int>.unmodifiable(_dataPacketCountsByRevision);
  Map<int, SequenceState> get sequenceByRevision =>
      Map<int, SequenceState>.unmodifiable(_sequenceByRevision);
  int get eventCount => _eventCount;
  int get consoleCount => _consoleCount;
  int get unknownCount => _unknownCount;
  int get revision16Count => _revision16Count;
  int get revision19Count => _revision19Count;
  int get revision22Count => _revision22Count;
  int get revision25Count => _revision25Count;
  int get revision26Count => _revision26Count;
  int get intraBurstGapCount =>
      _sequenceByRevision.values.fold<int>(0, (sum, s) => sum + s.gapCount);
  int get intraBurstMissing =>
      _sequenceByRevision.values.fold<int>(0, (sum, s) => sum + s.missingCount);
  int get intraBurstBackward => _sequenceByRevision.values.fold<int>(
    0,
    (sum, s) => sum + s.backwardCount,
  );

  int get historicalPacketCount => countHistoricalBurstPackets(
    dataPacketCountsByRevision: _dataPacketCountsByRevision,
    revision16Count: _revision16Count,
    revision19Count: _revision19Count,
    revision22Count: _revision22Count,
    revision25Count: _revision25Count,
    revision26Count: _revision26Count,
  );

  int get totalTrafficPacketCount => countBurstTrafficPackets(
    dataPacketCountsByRevision: _dataPacketCountsByRevision,
    revision16Count: _revision16Count,
    revision19Count: _revision19Count,
    revision22Count: _revision22Count,
    revision25Count: _revision25Count,
    revision26Count: _revision26Count,
    eventCount: _eventCount,
    consoleCount: _consoleCount,
    unknownCount: _unknownCount,
  );

  String get breakdownString {
    final parts = <String>[];
    final revs = _dataPacketCountsByRevision.keys.toList()..sort();
    for (final rev in revs) {
      parts.add('V$rev=${_dataPacketCountsByRevision[rev]}');
    }
    if (_revision16Count > 0) parts.add('V16=$_revision16Count');
    if (_revision19Count > 0) parts.add('V19=$_revision19Count');
    if (_revision22Count > 0) parts.add('V22=$_revision22Count');
    if (_revision25Count > 0) parts.add('V25=$_revision25Count');
    if (_revision26Count > 0) parts.add('V26=$_revision26Count');
    if (_eventCount > 0) parts.add('events=$_eventCount');
    if (_consoleCount > 0) parts.add('console=$_consoleCount');
    if (_unknownCount > 0) parts.add('unknown=$_unknownCount');
    final seq = sequenceSummary;
    if (seq.isNotEmpty) parts.add(seq);
    return '{${parts.join(', ')}}';
  }

  String get sequenceSummary {
    final revs = _sequenceByRevision.keys.toList()..sort();
    final parts = <String>[];
    for (final rev in revs) {
      final s = _sequenceByRevision[rev]!;
      if (s.gapCount > 0 || s.backwardCount > 0 || s.missingCount > 0) {
        parts.add(
          'seqV$rev(gaps=${s.gapCount}, missing=${s.missingCount}, backward=${s.backwardCount})',
        );
      }
    }
    return parts.join(', ');
  }

  /// [revision] is the record version byte (inner[1]), which the caller has
  /// already read off the frame. This used to take the record's hex and parse
  /// the whole thing back into bytes to reach that one byte — a throwaway
  /// buffer per record, on every record of every offload.
  void onHistoricalData(int packetType, int counter, int revision) {
    if (packetType != PacketType.historicalData) return;
    if (revision < 0) {
      _unknownCount++;
      return;
    }
    if (_ordinaryHistoricalRevisions.contains(revision)) {
      _dataPacketCountsByRevision[revision] =
          (_dataPacketCountsByRevision[revision] ?? 0) + 1;
      final seq = _sequenceByRevision.putIfAbsent(
        revision,
        () => SequenceState(firstSequence: counter),
      );
      seq.observe(counter);
      return;
    }
    switch (revision) {
      case 16:
        _revision16Count++;
        return;
      case 19:
        _revision19Count++;
        return;
      case 22:
        _revision22Count++;
        return;
      case 25:
        _revision25Count++;
        return;
      case 26:
        _revision26Count++;
        return;
      default:
        _unknownCount++;
        return;
    }
  }

  void onEvent() => _eventCount++;

  void onConsole() => _consoleCount++;

  void onUnknown() => _unknownCount++;

  void reset() {
    _dataPacketCountsByRevision.clear();
    _sequenceByRevision.clear();
    _eventCount = 0;
    _consoleCount = 0;
    _unknownCount = 0;
    _revision16Count = 0;
    _revision19Count = 0;
    _revision22Count = 0;
    _revision25Count = 0;
    _revision26Count = 0;
  }
}

@visibleForTesting
class SequenceState {
  SequenceState({required this.firstSequence});

  final int firstSequence;
  int? lastSequence;
  int gapCount = 0;
  int missingCount = 0;
  int backwardCount = 0;

  void observe(int seq) {
    final last = lastSequence;
    if (last != null) {
      if (seq > last + 1) {
        gapCount++;
        missingCount += (seq - last) - 1;
      } else if (seq <= last) {
        backwardCount++;
      }
    }
    if (last == null || seq > last) {
      lastSequence = seq;
    }
  }
}
