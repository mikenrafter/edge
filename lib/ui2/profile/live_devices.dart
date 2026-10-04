// Live devices — the last 30 s of every stream, per connected device.
//
// One card per device (the band and any paired sensor). A connected device
// shows one graph per stream it has reported; the list of streams is whatever
// [LiveStreamBuffer.streamKeys] holds, so a stream nobody planned for appears
// as a new graph with no change here. A stream with nothing in the window says
// so instead of drawing a flat line. A disconnected device shows when it was
// last seen and no chart.
//
// Reads RAM only (invariant 14): nothing on this screen is stored.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ble/hrs_link.dart' show HrsLink;
import '../../ble/polar_pmd_link.dart' show PolarPmdLink;
import '../../data/db.dart' show LocalDb;
import '../../ble/adapters/_registry.dart' show kBleHrs, kPolarPmd;
import '../../state/app_state.dart';
import '../../state/live_stream_buffer.dart';
import '../ui2.dart';
import 'devices.dart' show formatDayTime, liveSources;

/// One device as the screen needs it. [id] is the key its samples are stored
/// under in the buffer.
class LiveDevice {
  const LiveDevice({
    required this.id,
    required this.name,
    required this.kind,
    required this.connected,
    this.batteryPct,
    this.lastSeen,
  });

  final String id, name, kind;
  final bool connected;
  final double? batteryPct;
  final DateTime? lastSeen;
}

const Map<String, String> _kStreamLabels = {
  'hr': 'Heart rate (bpm)',
  'rr': 'Beat intervals (ms)',
  'accel_x': 'Accelerometer X (g)',
  'accel_y': 'Accelerometer Y (g)',
  'accel_z': 'Accelerometer Z (g)',
  'accel_mag': 'Acceleration (g)',
  'gyro_x': 'Gyroscope X (°/s)',
  'gyro_y': 'Gyroscope Y (°/s)',
  'gyro_z': 'Gyroscope Z (°/s)',
  'ecg_uv': 'ECG, filtered (µV)',
  'ecg_band_hr': 'ECG: heart rate the band reports (bpm)',
  'ecg_quality': 'ECG: signal quality (band code)',
  // Meaning unconfirmed by protocol: shown as raw channels, never as a sensor.
  'r11_ch1': 'R11 raw channel 1 (unidentified)',
  'r11_ch2': 'R11 raw channel 2 (unidentified)',
  'skin_temp': 'Skin temperature (°C)',
  'spo2': 'Blood oxygen (%)',
  'battery': 'Battery (%)',
};

/// A human label for a stream key; an unknown key is shown as-is.
String liveStreamLabel(String key) => _kStreamLabels[key] ?? key;

/// Resamples [samples] into [slots] equal buckets over the [window] ending at
/// [now]: the mean of each bucket, null where nothing arrived (a gap, never a
/// zero).
List<double?> liveSeries(
  List<LiveSample> samples,
  DateTime now,
  Duration window, {
  int slots = 60,
}) {
  final sums = List<double>.filled(slots, 0);
  final counts = List<int>.filled(slots, 0);
  final startUs = now.subtract(window).microsecondsSinceEpoch;
  final span = window.inMicroseconds;
  for (final s in samples) {
    final i = ((s.at.microsecondsSinceEpoch - startUs) * slots ~/ span)
        .clamp(0, slots - 1);
    sums[i] += s.value;
    counts[i]++;
  }
  return [for (var i = 0; i < slots; i++) counts[i] == 0 ? null : sums[i] / counts[i]];
}

/// How many slots to split [window] into for [samples]: each slot is at least
/// one and a half of the stream's usual intervals wide (the mean gap between
/// arrivals; jitter moves single gaps, not the mean), so a stream arriving once a second never shows a missing slot
/// between two readings; a fast stream keeps the 60-slot maximum. Too few
/// samples to tell the rate fall back to that maximum.
int liveSlotsFor(List<LiveSample> samples, Duration window, {int max = 60}) {
  if (samples.length < 3) return max;
  final mean = samples.last.at.difference(samples.first.at).inMicroseconds ~/
      (samples.length - 1);
  if (mean <= 0) return max;
  return (window.inMicroseconds * 2 ~/ (mean * 3)).clamp(10, max);
}

