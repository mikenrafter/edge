// Shared helpers for the GestureController tests. Everything goes
// through AppState's public and @visibleForTesting surface, so the same files
// serve the AppState-level tests and the controller's own tests.
//
// A strap double tap travels the real path: an EVENT frame handed to the
// engine's immediate-frame handler (the engine's onEvent is AppState._onLiveEvent
// in AppState.forTesting), through the GestureDispatcher, the claim ledger (a
// real LocalDb over sqflite_ffi), the native-action channel (mocked here), the
// cue deliveries (AlertDispatcher -> haptics queue -> the fake link's writes)
// and the tap ack. Nothing is replaced inside the gesture area.
//
// The band is a gen5 fake link. Every command it receives is recorded and
// acknowledged from inside the write (like test/ecg_ble_engine_test.dart). A
// haptic write is followed 2 ms later by the band's own "ended" event so the
// haptics queue moves at test speed. [GestureRig.cueOf] names a haptic write
// by comparing its body with what each gesture cue writes, measured once per
// rig, so the tests never hard-code a vibration pattern.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/ecg/ble_ecg_transport.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart';
import 'package:openstrap_edge/ecg/ecg_guard_store.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_transport.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart' show TapCountMethod;
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show PairedDevice;
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'ecg_presence_packets.dart' show presencePacket;

export 'ecg_presence_packets.dart' show presencePacket;

import 'app_state_derive_harness.dart' show settleMs, until;

export 'app_state_derive_harness.dart'
    show deriveDbSetUp, deriveDbTearDown, settleMs, until, TickCounter, TimerSpy;
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String kSerial = '5AM0000000';

/// One command that reached the fake radio.
typedef GWrite = ({int opcode, List<int> body});

Decoded _ack(int seq, int opcode) => Decoded('cmd_response', {
      'opcode': opcode,
      'req_seq': seq,
      'cmd_status': CommandAwaiter.statusSuccess,
    });

Uint8List _helloBody() {
  final body = Uint8List(Gen5HelloInfo.semanticBodyLen);
  final v = ByteData.sublistView(body);
  body[0] = 1; // revision 1 + optical 0 = a WHOOP MG
  v.setUint32(1, 900, Endian.little);
  v.setUint32(6, DateTime.now().millisecondsSinceEpoch ~/ 1000, Endian.little);
  for (var i = 0; i < 10; i++) {
    body[14 + i] = '5AM0000000'.codeUnitAt(i);
  }
  v.setUint32(79, 13, Endian.little);
  v.setUint32(87, 0, Endian.little);
  body[91] = 50;
  body[92] = 41;
  body[93] = 1;
  body[102] = 1;
  return body;
}

Decoded _helloReply(int seq) => Decoded('cmd_response', {
      'opcode': Cmd.getHello,
      'req_seq': seq,
      'cmd_status': CommandAwaiter.statusSuccess,
      'gen5_hello': Gen5HelloInfo.parse(_helloBody())!,
    });

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Native actions the app asked the platform for, in order. The channel
/// answers [ok] (false makes every native action fail).
class ActionChannel {
  ActionChannel({this.ok = true, this.order}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ch, (call) async {
      if (call.method == 'perform') {
        final id = (call.arguments as Map)['action'] as String;
        performed.add(id);
        order?.add('action:$id');
        // A native action that answers late: the test lets it go.
        final h = hold;
        if (h != null) await h.future;
        return ok;
      }
      return <String>[];
    });
  }
  static const MethodChannel _ch = MethodChannel('openstrap/device_actions');
  final performed = <String>[];
  final List<String>? order;
  bool ok;

  /// When set, every `perform` waits for it before it answers.
  Completer<void>? hold;
  void dispose() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_ch, null);
}

/// An EcgController over a transport that records its calls into [order] and
/// [begins]; every begin() is remembered with the persist flag the gesture
/// passed.
class SpyEcg extends EcgController {
  SpyEcg._(this._t, this.guardStore, bool keep)
      : super(
          transport: _t,
          guard: guardStore,
          save: (r, p) async {},
          busyReason: () => null,
          holdScreen: (o) async {},
          releaseScreen: (o) async {},
          keepWaveform: () => keep,
        );

  /// [keep] is the wearer's "Keep waveform" choice, which also decides whether
  /// a gesture's PREPARE asks the band for its raw save.
  factory SpyEcg(
    List<String> order, {
    bool remembersWrist = true,
    bool keep = false,
  }) {
    final guard = MemoryEcgGuardStore();
    if (remembersWrist) guard.wrists[kSerial] = EcgWrist.left;
    return SpyEcg._(_SpyTransport(order), guard, keep);
  }

