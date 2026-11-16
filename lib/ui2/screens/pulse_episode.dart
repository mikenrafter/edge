// Owner: episode detail. One pinned persisted revision drives every graph and export.
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import '../../compute/findings.dart';
import '../../l10n/app_localizations.dart';
import '../finding_presentation.dart';
import '../../data/db.dart';
import '../../data/pulse_episode_store.dart';
import '../../util/log_file.dart';
import '../ui2.dart';

const pulseLimits =
    "Your wrist sensor recorded uneven pulse timing. We haven't measured how often this flag is right or how often it misses. Movement, sensor fit and extra beats can cause the same pattern. It can't identify AF or rule out a rhythm problem. A clinician can check your rhythm with an ECG. Discuss repeated flags with a clinician, especially if you have symptoms.";

enum PulseUnits { milliseconds, bpm }

double? pulseValue(num? rr, PulseUnits units) =>
    rr == null || !rr.isFinite || rr <= 0
    ? null
    : units == PulseUnits.milliseconds
    ? rr.toDouble()
    : 60000 / rr;
double? pulseChange(Map<String, dynamic> beat, PulseUnits units) {
  final raw = beat['raw'] as num?, change = beat['change'] as num?;
  if (raw == null || change == null) return null;
  final a = pulseValue(raw, units), b = pulseValue(raw - change, units);
  return a == null || b == null ? null : a - b;
}

class PulseEpisodeScreen extends StatefulWidget {
  final String episodeId;
  final PulseEpisodeSnapshot? snapshot;
  final PulseUnits initialUnits;
  final double? initialZoomMs;
  const PulseEpisodeScreen({
    super.key,
    required this.episodeId,
    this.snapshot,
    this.initialUnits = PulseUnits.milliseconds,
    this.initialZoomMs,
  });
  @override
  State<PulseEpisodeScreen> createState() => _PulseEpisodeScreenState();
}

class _PulseEpisodeScreenState extends State<PulseEpisodeScreen> {
  PulseEpisodeSnapshot? _episode;
  Object? _error;
  late PulseUnits _units;
  double _zoom = 0;
  Map<String, dynamic>? _focus;
  bool _sharing = false;
  @override
  void initState() {
    super.initState();
    _units = widget.initialUnits;
    if (widget.snapshot != null) {
      _setEpisode(widget.snapshot!);
    } else {
      _load();
    }
  }

