// Shared synthetic archive buckets for the official-export archive tests. Built
// through the real codec, so every bucket carries a genuine fingerprint.
import 'package:openstrap_edge/data/substrate_archive_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ArchiveTable archiveTable(List<Map<String,Object?>> rows) {
  final b = ArchiveTableBuilder()..addRows(rows); return b.build();
}
Future<void> bucket(Database db, int day, List<Map<String,Object?>> parents,
    List<Map<String,Object?>> beats, {bool corrupt = false,String device=''}) async {
  final w = SubstrateArchiveCodec.encodeMergeVerify(ArchiveBucket(archiveTable(parents),archiveTable(beats)));
  await db.insert('substrate_archive', {'device_id':device, 'utc_day':day,
    'codec':1, 'from_ts':w.fromTs ?? 1, 'to_ts':w.toTs ?? 1, 'onehz_rows':parents.length,
    'rr_rows':beats.length,'raw_bytes':w.rawBytes,'fingerprint':corrupt ? 1 : w.fingerprint,
    'blob':w.blob,'created_at':1,'updated_at':1});
}
Map<String,Object?> parent(int sec, Object? hr) => {'device_id':'','ts_ms':sec*1000,'rec_ts':sec,'counter':sec,'hr':hr};
Map<String,Object?> beat(int sec, int n) => {'device_id':'','ts_ms':sec*1000,'rec_ts':sec,'beat_index':n,'rr_ms':800,'rr_ts_ms':sec*1000+n*800};
