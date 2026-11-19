// WHY: R7, Sleep stores stable block ids while official v0.12.2 activity_store
// uses the literal '$day:$startTs' sleep_nap key. Export must keep that link.
// catches: copying the block id, using the suggestion's old start, or keeping pending inference.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/payload_requirements.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'rich_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in ['confirmed','merged','pending']) {
    test('nap suggestion link exports the surviving official nap key for $mode',()async {
      final fx=await RichFixture.build();
      try {
        final source=await databaseFactoryFfi.openDatabase(fx.forkPath);
        try {
          await source.delete('activity_suggestions');
          await source.delete('sleep_block');await source.delete('sleep_nap');
          final block={'id':'survivor','kind':'nap','owner_day':'2026-10-20','owner_rule':1,
            'start_ts':1792504800,'end_ts':1792506600,'source':'manual','state':'live',
            'history':'[]','revision':0,'created_at':1,'updated_at':1};
          await source.insert('sleep_block',block);
          if(mode=='merged') {
            await source.insert('sleep_block',{...block,'id':'old-block','state':'merged',
              'start_ts':1792505100,'end_ts':1792506300,'merged_into':'survivor'});
          }
          await source.insert('sleep_nap',{'day_id':'2026-10-20','start_ts':1792504800,
            'end_ts':1792506600,'source':'manual','created_at':1});
          await source.insert('activity_suggestions',{'id':'suggestion','kind':'nap',
            'day_id':'2026-10-20','start_ts':1792505100,'end_ts':1792506300,
            'detection_start':1792505100,'detection_end':1792506300,
            'status':mode=='pending'?'pending':'confirmed','revision':0,
            'linked_id':mode=='merged'?'old-block':'survivor','details_json':'{}','created_at':1,'updated_at':1});
        }finally{await source.close();}
        final report=await mapOfficialSnapshot(snapshotPath:fx.forkPath,
          outputPath:'${File(fx.forkPath).parent.path}/nap.db',factory:databaseFactoryFfi,
          calendar:const FixedOffsetCalendar(0));
        final target=await databaseFactoryFfi.openDatabase(report.path);
        try {
          final rows=await target.query('activity_suggestions');
          if(mode=='pending') {
            expect(rows,isEmpty);
            expect((report.tables['activity_suggestions'] as Map)['target_count'],0);
          }else {
            expect(rows.single['linked_id'],'2026-10-20:1792504800');
            expect(rows.single['status'],'confirmed');
            expect((await target.query('sleep_nap')).single['start_ts'],1792504800);
          }
        }finally{await target.close();}
      }finally{await fx.dispose();}
    });
  }
}