  final _SpyTransport _t;
  final MemoryEcgGuardStore guardStore;

  /// The `persist` flag of every begin().
  final begins = <bool>[];

  /// The members of every PREPARE the transport answered, in order.
  List<List<String>> get prepares => _t.prepares;
  int get cleanups => _t.cleanups;

  @override
  Future<void> begin(
    EcgWrist wrist, {
    bool persist = true,
    void Function(String line)? trace,
  }) {
    begins.add(persist);
    return super.begin(wrist, persist: persist, trace: trace);
  }
}

class _SpyTransport implements EcgTransport {
  _SpyTransport(this.order);
  final List<String> order;
  final prepares = <List<String>>[];
  int cleanups = 0;
  EcgLeaseHandle? current;
  final _events = StreamController<EcgTransportEvent>.broadcast();

  EcgCommandListResult _ok(List<String> labels) => EcgCommandListResult([
        for (final l in labels)
          EcgMemberOutcome(l, written: true, succeeded: true),
      ]);

  @override
  bool get isReady => true;
  @override
  bool get isMaverick => true;
  @override
  int get linkGeneration => 7;
  @override
  String? get serial => kSerial;
  @override
  Stream<EcgTransportEvent> get events => _events.stream;
  @override
  EcgLeaseHandle? acquire() =>
      current == null ? current = EcgLeaseHandle(Object(), 7) : null;
  @override
  bool leaseValid(EcgLeaseHandle lease) => identical(current, lease);
  @override
  void release(EcgLeaseHandle lease) {
    if (identical(current, lease)) current = null;
  }

  @override
  Future<void> cancelHistory(EcgLeaseHandle lease) async {}
  @override
  Future<EcgCommandListResult> prepare(
    EcgLeaseHandle lease,
    EcgWrist wrist, {
    bool rawSave = true,
  }) async {
    order.add('ecg:prepare');
    final members = ['selectWrist', 'filteredOn', if (rawSave) 'rawSaveOn'];
    prepares.add(members);
    return _ok(members);
  }

  @override
  Future<EcgCommandListResult> start(EcgLeaseHandle lease) async {
    order.add('ecg:start');
    return _ok(['abortHistorical', 'generationStart']);
  }

  @override
  Future<EcgCommandListResult> restart(EcgLeaseHandle lease) async =>
      _ok(['abortHistorical', 'generationRestart']);
  @override
  Future<EcgCommandListResult> cleanup(EcgLeaseHandle lease) async {
    order.add('ecg:cleanup');
    cleanups++;
    return _ok(['generationStop', 'filteredOff', 'rawSaveOff']);
  }

  @override
  Future<void> requestSync() async {}
}

/// An AppState on a gen5 fake link, plus everything a gesture test reads.
class GestureRig {
  /// [dev] is developer mode, which the ECG gestures need on top of an MG; it
  /// follows [mg] unless a test says otherwise.
  GestureRig(
      {this.mg = true, bool? dev, EcgController? ecg, List<String>? order}) {
    Prefs.setBool(Prefs.devMode, dev ?? mg);
    final trace = this.order = order ?? <String>[];
    app = AppState.forTesting(ecg: ecg);
    engine = app.engine;
    engine.debugInstallFakeLink(
      band: BandProfile.gen5,
      listening: true,
      onWrite: (Uint8List frame) async {
        final inner = parseFrame(frame, profile: BandProfile.gen5)!.inner;
        final w = (opcode: inner[2], body: inner.sublist(3));
        writes.add(w);
        trace.add(_label(w));
        engine.debugAbsorbDecoded(_ack(inner[1], inner[2]));
        if (_isHaptic(w.opcode)) {
          // The band's own "ended" event, so the queue does not wait out the
          // pattern's playback.
          Timer(const Duration(milliseconds: 2), _signalEnded);
        }
        return true;
      },
    );
    app.paired = PairedDevice('AA:BB:CC:DD:EE:FF', kSerial);
    engine.state.generation = 'gen5';
    engine.state.connection = 'connected';
    if (mg) engine.debugAbsorbDecoded(_helloReply(99));
  }

  final bool mg;
  late final List<String> order;
  late final AppState app;
  late final BleEngine engine;
  final writes = <GWrite>[];
  final _cueBodies = <String, String>{};
  int _tapSeq = 0;
  int _lastSec = 0;
  bool _disposed = false;

