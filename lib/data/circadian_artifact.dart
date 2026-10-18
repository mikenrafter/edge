// The `circadian` artifact: everything the Body clock screen draws, as one
// JSON map the warmer can store and the screen can open from without reading a
// single day bundle.
//
// It is the cross-day rollup (`getInsights()`) plus what the screen used to read
// on every open: one sleep window per calendar night for the actogram (42
// `getDaySleepV2` reads), the newest night's wake time and duration (MIND-11's
// two inputs), and the rolling week's hourly daytime-HRV row (7 `getDayHeart`
// reads). Pure orchestration over the repository's own readers; the metric math
// stays in analytics and in the screen's envelope readers.
import 'day_label.dart';
import 'local_repository.dart';

/// How many nights the actogram draws. Each night costs one day-bundle read.
// ponytail: N bundle reads per build. If this ever feels slow, the fix is a
// `sleepWindows({days})` repo method that reads onset/offset without the
// payload, not a smaller number here.
const int kCircadianNights = 42;

/// The key the screen's own rows sit under in the artifact, so none of them can
/// shadow a rollup key.
const String kCircadianScreenKey = 'screen';

Future<Map<String, dynamic>> buildCircadianArtifact(
    LocalRepository repo) async {
  final cd = await repo.getInsights();

  // One column per CALENDAR night, not per derived day. `availableDays`
  // returns only the days that produced a result, so walking it directly
  // packed a 42-night actogram out of whatever 42 days happened to exist —
  // a fortnight of no records closed up, and every column left of it moved.
  // An actogram is a picture of when things happen; the x spacing IS the
  // measurement.
  final days = await repo.availableDays(); // newest first
  final have = days.toSet();
  final cols = <List<double>?>[];
  final labels = <String>[];
  // The newest night that actually has a window, picked up as the actogram
  // walks past it. MIND-11 needs exactly this and nothing else, so it costs no
  // read of its own.
  Map<String, dynamic>? latestNight;
  if (days.isNotEmpty) {
    final a = DateTime.parse(days.first);
    for (var back = kCircadianNights - 1; back >= 0; back--) {
      final day = dayLabelOf(DateTime(a.year, a.month, a.day - back));
      labels.add(day);
      if (!have.contains(day)) {
        cols.add(null);
        continue;
      }
      final n = await repo.getDaySleepV2(day);
      // A window with no total sleep time is a night NOT RECORDED: the
      // user's asserted times are not a measured asleep stretch to draw.
      cols.add(n['duration_min'] == null
          ? null
          : _column(n['onset_ts'] as num?, n['wake_ts'] as num?));
      if (n['wake_ts'] is num) latestNight = n;
    }
  }

  // The rolling week, TODAY EXCLUDED — today's daytime bins are a handful of
  // five-minute windows and this row is only honest as a weekly median.
  final today = dayLabelOf(DateTime.now());
  final week = days.where((d) => d != today).take(7).toList();
  final byHour = List.generate(24, (_) => <double>[]);
  String? hourlyNote;
  for (final day in week) {
    final dh = (await repo.getDayHeart(day))['daytime_hrv'];
    if (dh is! Map) continue;
    hourlyNote ??= dh['note']?.toString();
    final tl = dh['timeline'];
    for (final e in (tl is List ? tl : const [])) {
      if (e is! Map) continue;
      final t = e['t'], v = e['rmssd'];
      if (t is! num || v is! num) continue;
      final h = DateTime.fromMillisecondsSinceEpoch(t.round() * 1000).hour;
      byHour[h].add(v.toDouble());
    }
  }

  return {
    ...cd,
    kCircadianScreenKey: {
      'actogram': cols,
      'labels': labels,
      'latest_wake_ts': latestNight?['wake_ts'],
      'latest_duration_min': latestNight?['duration_min'],
      'hourly_samples': [
        for (final xs in byHour) [...xs]
      ],
      'hourly_days': week.length,
      'hourly_note': hourlyNote,
    },
  };
}

/// One night as 24 hourly asleep-fractions on a noon-anchored axis.
List<double>? _column(num? onsetTs, num? wakeTs) {
  if (onsetTs == null || wakeTs == null || wakeTs <= onsetTs) return null;
  final onset = DateTime.fromMillisecondsSinceEpoch(onsetTs.round() * 1000);
  // Anchor at the noon BEFORE sleep onset, so a 23:40 start and a 01:10 start
  // land in the same column rather than a day apart.
  final anchor = onset.hour < 12
      ? DateTime(onset.year, onset.month, onset.day - 1, 12)
      : DateTime(onset.year, onset.month, onset.day, 12);
  final a = anchor.millisecondsSinceEpoch / 1000;
  final lo = (onsetTs - a) / 3600, hi = (wakeTs - a) / 3600;
  if (hi <= 0 || lo >= 24) return null;
  return [
    for (var h = 0; h < 24; h++)
      ((hi < h + 1 ? hi : h + 1) - (lo > h ? lo : h)).clamp(0.0, 1.0).toDouble(),
  ];
}
