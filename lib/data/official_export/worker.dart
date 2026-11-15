import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../import/backup_crypto.dart';
import '../../util/heavy.dart';
import '../../util/worker_init.dart';
import '../substrate_archive_codec.dart';
import '../day_label.dart';

// CLAIM(export-typed-hash): NULL, integers, IEEE doubles, text and blobs have
// distinct encodings [export_test; canonical hash tests]. Length framing is JSON.
String canonicalValue(Object? value) => switch (value) {
  null => 'n',
  int v => 'i$v',
  double v =>
    'd${base64Encode((ByteData(8)..setFloat64(0, v)).buffer.asUint8List())}',
  String v => 's$v',
  List<int> v => 'b${base64Encode(v)}',
  _ => throw FormatException('Unsupported SQLite value ${value.runtimeType}'),
};

@heavy
String hashOfficialRowsHeavy(
  WorkerInputs inputs,
  OfficialRows input,
  List<String> columns,
  String previous,
) {
  WorkerInit.ensure(inputs);
  assertWorker();
  var digest = previous;
  for (final row in input.rows) {
    digest = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              digest,
              for (final c in columns) canonicalValue(row[c]),
            ]),
          ),
        )
        .toString();
  }
  return digest;
}

@heavy
Future<String> officialFileHashHeavy(WorkerInputs inputs, String path) async {
  WorkerInit.ensure(inputs);
  assertWorker();
  return (await sha256.bind(File(path).openRead()).first).toString();
}

@heavy
Future<void> sealOfficialFileHeavy(
  WorkerInputs inputs,
  String source,
  String encrypted,
  String passphrase,
) async {
  WorkerInit.ensure(inputs);
  assertWorker();
  await encryptBackupFile(File(source), File(encrypted), passphrase);
}

@heavy
Future<void> openOfficialFileHeavy(
  WorkerInputs inputs,
  String encrypted,
  String plain,
  String passphrase,
) async {
  WorkerInit.ensure(inputs);
  assertWorker();
  await decryptBackupFile(File(encrypted), File(plain), passphrase);
}

// One UTC archive bucket at a time. Row maps preserve the codec's SQL types.
@heavy
OfficialArchiveBucket? expandOfficialBucketHeavy(
  WorkerInputs inputs,
  Uint8List blob,
  int codec,
  int fingerprint,
) {
  WorkerInit.ensure(inputs);
  assertWorker();
  final bucket = SubstrateArchiveCodec.decode(blob, codec: codec);
  if (bucket == null ||
      SubstrateArchiveCodec.fingerprint(bucket) != fingerprint) {
    return null;
  }
  final beats = <int, List<Map<String, Object?>>>{};
  for (var i = 0; i < bucket.rr.rowCount; i++) {
    final row = bucket.rr.rowAt(i);
    (beats[(row['ts_ms'] as num).toInt()] ??= []).add(row);
  }
  return OfficialArchiveBucket(
    onehz: [
      for (var i = 0; i < bucket.onehz.rowCount; i++) bucket.onehz.rowAt(i),
    ],
    beats: beats,
  );
}

@SendableShape(
  'bounded native SQLite pages preserve NULL, integers, doubles, text and Uint8List blobs; round-trip tests pin the storage classes',
)
class OfficialRows {
  const OfficialRows(this.rows);
  final List<Map<String, Object?>> rows;
}

@SendableShape(
  'one lossless bucket carries exact SQLite row maps and beat lists keyed by physiological milliseconds; round-trip tested',
)
class OfficialArchiveBucket {
  const OfficialArchiveBucket({required this.onehz, required this.beats});
  final List<Map<String, Object?>> onehz;
  final Map<int, List<Map<String, Object?>>> beats;
}

@heavy
List<List<int>>? decodeOfficialWindowsHeavy(WorkerInputs inputs, String text) {
  WorkerInit.ensure(inputs);
  assertWorker();
  try {
    final decoded = jsonDecode(text) as List;
    final windows = <List<int>>[];
    for (final value in decoded) {
      final pair = value as List;
      if (pair.length != 2 ||
          pair[0] is! int ||
          pair[1] is! int ||
          (pair[1] as int) <= (pair[0] as int)) {
        return null;
      }
      windows.add([pair[0] as int, pair[1] as int]);
    }
    return windows;
  } catch (_) {
    return null;
  }
}

@heavy
({String json, List<String> omitted})? sanitizeOfficialActivityHeavy(
  WorkerInputs inputs,
  String text,
) {
  WorkerInit.ensure(inputs);
  assertWorker();
  try {
    final details = jsonDecode(text) as Map;
    final sport = details['sport'];
    final safe = <String, Object?>{
      if (sport is String && sport.length <= 80) 'sport': sport,
    };
    return (
      json: jsonEncode(safe),
      omitted: [
        for (final key in details.keys)
          if (!safe.containsKey(key)) 'details_json.$key',
      ],
    );
  } catch (_) {
    return null;
  }
}

@heavy
List<String> officialCoveredDaysHeavy(WorkerInputs inputs, OfficialRows page) {
  WorkerInit.ensure(inputs);
  assertWorker();
  return [
    for (final row in page.rows)
      dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch((row['rec_ts'] as int) * 1000),
      ),
  ];
}

// One worker per bounded SQL page, rather than one isolate per decision.
@heavy
List<({String json, List<String> omitted})?> sanitizeOfficialActivitiesHeavy(
  WorkerInputs inputs,
  List<String> texts,
) {
  WorkerInit.ensure(inputs);
  assertWorker();
  return [
    for (final text in texts) sanitizeOfficialActivityHeavy(inputs, text),
  ];
}

@heavy
OfficialArchiveKeys officialArchiveKeysHeavy(
  WorkerInputs inputs,
  OfficialRows live,
  OfficialRows archived,
) {
  WorkerInit.ensure(inputs);
  assertWorker();
  return OfficialArchiveKeys(
    live: {for (final row in live.rows) row['ts_ms'] as int},
    archived: {for (final row in archived.rows) row['ts_ms'] as int},
  );
}

@SendableShape(
  'sets contain only integer recording milliseconds; sendable_officialArchiveKeysHeavy_test pins both sets across the real isolate boundary',
)
class OfficialArchiveKeys {
  const OfficialArchiveKeys({required this.live, required this.archived});
  final Set<int> live, archived;
}