  static bool _isHaptic(int op) =>
      op == Cmd.runHapticPatternMaverick || op == Cmd.runHapticsPattern;

  String _label(GWrite w) {
    if (_isHaptic(w.opcode)) return 'cue:${cueOf(w)}';
    if (w.opcode == Cmd.selectWrist) return 'band:selectWrist';
    if (w.opcode == Cmd.toggleLabradorRawSave) return 'band:rawSave';
    if (w.opcode == Cmd.toggleLabradorFiltered) return 'band:filtered';
    if (w.opcode == Cmd.toggleLabradorDataGeneration) return 'band:generation';
    return 'band:${w.opcode}';
  }

  /// The gesture cue a haptic write plays: start, followUp, confirm, failed,
  /// or `?` for anything else. Needs [measureCues] first.
  String cueOf(GWrite w) {
    final hex = _hex(w.body);
    for (final e in _cueBodies.entries) {
      if (e.value == hex) return e.key;
    }
    return '?';
  }

  /// The body (hex) a gesture cue writes on this band with the built-in
  /// patterns; null before [measureCues].
  String? defaultCueBody(String cue) => _cueBodies[cue];

  void _signalEnded() {
    if (_disposed) return;
    final now = DateTime.now();
    app.haptics.onBandEvent(StrapEvent(
      eventId: 100,
      tsEpoch: now.millisecondsSinceEpoch ~/ 1000,
      receivedAt: now,
      hex: '',
      deviceId: '',
    ));
  }