  void _setEpisode(PulseEpisodeSnapshot e) {
    _episode = e;
    final jumps = (e.evidence?['jumps'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    _focus = jumps.firstOrNull ?? e.beats.firstOrNull;
    _zoom =
        widget.initialZoomMs ??
        ((_focus?['time'] as num?)?.toDouble() ?? e.startMs.toDouble()) - 15000;
    _zoom = _clamp(_zoom);
  }

  Future<void> _load() async {
    try {
      final e = await PulseEpisodeStore(
        await LocalDb.instance,
      ).get(widget.episodeId);
      if (!mounted) return;
      setState(() {
        if (e == null) {
          _error = 'This episode is unavailable';
        } else {
          _setEpisode(e);
          _error = null;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  double get _lo =>
      (_episode!.beats.firstOrNull?['time'] as num?)?.toDouble() ??
      _episode!.startMs.toDouble();
  double get _hi =>
      (_episode!.beats.lastOrNull?['time'] as num?)?.toDouble() ??
      _episode!.endMs.toDouble();
  double _clamp(double t) => t.clamp(_lo, math.max(_lo, _hi - 30000));
  String _clock(num t, {bool seconds = false}) {
    final offset = (_episode?.row['offset_min'] as int?) ?? 0;
    final time = DateTime.fromMillisecondsSinceEpoch(
      t.toInt(),
      isUtc: true,
    ).add(Duration(minutes: offset));
    return DateFormat(seconds ? 'HH:mm:ss' : 'HH:mm').format(time);
  }

  String get _unit => _units == PulseUnits.milliseconds ? 'ms' : 'bpm';
  String _value(num? rr) {
    final v = pulseValue(rr, _units);
    return v == null ? '—' : '${v.round()} $_unit';
  }

  String _delta(Map<String, dynamic> b) {
    final d = pulseChange(b, _units);
    return d == null ? '—' : '${d >= 0 ? '+' : ''}${d.round()} $_unit';
  }

  String _extreme(Map<String, dynamic> beat) =>
      '${_value(beat['raw'] as num?)}${beat['corrected'] == true
          ? ' · corrected'
          : beat['dropped'] == true
          ? ' · dropped'
          : ''}';

  void _select(Map<String, dynamic> beat) => setState(() {
    _focus = beat;
    _zoom = _clamp((beat['time'] as num).toDouble() - 15000);
  });
  Future<void> _share() async {
    setState(() => _sharing = true);
    final e = _episode!;
    final ok = await saveLogFile(
      logFileName('pulse-episode', DateTime.now(), ext: 'json'),
      const JsonEncoder.withIndent('  ').convert({
        'episode': e.row,
        'evidence': e.evidence,
        'evidenceStatus': e.evidenceStatus,
        'limits': pulseLimits,
      }),
    );
    if (!mounted) return;
    setState(() => _sharing = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recording could not be shared. Try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c), e = _episode;
    if (e == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Irregular pulse pattern')),
        body: Center(
          child: _error != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Recording could not be loaded. $_error'),
                    TextButton(
                      onPressed: _load,
                      child: const Text('Try again'),
                    ),
                  ],
                )
              : const Text('Loading recording…'),
        ),
      );
    }
    final doc = e.evidence;
    final beats = e.beats;
    final overview = (doc?['overview'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final jumps = (doc?['jumps'] as List? ?? []).cast<Map<String, dynamic>>();
    final visible = beats
        .where(
          (b) =>
              (b['time'] as num) >= _zoom && (b['time'] as num) < _zoom + 30000,
        )
        .toList();
    final focus = _focus;
    final inView =
        focus != null &&
        (focus['time'] as num) >= _zoom &&
        (focus['time'] as num) < _zoom + 30000;
    final windows = (doc?['windows'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final usable = [
      for (final b in beats)
        if (b['plausible'] == true) pulseValue(b['raw'] as num?, _units)!,
    ];
    final low = usable.isEmpty ? 0.0 : usable.reduce(math.min),
        high = usable.isEmpty ? 1.0 : usable.reduce(math.max);
    final pad = math.max(10.0, (high - low) * .15);
    final axis = AxisSpec(
      min: math.max(0, low - pad),
      max: high + pad,
      format: (v) => v.round().toString(),
    );
    Widget graph(String kind, {required double height}) => RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: PulseEpisodePainter(
          kind: kind,
          episode: e,
          units: _units,
          zoomMs: _zoom,
          axis: axis,
          ink: p.ink2,
          line: p.line,
          focusId: inView ? focus['id'] as String : null,
        ),
      ),
    );
    Widget card(Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Surface(child: child),
    );
    Widget why(String title, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: F.cap.copyWith(color: p.ink2)),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: F.cap.copyWith(color: p.ink),
            ),
          ),
        ],
      ),
    );
    String range(String key) {
      final values = [
        for (final w in windows)
          if (w[key] is num) (w[key] as num).toDouble(),
      ];
      if (values.isEmpty) return '—';
      final low = values.reduce(math.min), high = values.reduce(math.max);
      final places = key == 'pnnPct' ? 0 : 2;
      return low == high
          ? low.toStringAsFixed(places)
          : '${low.toStringAsFixed(places)}–${high.toStringAsFixed(places)}';
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Irregular pulse pattern')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            '${e.row['day']} · ${_clock(e.startMs)}–${_clock(e.endMs)} · ${((e.endMs - e.startMs) / 60000).round()} min${e.row['ongoing'] == 1 ? ' · recorded through ${_clock(e.endMs)}' : ''}',
            style: F.cap.copyWith(color: p.ink2),
          ),
          const SizedBox(height: 6),
          Text(e.alertNote, style: F.cap.copyWith(color: p.ink2)),
          Text(
            'Clock zone recorded at analysis; original recording zone unknown.',
            style: F.cap.copyWith(color: p.ink3),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('ms between beats'),
                selected: _units == PulseUnits.milliseconds,
                onSelected: (_) =>
                    setState(() => _units = PulseUnits.milliseconds),
              ),
              ChoiceChip(
                label: const Text('beats per minute'),
                selected: _units == PulseUnits.bpm,
                onSelected: (_) => setState(() => _units = PulseUnits.bpm),
              ),
            ],
          ),
          if (_units == PulseUnits.bpm)
            Text(
              'Pulse-rate equivalent: 60,000 ÷ interval. Night HR is measured separately.',
              style: F.cap.copyWith(color: p.ink3),
            ),
          const SizedBox(height: 12),
          if (e.row['status'] == 'retracted')
            card(
              const Text(
                'Reanalysis changed this episode. The earlier recording and alert record are retained.',
              ),
            ),
          if (e.evidenceStatus != 'complete')
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.evidenceStatus == 'partial'
                        ? 'Partial recording'
                        : 'Recording removed',
                    style: F.body.copyWith(color: p.ink),
                  ),
                  Text(
                    e.evidenceStatus == 'partial'
                        ? 'Some beats were omitted to keep this recording within its evidence limit. Gaps are shown; missing beats are never connected.'
                        : 'Evidence is retained for 365 days within a 128 MiB budget. The episode summary and alert record remain.',
                    style: F.cap.copyWith(color: p.ink2),
                  ),
                ],
              ),
            ),
          if (doc != null) ...[
            card(
              Column(
                children: [
                  ChartFrame(
                    title: _units == PulseUnits.milliseconds
                        ? 'Time between beats: the whole episode'
                        : 'Pulse-rate equivalent: the whole episode',
                    unit: _unit,
                    height: 145,
                    yAxis: axis,
                    xLabels: [
                      _clock(_lo),
                      _clock(e.startMs),
                      _clock(e.endMs),
                      _clock(_hi),
                    ],
                    legend: [
                      ('Range of most beats (each 30 s)', p.ink2),
                      ('Typical beat', C.blue),
                    ],
                    empty: overview.isEmpty
                        ? const Text('No retained overview')
                        : null,
                    child: LayoutBuilder(
                      builder: (c, box) => GestureDetector(
                        key: const ValueKey('pulse-overview'),
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) => setState(
                          () => _zoom = _clamp(
                            _lo +
                                d.localPosition.dx /
                                    box.maxWidth *
                                    (_hi - _lo) -
                                15000,
                          ),
                        ),
                        onHorizontalDragUpdate: (d) => setState(
                          () => _zoom = _clamp(
                            _zoom + d.delta.dx / box.maxWidth * (_hi - _lo),
                          ),
                        ),
                        child: graph('overview', height: 145),
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (var i = 0; i < jumps.length; i++)
                        ActionChip(
                          label: Text(
                            '${i + 1} · ${_clock(jumps[i]['time'] as num)} · ${_delta(jumps[i])}',
                          ),
                          onPressed: () => _select(jumps[i]),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Drag the strip, or tap / drag the overview, to move through the episode.',
                    style: F.cap.copyWith(color: p.ink3),
                  ),
                  ChartFrame(
                    title: 'Zoomed in: 30 seconds',
                    unit: _unit,
                    height: 155,
                    yAxis: axis,
                    xLabels: [
                      _clock(_zoom, seconds: true),
                      _clock(_zoom + 15000, seconds: true),
                      _clock(_zoom + 30000, seconds: true),
                    ],
                    legend: const [
                      ('Sudden long', C.orange),
                      ('Sudden short', C.blue),
                      ('Corrected / dropped', C.purple),
                    ],
                    child: LayoutBuilder(
                      builder: (c, box) => GestureDetector(
                        key: const ValueKey('pulse-zoom'),
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (d) => setState(
                          () => _zoom = _clamp(
                            _zoom - d.delta.dx / box.maxWidth * 30000,
                          ),
                        ),
                        onTapUp: (d) {
                          if (visible.isEmpty) return;
                          final t =
                              _zoom + d.localPosition.dx / box.maxWidth * 30000;
                          final sorted = [...visible]
                            ..sort(
                              (a, b) => ((a['time'] as num) - t)
                                  .abs()
                                  .compareTo(((b['time'] as num) - t).abs()),
                            );
                          setState(() => _focus = sorted.first);
                        },
                        child: graph('zoom', height: 155),
                      ),
                    ),
                  ),
                  if (inView) ...[
                    ChartKeyReadout(
                      time: _clock(focus['time'] as num, seconds: true),
                      scrubbed: true,
                      cells: [
                        ChartCell(
                          'Raw interval',
                          C.blue,
                          value: _value(focus['raw'] as num?),
                        ),
                        ChartCell('Change', C.orange, value: _delta(focus)),
                      ],
                    ),
                    Text(
                      '${(focus['labels'] as List).isEmpty ? 'Ordinary beat' : (focus['labels'] as List).map((v) => switch (v) {
                              'suddenLong' => 'Sudden long beat',
                              'suddenShort' => 'Sudden short beat',
                              'shortLongPair' => 'Short-long pair',
                              'likelyExtra' => 'Likely extra beat',
                              'likelyMissed' => 'Likely missed beat',
                              'corrected' => 'Corrected',
                              'dropped' => 'Dropped',
                              _ => v.toString(),
                            }).join(', ')} · ${focus['feature'] == true ? 'used by the rule' : 'not used by the rule'}${focus['corrected'] == true ? ' · corrected to ${_value(focus['value'] as num?)}' : ''}',
                      style: F.cap.copyWith(color: p.ink2),
                    ),
                  ] else
                    Text(
                      'Tap any beat to read its time, interval and change.',
                      style: F.cap.copyWith(color: p.ink2),
                    ),
                  if (visible.isEmpty)
                    Text(
                      'No retained beats in this range.',
                      style: F.cap.copyWith(color: p.ink2),
                    ),
                ],
              ),
            ),
            card(
              Column(
                children: [
                  ChartFrame(
                    title: 'Each beat against the next',
                    unit: _unit,
                    height: 190,
                    yAxis: axis,
                    xLabels: [
                      axis.min.round().toString(),
                      ((axis.min + axis.max) / 2).round().toString(),
                      axis.max.round().toString(),
                    ],
                    child: graph('poincare', height: 190),
                  ),
                  Row(
                    children: [
                      Text(
                        _clock(e.startMs),
                        style: F.cap.copyWith(color: p.ink3),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: SizedBox(
                          height: 8,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: PulseEpisodePainter.timeColors,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _clock(e.endMs),
                        style: F.cap.copyWith(color: p.ink3),
                      ),
                    ],
                  ),
                  Text(
                    (doc['comparison'] as List? ?? []).isEmpty
                        ? 'Calm comparison unavailable'
                        : 'Episode beats coloured by time · preceding calm stretch in green',
                    style: F.cap.copyWith(color: p.ink2),
                  ),
                ],
              ),
            ),
            card(
              ChartFrame(
                title: 'Heart rate through the night',
                unit: 'bpm',
                height: 110,
                xLabels: (doc['heartRate'] as List? ?? []).isEmpty
                    ? const []
                    : [
                        _clock((doc['heartRate'] as List).first['time'] as num),
                        _clock(e.startMs),
                        _clock((doc['heartRate'] as List).last['time'] as num),
                      ],
                empty: (doc['heartRate'] as List? ?? []).isEmpty
                    ? const Text('Night heart rate was not recorded')
                    : null,
                child: graph('night', height: 110),
              ),
            ),
            card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Why it was flagged',
                    style: F.body.copyWith(color: p.ink),
                  ),
                  why(
                    'Changes over 70 ms, original rule',
                    '${range('pnnPct')}% · rule ≥30%',
                  ),
                  why(
                    'Scatter, short vs long term (SD1/SD2)',
                    '${range('ratio')} · rule ≥0.70',
                  ),
                  why(
                    'Consecutive five-minute windows',
                    '${windows.length} · minimum 2',
                  ),
                  why(
                    'Usable recording',
                    windows.isEmpty
                        ? '—'
                        : '${(100 * windows.map((w) => (w['coverageMs'] as num) / (w['durationMs'] as num)).reduce(math.min)).round()}% · minimum 80%',
                  ),
                  why(
                    'Corrected or dropped',
                    windows.isEmpty
                        ? '—'
                        : '${(100 * windows.map((w) => (w['cleaned'] as num) / (w['total'] as num)).reduce(math.max)).round()}% · maximum 30%',
                  ),
                  why('Movement / wear', 'Unknown / unknown'),
                  if (doc['extremes'] is Map) ...[
                    why(
                      'Shortest interval',
                      _extreme(
                        doc['extremes']['shortest'] as Map<String, dynamic>,
                      ),
                    ),
                    why(
                      'Longest interval',
                      _extreme(
                        doc['extremes']['longest'] as Map<String, dynamic>,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "What this can and can't tell you",
                  style: F.body.copyWith(color: p.ink),
                ),
                const SizedBox(height: 8),
                Text(
                  pulseLimits,
                  style: F.cap.copyWith(color: p.ink2, height: 1.5),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _sharing ? null : _share,
                  child: Text(
                    _sharing
                        ? 'Preparing recording…'
                        : 'Share this recording with a clinician',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PulseEpisodePainter extends CustomPainter {
  final String kind;
  final PulseEpisodeSnapshot episode;
  final PulseUnits units;
  final double zoomMs;
  final AxisSpec axis;
  final Color ink, line;
  final String? focusId;
  const PulseEpisodePainter({
    required this.kind,
    required this.episode,
    required this.units,
    required this.zoomMs,
    required this.axis,
    required this.ink,
    required this.line,
    this.focusId,
  });
  static const timeColors = [
    Color(0xfffde047),
    Color(0xfffb923c),
    Color(0xffef4444),
    Color(0xffa855f7),
  ];
  Color _time(num t) {
    final f =
        ((t - episode.startMs) / (episode.endMs - episode.startMs)).clamp(
          0.0,
          1.0,
        ) *
        3;
    final i = math.min(2, f.floor());
    return Color.lerp(timeColors[i], timeColors[i + 1], f - i)!;
  }

  @override
  void paint(Canvas c, Size s) {
    final doc = episode.evidence;
    if (doc == null || s.isEmpty) return;
    final beats = episode.beats;
    final times = beats.map((b) => (b['time'] as num).toDouble()).toList();
    final lo = times.isEmpty ? episode.startMs.toDouble() : times.first,
        hi = times.isEmpty ? episode.endMs.toDouble() : times.last;
    double x(num t) => ((t - lo) / math.max(1, hi - lo) * s.width).toDouble();
    double y(num rr) =>
        s.height * (1 - axis.t(pulseValue(rr, units) ?? axis.min));
    void lineTo(Offset a, Offset b, Color color, {double width = 1}) =>
        c.drawLine(
          a,
          b,
          Paint()
            ..color = color
            ..strokeWidth = width,
        );
    void text(String v, Offset at, Color color) {
      final p = TextPainter(
        text: TextSpan(
          text: v,
          style: TextStyle(fontSize: 9, color: color, fontFamily: 'Manrope'),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(
        c,
        Offset(
          at.dx.clamp(0, math.max(0, s.width - p.width)),
          at.dy.clamp(0, math.max(0, s.height - p.height)),
        ),
      );
    }

    if (kind == 'overview' || kind == 'zoom') {
      for (final gap in (doc['omissions'] as List? ?? [])) {
        final from = (gap['from'] as num).toDouble(),
            to = (gap['to'] as num).toDouble();
        double gx(double t) =>
            kind == 'zoom' ? (t - zoomMs) / 30000 * s.width : x(t);
        final left = gx(from).clamp(0.0, s.width),
            right = gx(to).clamp(0.0, s.width);
        if (right > left) {
          c.drawRect(
            Rect.fromLTRB(left, 0, right, s.height),
            Paint()..color = C.purple.withValues(alpha: .16),
          );
          if (kind == 'zoom') {
            text('Recording gap', Offset(left + 2, s.height / 2), ink);
          }
        }
      }
    }
    if (kind == 'overview') {
      c.drawRect(
        Rect.fromLTRB(x(episode.startMs), 0, x(episode.endMs), s.height),
        Paint()..color = C.orange.withValues(alpha: .10),
      );
      final bins = (doc['overview'] as List).cast<Map<String, dynamic>>();
      for (var i = 1; i < bins.length; i++) {
        final a = bins[i - 1], b = bins[i];
        if ((b['time'] as num) - (a['time'] as num) > 30000) continue;
        final path = Path()
          ..moveTo(x(a['time'] as num), y(a['lo'] as num))
          ..lineTo(x(b['time'] as num), y(b['lo'] as num))
          ..lineTo(x(b['time'] as num), y(b['hi'] as num))
          ..lineTo(x(a['time'] as num), y(a['hi'] as num))
          ..close();
        c.drawPath(path, Paint()..color = ink.withValues(alpha: .20));
        lineTo(
          Offset(x(a['time'] as num), y(a['median'] as num)),
          Offset(x(b['time'] as num), y(b['median'] as num)),
          C.blue,
          width: 1.5,
        );
      }
      final box = Rect.fromLTRB(
        x(zoomMs),
        0,
        math.max(x(zoomMs) + 3, x(zoomMs + 30000)),
        s.height,
      );
      c.drawRect(box, Paint()..color = C.blue.withValues(alpha: .14));
      c.drawRect(
        box,
        Paint()
          ..color = C.blue
          ..style = PaintingStyle.stroke,
      );
      final jumps = (doc['jumps'] as List).cast<Map<String, dynamic>>();
      final labels = <double>[];
      for (final j in jumps) {
        final actual = x(j['time'] as num);
        labels.add(math.max(actual, labels.isEmpty ? 8.0 : labels.last + 19));
      }
      if (labels.isNotEmpty && labels.last > s.width - 8) {
        labels[labels.length - 1] = s.width - 8;
        for (var i = labels.length - 2; i >= 0; i--) {
          labels[i] = math.min(labels[i], labels[i + 1] - 19);
        }
      }
      for (var i = 0; i < jumps.length; i++) {
        final px = x(jumps[i]['time'] as num), labelX = labels[i];
        lineTo(Offset(labelX, 16), Offset(px, 28), line);
        lineTo(Offset(px, 28), Offset(px, s.height), line);
        c.drawCircle(Offset(labelX, 8), 8, Paint()..color = C.blue);
        text('${i + 1}', Offset(labelX - 3, 2), Colors.white);
      }
    } else if (kind == 'zoom') {
      final visible = beats
          .where(
            (b) =>
                (b['time'] as num) >= zoomMs &&
                (b['time'] as num) < zoomMs + 30000,
          )
          .toList();
      final values = [
        for (final b in visible)
          if (b['plausible'] == true &&
              b['corrected'] != true &&
              b['dropped'] != true)
            (b['raw'] as num).toDouble(),
      ]..sort();
      final median = values.isEmpty
          ? null
          : values[((values.length - 1) * .5).floor()];
      if (median != null) {
        lineTo(
          Offset(0, y(median)),
          Offset(s.width, y(median)),
          ink.withValues(alpha: .4),
        );
      }
      for (final b in visible) {
        final px = ((b['time'] as num) - zoomMs) / 30000 * s.width,
            py = y(b['raw'] as num);
        final labels = b['labels'] as List;
        final color = labels.contains('suddenLong')
            ? C.orange
            : labels.contains('suddenShort')
            ? C.blue
            : ink;
        if (b['dropped'] == true) {
          lineTo(Offset(px - 3, py - 3), Offset(px + 3, py + 3), C.purple);
          lineTo(Offset(px + 3, py - 3), Offset(px - 3, py + 3), C.purple);
        } else {
          if (median != null) {
            lineTo(
              Offset(px, y(median)),
              Offset(px, py),
              color.withValues(alpha: .6),
            );
          }
          c.drawCircle(
            Offset(px, py),
            b['id'] == focusId ? 4.5 : 2.5,
            Paint()..color = color,
          );
          if (b['corrected'] == true && b['value'] is num) {
            c.drawCircle(
              Offset(px, y(b['value'] as num)),
              4,
              Paint()
                ..color = C.purple
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5,
            );
          }
        }
        if (labels.contains('suddenLong') || labels.contains('suddenShort')) {
          text(
            '${pulseValue(b['raw'] as num, units)?.round() ?? '—'}',
            Offset(px - 9, py + (median != null && py < y(median) ? -12 : 5)),
            ink,
          );
        }
        if (b['id'] == focusId) {
          lineTo(
            Offset(px, 0),
            Offset(px, s.height),
            C.blue.withValues(alpha: .5),
          );
        }
      }
    } else if (kind == 'poincare') {
      lineTo(Offset(0, s.height), Offset(s.width, 0), line);
      void cloud(List<Map<String, dynamic>> b, bool calm) {
        final byId = {for (final v in b) v['id']: v};
        for (final v in b) {
          final previous = byId[v['predecessor']];
          if (v['adjacent'] != true ||
              previous == null ||
              v['value'] == null ||
              previous['value'] == null) {
            continue;
          }
          final time = v['time'] as num;
          if (!calm && (time < episode.startMs || time >= episode.endMs)) {
            continue;
          }
          final px =
                  axis.t(pulseValue(previous['value'] as num, units)!) *
                  s.width,
              py = y(v['value'] as num);
          c.drawCircle(
            Offset(px, py),
            1.8,
            Paint()
              ..color = (calm ? C.green : _time(time)).withValues(alpha: .65)
              ..style =
                  (v['corrected'] == true || previous['corrected'] == true)
                  ? PaintingStyle.stroke
                  : PaintingStyle.fill,
          );
        }
      }

      cloud(
        (doc['comparison'] as List? ?? []).cast<Map<String, dynamic>>(),
        true,
      );
      cloud(beats, false);
    } else if (kind == 'night') {
      final hr = (doc['heartRate'] as List? ?? []).cast<Map<String, dynamic>>();
      if (hr.isEmpty) return;
      final a = (hr.first['time'] as num).toDouble(),
          b = (hr.last['time'] as num).toDouble();
      double nx(num t) => (t - a) / math.max(1, b - a) * s.width;
      c.drawRect(
        Rect.fromLTRB(
          nx(episode.startMs).clamp(0, s.width),
          0,
          nx(episode.endMs).clamp(0, s.width),
          s.height,
        ),
        Paint()..color = C.orange.withValues(alpha: .18),
      );
      final v = hr.map((r) => (r['bpm'] as num).toDouble()).toList();
      final min = v.reduce(math.min) - 5, max = v.reduce(math.max) + 5;
      double ny(num n) => s.height * (1 - (n - min) / (max - min));
      for (var i = 1; i < hr.length; i++) {
        if ((hr[i]['time'] as num) - (hr[i - 1]['time'] as num) > 60000) {
          continue;
        }
        lineTo(
          Offset(nx(hr[i - 1]['time'] as num), ny(hr[i - 1]['bpm'] as num)),
          Offset(nx(hr[i]['time'] as num), ny(hr[i]['bpm'] as num)),
          C.orange,
          width: 1.5,
        );
      }
      text('${min.round()} bpm', Offset(2, s.height - 12), ink);
      text('${max.round()} bpm', const Offset(2, 0), ink);
    }
  }

  @override
  bool shouldRepaint(covariant PulseEpisodePainter old) => true;
}

class PulseEpisodesScreen extends StatefulWidget {
  const PulseEpisodesScreen({super.key});
  @override
  State<PulseEpisodesScreen> createState() => _PulseEpisodesScreenState();
}

class _PulseEpisodesScreenState extends State<PulseEpisodesScreen> {
  final _rows = <PulseEpisodeSnapshot>[];
  bool _loading = false, _more = true;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _next();
  }

  Future<void> _next() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final last = _rows.lastOrNull;
      final page = await PulseEpisodeStore(
        await LocalDb.instance,
      ).list(beforeMs: last?.startMs, beforeId: last?.id ?? '');
      if (!mounted) return;
      setState(() {
        _rows.addAll(page);
        _more = page.length == 30;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('Pulse episodes')),
    body: ListView(
      children: [
        for (final e in _rows) PulseEpisodeRow(e),
        if (_error != null)
          TextButton(
            onPressed: _next,
            child: const Text('Recordings could not be loaded. Try again.'),
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Loading recordings…'),
          ),
        if (!_loading && _error == null && _rows.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No pulse episodes recorded'),
          ),
        if (_more && !_loading && _error == null)
          TextButton(onPressed: _next, child: const Text('Earlier episodes')),
      ],
    ),
  );
}

class PulseEpisodeRow extends StatelessWidget {
  final PulseEpisodeSnapshot episode;
  const PulseEpisodeRow(this.episode, {super.key});
  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l =
        AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    return ListTile(
      leading: Icon(
        findingIcon(const Finding(FindingKind.irregularRhythm, '')),
        color: P.of(c).on(findingColor(FindingKind.irregularRhythm)),
      ),
      title: Text(
        '${l.observationsPulsePattern} · ${episode.row['day']}',
        style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${((episode.endMs - episode.startMs) / 60000).round()} min · ${episode.alertNote}',
        style: F.cap.copyWith(color: p.ink2),
      ),
      trailing: Icon(Icons.chevron_right, color: p.ink3),
      onTap: () => Navigator.of(c).push(
        MaterialPageRoute<void>(
          builder: (_) => PulseEpisodeScreen(episodeId: episode.id),
        ),
      ),
    );
  }
}