/// The slot width as words for the key, e.g. "½ s" or "1.5 s".
String liveSlotWidth(Duration window, int slots) {
  final ms = window.inMilliseconds / slots;
  if ((ms - 500).abs() < 1) return '½ s';
  final s = ms / 1000;
  return '${s == s.roundToDouble() ? s.toStringAsFixed(0) : s.toStringAsFixed(1)} s';
}

class LiveDevices extends StatefulWidget {
  const LiveDevices({super.key});

  @override
  State<LiveDevices> createState() => _LiveDevicesState();
}

class _LiveDevicesState extends State<LiveDevices> {
  Timer? _tick;
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    // Held for dispose: a context lookup there is unsafe (§4.5).
    _app = context.read<AppState>();
    // The buffer moves many times a second and is deliberately not a
    // listenable (a rebuild per sample would be the 1 Hz storm other screens
    // were fixed for); redraw once a second instead.
    _tick = Timer.periodic(Motion.tick, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    // Nothing streams behind a closed screen. Stop clears the owner before its
    // first await, so not awaiting it here cannot leave the feed on.
    unawaited(_app.stopLiveFeed(LocalDb.kPrimaryDeviceId));
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final app = c.watch<AppState>();
    final now = DateTime.now();
    final liveIds = {
      if (HrsLink.instance.reading.value != null) kBleHrs.id,
      if (PolarPmdLink.instance.reading.value != null) kPolarPmd.id,
    };
    final devices = <LiveDevice>[
      for (final s in liveSources(app, liveAdapterIds: liveIds))
        if (s.isBand || s.deviceId != null)
          () {
            final id = s.deviceId ?? LocalDb.kPrimaryDeviceId;
            return LiveDevice(
              id: id,
              name: s.name,
              kind: s.kind,
              connected: s.connected,
              batteryPct: s.batteryPct,
              lastSeen: _newest(app.liveStreams, id) ?? s.lastData,
            );
          }(),
    ];
    return LiveDevicesView(
      devices: devices,
      buffer: app.liveStreams,
      now: now,
      feedOn: app.isLiveFeedOn,
      onFeed: (id, on) =>
          unawaited(on ? app.startLiveFeed(id) : app.stopLiveFeed(id)),
    );
  }

  static DateTime? _newest(LiveStreamBuffer b, String id) {
    DateTime? best;
    for (final k in b.streamKeys(id)) {
      final r = b.retained(id, k);
      if (r.isNotEmpty && (best == null || r.last.at.isAfter(best))) {
        best = r.last.at;
      }
    }
    return best;
  }
}

class LiveDevicesView extends StatelessWidget {
  const LiveDevicesView({
    super.key,
    required this.devices,
    required this.buffer,
    required this.now,
    this.feedOn,
    this.onFeed,
  });

  final List<LiveDevice> devices;
  final LiveStreamBuffer buffer;
  final DateTime now;