  Future<void> _deviceRowLanded() async {
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      final db = await LocalDb.instance;
      final rows = await db.query('device',
          columns: ['adapter_id'],
          where: 'id = ?',
          whereArgs: [LocalDb.kPrimaryDeviceId]);
      if (rows.isNotEmpty && rows.first['adapter_id'] != null) return;
      if (!DateTime.now().isBefore(end)) {
        throw TestFailure('the primary device row never got an adapter_id '
            '(rows: $rows)');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Play each gesture cue once on this band and remember the body it writes.
  /// Call before any gesture; the writes it makes are cleared afterwards. A
  /// WHOOP MG rig also chooses the ECG counting method here (the app's default
  /// is repeated double taps), so its gestures take the ECG route; a test that
  /// wants double taps on it sets [TapCountMethod.repeat] afterwards.
  Future<void> measureCues() async {
    if (mg) {
      await app.gestureSettings.setTapMethod(TapCountMethod.ecg);
    }
    // The hello answer starts a device-row write (insert, then the update
    // that sets the band's family); wait for it to land before a test can
    // finish and close the database. A rig with no hello writes nothing, so
    // it has nothing to wait for. Polled, not slept: how long the two
    // statements take depends on how busy the machine is.
    if (mg) await _deviceRowLanded();
    final plays = <String, Future<dynamic> Function()>{
      'start': app.gestureCues.start,
      'followUp': app.gestureCues.followUp,
      'confirm': app.gestureCues.confirm,
      'failed': app.gestureCues.failed,
    };
    for (final e in plays.entries) {
      final before = writes.length;
      await e.value();
      final w = writes.skip(before).where((w) => _isHaptic(w.opcode));
      if (w.isNotEmpty) _cueBodies[e.key] = _hex(w.first.body);
    }
    writes.clear();
    order.clear();
  }

  /// The cues written so far, in order (start / followUp / confirm / failed).
  List<String> get cues => [
        for (final w in writes)
          if (_isHaptic(w.opcode)) cueOf(w),
      ];

  /// How far [advance] has moved the strap clock ahead of the phone's.
  Duration _ahead = Duration.zero;

  /// The strap clock taps are stamped with by default: the real clock plus
  /// [advance]. The engine stamps receipt with the real clock, so an advanced
  /// tap reads as a few seconds in the strap's future: still plausible
  /// (within kMaxStrapFutureSkew) and live.
  DateTime get now => DateTime.now().add(_ahead);

  int get nowSec => now.millisecondsSinceEpoch ~/ 1000;

  /// Move the strap clock forward (upstream's rig moved its fake dispatcher
  /// clock; the merged dispatcher judges recency and debounce on the event's
  /// own times, so the strap clock is the one a test can move).
  void advance(Duration d) => _ahead += d;

  void _sendEvent(int id, int sec) {
    final inner = Uint8List(12);
    final v = ByteData.sublistView(inner);
    inner[0] = PacketType.event;
    inner[1] = 0x07;
    v.setUint16(2, id, Endian.little);
    v.setUint32(4, sec, Endian.little);
    v.setUint16(8, 100 + 37 * _tapSeq, Endian.little);
    v.setUint16(10, 0, Endian.little);
    engine.debugProcessImmediateFrame(Frame(inner, true, true));
  }

  /// Hand the engine one band double tap, exactly as the radio does. Every call
  /// is a distinct tap (own strap sub-second), received now.
  void doubleTap({int? atSec, bool resend = false}) {
    final sec = resend ? _lastSec : atSec ?? nowSec;
    _lastSec = sec;
    if (!resend) _tapSeq++;
    _sendEvent(14, sec);
  }

  /// Hand the engine one band event [id], a distinct one (own strap
  /// sub-second). [atSec] is the strap's own timestamp (default: [nowSec]).
  void event(int id, {int? atSec}) {
    _tapSeq++;
    _sendEvent(id, atSec ?? nowSec);
  }

  /// A double tap whose strap timestamp is [age] behind [now].
  void doubleTapAged(Duration age) => doubleTap(atSec: nowSec - age.inSeconds);

  /// Map the plain double tap to [a] alone.
  Future<void> map(DeviceAction a) =>
      app.gestureSettings.setDoubleTapActions({a});

  /// One live R17 packet into the ECG controller the way the engine hands it
  /// over (the transport the real AppState built over this engine).
  void feedEcg(LabradorR17 r) {
    final t = app.ecg.transport as BleEngineEcgTransport;
    t.onEngineEvent(EcgFrameEvent(r, engine.linkGeneration));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    app.dispose();
    BleEngine.resetBandClaimForTest();
  }
}

/// The Device lab's log as the gesture sessions write it.
String labText(GestureRig rig) =>
    rig.app.deviceLab.toPlainText(withPackets: false);

int labCount(GestureRig rig, String needle) =>
    needle.allMatches(labText(rig)).length;

/// The opening of an ECG gesture the way the band delivers it, on the real
/// clock: [steady] packets of one second of finger contact (or none, when
/// [finger] is false), each fed 450 ms after the last (the stream runs ahead of
/// the wall clock, inside the readiness step tolerance), so the stream is
/// steady and the sensor has settled by the last one. A first packet with no
/// finger is the quick start: the count is decided as 2 at once. Returns the
/// next strap second.
Future<int> feedEcgOpening(void Function(LabradorR17) feed,
    {int sec = 1000, int steady = 3, bool finger = true}) async {
  for (var i = 0; i < steady; i++) {
    feed(presencePacket(sec++, presence: finger, contact: finger));
    await settleMs(450);
  }
  return sec;
}

/// An ECG gesture's packets for a count of [n] (2..5) through the accurate
/// path: the opening ([feedEcgOpening], finger on the sensor, or none for 2),
/// then one lift and one touch per further count, waiting for each follow-up
/// cue to finish before the next touch, then quiet packets until the gesture
/// ends. Stops feeding the moment the session reports its final count.
Future<void> playEcgCount(GestureRig rig, int n) async {
  bool done() => labCount(rig, 'Final count') > 0;
  var sec = await feedEcgOpening(rig.feedEcg, finger: n > 2);
  for (var i = 0; i < n - 3 && !done(); i++) {
    rig.feedEcg(presencePacket(sec++)); // the lift, while the cue plays
    await until(() => labCount(rig, 'Follow-up cue played') > i);
    await settleMs(5);
    rig.feedEcg(presencePacket(sec++, presence: true, contact: true));
    await settleMs(20);
  }
  for (var i = 0; i < 14 && !done(); i++) {
    rig.feedEcg(presencePacket(sec++));
    await settleMs(150);
  }
}

/// Forget what an earlier test left in the static Prefs cache for the gesture
/// area (Prefs has no reset; it is loaded once per test file).
Future<void> resetGesturePrefs() async {
  await Prefs.ensureLoaded();
  Prefs.setString(Prefs.gestureFailures, '');
  Prefs.setString(Prefs.hapticsCueAssign, '');
}

/// Mapped actions for 2..5 taps, each a different native action so the one
/// that ran names the count.
const kActionFor = <int, DeviceAction>{
  2: DeviceAction.mediaPlayPause,
  3: DeviceAction.mediaNext,
  4: DeviceAction.volumeUp,
  5: DeviceAction.torch,
};

Future<void> mapActions(AppState app, Iterable<int> counts) async {
  for (final n in counts) {
    await app.gestureSettings.setActionsForTaps(n, {kActionFor[n]!});
  }
}

// ── from upstream's copy of this harness (merge: union of both sides) ──

// Shared helpers for the AppState band-gesture tests. Everything goes through
// AppState's public and @visibleForTesting surface (plus the dispatcher's
// clock hook), so the same files keep passing wherever the dispatcher lives.
//
// A strap double tap travels the real path: an EVENT frame handed to the
// engine's immediate-frame handler (the engine's onEvent is AppState's live
// event entry in AppState.forTesting), then event persistence (a real LocalDb
// over sqflite_ffi), the alarm handler, the GestureDispatcher, and either the
// native-action channel (mocked here) or one of AppState's three in-app
// handlers (a fake journal repository and the haptics channel are mocked).
//
// The dispatcher's recency window and debounce read a clock; the rig replaces
// it with a fake one so a test can place a tap exactly at a boundary.



/// EventId.doubleTap, the only event the dispatcher acts on.
const int kDoubleTapEventId = 14;

Future<void> gestureDbSetUp(String name) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name));
  SharedPreferences.setMockInitialValues({});
}

Future<void> gestureDbTearDown(String name) async {
  // Fire-and-forget writes (event rows, workout teardown) must land before the
  // handle closes under them.
  await settleMs(400);
  await LocalDb.close();
  await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name));
}

/// The platform channel's haptic calls (HapticFeedback.mediumImpact etc.).
class HapticSpy {
  HapticSpy() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') calls.add('${call.arguments}');
      return null;
    });
  }
  final calls = <String>[];

  void dispose() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null);
}

/// An in-memory journal and workout seam. Every hook is optional so a test can
/// block, fail or observe one call.
class FakeJournalRepo extends LocalRepository {
  /// Journal entries as `getJournal` returns them: date, tags, note.
  final entries = <Map<String, dynamic>>[];

  /// Per-day metrics as `getJournalMetrics` returns them.
  final metrics = <String, Map<String, JournalMetricValue>>{};

  /// Every `postJournal` and `postJournalMetrics`, in order.
  final journalPosts = <({String date, List<String> tags, String note})>[];
  final metricPosts = <({String date, Map<String, JournalMetricValue> fields})>[];
  final calls = <String>[];

  Object? getJournalThrows;
  Object? postJournalThrows;
  Object? getMetricsThrows;
  Object? postMetricsThrows;
  Object? startWorkoutThrows;
  Object? endWorkoutThrows;
  Map<String, dynamic>? startWorkoutAnswer = {'workout_id': 'srv-1'};

  /// When set, `getJournalMetrics` waits for it after reading the day (the
  /// read-modify-write window the water latch guards).
  Completer<void>? metricsReadGate;

  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async {
    calls.add('getJournal:$range');
    if (getJournalThrows != null) throw getJournalThrows!;
    return [for (final e in entries) {...e}];
  }

  @override
  Future<void> postJournal(String date, List<String> tags, String note) async {
    calls.add('postJournal');
    if (postJournalThrows != null) throw postJournalThrows!;
    journalPosts.add((date: date, tags: List.of(tags), note: note));
  }

  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async {
    calls.add('getJournalMetrics');
    if (getMetricsThrows != null) throw getMetricsThrows!;
    final snapshot = {...?metrics[date]};
    final gate = metricsReadGate;
    if (gate != null) await gate.future;
    return snapshot;
  }

  @override
  Future<void> postJournalMetrics(
      String date, Map<String, JournalMetricValue> fields) async {
    calls.add('postJournalMetrics');
    if (postMetricsThrows != null) throw postMetricsThrows!;
    metricPosts.add((date: date, fields: {...fields}));
    metrics[date] = {...fields};
  }

  @override
  Future<Map<String, dynamic>> startWorkout(String type, {String? title}) async {
    calls.add('start:$type');
    if (startWorkoutThrows != null) throw startWorkoutThrows!;
    return startWorkoutAnswer!;
  }

  @override
  Future<Map<String, dynamic>> endWorkout(String workoutId) async {
    calls.add('end:$workoutId');
    if (endWorkoutThrows != null) throw endWorkoutThrows!;
    return const {};
  }

  @override
  Future<Map<String, dynamic>> getToday() async => const {};
}

/// Stored band events, oldest first: (event_id, ts, device_id).
Future<List<({int id, int ts, String device})>> storedEvents() async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
      'SELECT event_id, ts, device_id FROM events ORDER BY rowid');
  return [
    for (final r in rows)
      (
        id: (r['event_id'] as num).toInt(),
        ts: (r['ts'] as num).toInt(),
        device: '${r['device_id']}',
      ),
  ];
}