  /// Whether a device's live feed is on, and the Start / Stop control. Both
  /// null (a view with no AppState behind it) means no control is drawn.
  final bool Function(String deviceId)? feedOn;
  final void Function(String deviceId, bool on)? onFeed;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar('Live devices'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                if (devices.isEmpty)
                  Surface(
                    child: Text('No device is connected.',
                        style: F.body.copyWith(color: p.ink2)),
                  )
                else ...[
                  Text(
                      'The last ${buffer.window.inSeconds} seconds of every '
                      'stream. Kept in memory only.',
                      style: F.cap.copyWith(color: p.ink3)),
                  for (final d in devices) ...[
                    const SizedBox(height: S.x4),
                    _DeviceCard(
                      device: d,
                      buffer: buffer,
                      now: now,
                      feedOn: feedOn?.call(d.id) ?? false,
                      onFeed: feedOn == null || onFeed == null || d.id != _kBandId
                          ? null
                          : (on) => onFeed!(d.id, on),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// The band's id in the buffer (LocalDb.kPrimaryDeviceId); only it has a feed.
const String _kBandId = LocalDb.kPrimaryDeviceId;

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.buffer,
    required this.now,
    required this.feedOn,
    required this.onFeed,
  });

  final LiveDevice device;
  final LiveStreamBuffer buffer;
  final DateTime now;
  final bool feedOn;

  /// Null when the device has no feed control.
  final void Function(bool on)? onFeed;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final battery = device.batteryPct;
    final seen = device.lastSeen;
    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(device.name, style: F.head.copyWith(color: p.ink)),
          ),
          if (battery != null)
            Text('${battery.round()}%', style: F.cap.copyWith(color: p.ink3)),
        ]),
        Text(device.kind, style: F.cap.copyWith(color: p.ink3)),
        const SizedBox(height: S.x1),
        if (!device.connected)
          Text(
              seen == null
                  ? 'Disconnected. Last seen: not yet this session'
                  : 'Disconnected. Last seen ${formatDayTime(seen)}',
              style: F.body.copyWith(color: p.ink2))
        else ...[
          Text('Connected', style: F.cap.copyWith(color: p.on(C.green))),
          if (onFeed != null) ...[
            const SizedBox(height: S.x3),
            BigButton(
              feedOn ? 'Stop live feed' : 'Start live feed',
              soft: feedOn,
              color: feedOn ? C.red : C.green,
              onTap: () => onFeed!(!feedOn),
            ),
          ],
          if (buffer.streamKeys(device.id).isNotEmpty) ...[
            const SizedBox(height: S.x3),
            // What this device has reported so far, one row per stream.
            Column(
              key: ValueKey<String>('live-sensors:${device.id}'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Streams reported', style: F.cap.copyWith(color: p.ink3)),
                for (final key in buffer.streamKeys(device.id))
                  Text(liveStreamLabel(key),
                      style: F.cap.copyWith(color: p.ink2)),
              ],
            ),
          ],
          for (final key in buffer.streamKeys(device.id)) ...[
            const SizedBox(height: S.x3),
            _StreamBlock(
                streamKey: key,
                samples: buffer.samples(device.id, key, now: now),
                now: now,
                window: buffer.window),
          ],
        ],
      ]),
    );
  }
}

class _StreamBlock extends StatelessWidget {
  const _StreamBlock({
    required this.streamKey,
    required this.samples,
    required this.now,
    required this.window,
  });

  final String streamKey;
  final List<LiveSample> samples;
  final DateTime now;
  final Duration window;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    if (samples.isNotEmpty) {
      return LiveStreamChart(
          label: liveStreamLabel(streamKey),
          samples: samples,
          now: now,
          window: window);
    }
    // Nothing in the window is not a zero: say so rather than draw a line.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(liveStreamLabel(streamKey), style: F.body.copyWith(color: p.ink)),
      Text('No data in the last ${window.inSeconds} s',
          style: F.cap.copyWith(color: p.ink3)),
    ]);
  }
}

/// One stream's graph: its last [window] of wall time, newest on the right.
class LiveStreamChart extends StatelessWidget {
  const LiveStreamChart({
    super.key,
    required this.label,
    required this.samples,
    required this.now,
    required this.window,
  });

  final String label;
  final List<LiveSample> samples;
  final DateTime now;
  final Duration window;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final latest = samples.last.value;
    final slots = liveSlotsFor(samples, window);
    final series = liveSeries(samples, now, window, slots: slots);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(label, style: F.body.copyWith(color: p.ink))),
        Text(latest.toStringAsFixed(latest.abs() >= 100 ? 0 : 1),
            style: F.cap.copyWith(color: p.ink3)),
      ]),
      const SizedBox(height: S.x1),
      // Each slot is as wide as liveSlotsFor picks; the row under the trace names
      // how long ago that slot was and its mean, never a neighbour's value. The
      // 72 pt is the trace alone: the key row sits beneath it.
      ChartScrub(
        label: label,
        gaps: hasChartGaps([series]),
        time: (at) {
          final i = ChartScrub.slotAt(series.length, at);
          final ago = window.inMilliseconds * (series.length - 1 - i) ~/
              series.length ~/
              1000;
          return ago == 0 ? 'now' : '$ago s ago';
        },
        keys: [
          // The stream's name is the heading above; the key says what a slot is.
          ChartKey.slots('Reading (${liveSlotWidth(window, slots)} mean)',
              p.on(C.blue), series,
              (i, v) => v.toStringAsFixed(v.abs() >= 100 ? 0 : 1)),
        ],
        child: SizedBox(
          height: 72,
          child: CustomPaint(
            size: Size.infinite,
            painter: LineChart(series, p.on(C.blue), fill: false),
          ),
        ),
      ),
    ]);
  }
}
