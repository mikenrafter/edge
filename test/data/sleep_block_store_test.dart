// WHY: every spacing/history consumer must see the same served sleep set.
// CLAIM(sleep-block-live-read), CLAIM(sleep-ownership-one-rule).
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/sleep_block_store.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
import 'package:openstrap_edge/data/sleep_ownership.dart';
import 'package:openstrap_edge/data/sleep_spacing.dart';
import 'support/sleep_block_fixture.dart';
import 'support/sleep_projection.dart';

void main() {
  late Database db;
  final start = localDayStartSec(fixtureDay)!;
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await LocalDb.repairOpenSchemaForTest(db);
  });
  tearDown(() => db.close());
  Future<List<SleepBlock>> live() => SleepBlockStore.live(db, start, start + 43200);
  Future<void> stored(String id, {String state = 'live', String kind = 'nap', int? at,
      String day = fixtureDay}) => db.insert('sleep_block',blockRow(id, kind:kind,
        day:day, state:state, start:at ?? start + 3600,end:(at ?? start + 3600)+1800));
  Future<void> detected({bool envelope = false, int? version, int skipped = 0,
      int shift = 0}) => seedDay(db, fixtureDay, version:version,skipped:skipped,
        window:envelope ? {'value':{'onset_ms':(start+shift)*1000,'offset_ms':(start+7200+shift)*1000}}
        : {'onset_ms':(start+shift)*1000,'offset_ms':(start+7200+shift)*1000});

  // catches: selecting all block states, or treating an unknown enum as live.
  test('S1 live excludes removed, merged and unknown rows', () async {
    await stored('live'); await stored('removed',state:'removed');
    await stored('merged',state:'merged'); await stored('bad',state:'future-state');
    await db.insert('sleep_block',blockRow('bad-kind',kind:'future-kind',start:start+3600,end:start+5400));
    await db.insert('sleep_block',blockRow('bad-source',source:'future-source',start:start+3600,end:start+5400));
    final rows = await live();
    expect(rows.map((b)=>b.id), ['live']);
    expect((rows.single.ownerDay, rows.single.revision, rows.single.provenance),
      (fixtureDay,0,SleepEntryProvenance.manual));
  });
  // catches: the original missing bare-window COALESCE.
  test('S2 live includes the literal bare main window', () async {
    await detected(); final rows = await live();
    expect(rows.map((b)=>(b.id,b.kind,b.startTs,b.endTs,b.provenance)),
      [(null,SleepBlockKind.main,start,start+7200,SleepEntryProvenance.automatic)]);
  });
  // catches: a reader that supports only the new bare writer shape.
  test('S3 live includes envelope windows and ignores absent/malformed ones', () async {
    await detected(envelope:true);
    expect((await live()).single.endTs,start+7200);
    await db.update('day_result',{'window_json':'—'}); expect(await live(),isEmpty);
    await db.update('day_result',{'window_json':'{}'}); expect(await live(),isEmpty);
  });
  // catches: automatic mains omitted from the store's spacing input. The old
  // repository seam is also pinned by nap_extend_test before the API move.
  test('S4 ten minutes after a bare wake requires Merge', () async {
    await detected();
    final blocks = await SleepBlockStore.live(db,start,start+10000);
    final proposal = SleepSpacing.evaluate(stored:blocks,changes:[BlockChange(after:
      SleepBlock(kind:SleepBlockKind.nap,day:fixtureDay,startTs:start+7800,endTs:start+9600))],editingDay:fixtureDay);
    expect(proposal?.startTs,start);
    expect(proposal?.endTs,start+9600);
  });
  // catches: only live main rows suppress a detection.
  test('S5 a removed main suppresses automatic sleep', () async {
    await detected(); await stored('main',kind:'main',state:'removed');
    expect(await live(),isEmpty);
  });
  // catches: a live main and detection counted twice.
  test('S6 a live main replaces automatic sleep', () async {
    await detected(); await stored('main',kind:'main');
    expect((await live()).map((b)=>(b.id,b.startTs)),[('main',start+3600)]);
  });
  // catches: MAX(version) without this build's ceiling, or equality-only read.
  test('S7 served older version survives a declined current and future sibling', () async {
    await detected(version:kAlgoVersion-1,shift:60);
    await detected(version:kAlgoVersion+1,shift:120);
    expect((await live()).single.startTs,start+60);
    await detected(version:kAlgoVersion,skipped:1,shift:180);
    expect(await live(),isEmpty,reason:'the selected skipped sibling suppresses the older one, like the screens');
  });
  // catches: ownership confused with geometric overlap; history lost on read.
  test('S8 read separates owned removed entries and framing neighbors', () async {
    await stored('own',state:'removed');
    await stored('neighbor',day:'2026-10-31',at:start-600);
    final r = await SleepBlockStore.read(db,fixtureDay);
    expect(r.entries.map((e)=>(e.id,e.removed)),[('own',true)]);
    expect(r.neighbors.map((b)=>b.id),['neighbor']);
    await db.delete('sleep_block');
    await db.insert('sleep_block',blockRow('night',kind:'main',start:start-3600,end:start+25200));
    await stored('afternoon',at:start+54000);
    await stored('evening-context',day:'2026-10-31',at:start-7200);
    final night = await SleepBlockStore.read(db,fixtureDay);
    expect(night.entries.map((e)=>e.id),['night','afternoon']);
    expect(night.neighbors.map((b)=>b.id),['evening-context']);
  });
  // catches: deriving suppression from the lossy natural-key projection, or
  // recomputing detected_day from an absorbed misdated nap's start instant.
  test('S9 napEdits retains collision and stored origin-day suppression', () async {
    await db.insert('sleep_block',blockRow('removed',state:'removed',start:1000,end:4600));
    await db.insert('sleep_block',blockRow('manual',start:1000,end:3400));
    await db.insert('sleep_block',blockRow('moved',day:'2026-11-02',start:9000,end:9600,
      history:'known',detectedStart:7000,detectedEnd:7600,detectedDay:fixtureDay));
    final edits = await SleepBlockStore.napEdits(db,fixtureDay);
    expect(edits.map((n)=>(n.kind.name,n.startSec,n.endSec)).toSet(),
      {('rejected',1000,4600),('added',1000,3400),('rejected',7000,7600)});
  });
  // catches: projector rewriting every day, losing a neighboring legacy row.
  test('S10 projector rewrites touched days only and clears main payload', () async {
    await db.insert('sleep_nap',napRow(1,2,'manual',day:'untouched'));
    final before = await db.query('sleep_nap',where:'day_id = ?',whereArgs:['untouched']);
    await stored('main',kind:'main'); await stored('nap');
    await stored('other',day:'2026-11-02');
    await SleepBlockStore.projectForTest(db,{fixtureDay,'2026-11-02'});
    await projectionMatches(db,'2026-11-02');
    await projectionMatches(db,fixtureDay);
    expect(await db.query('sleep_nap',where:'day_id = ?',whereArgs:['untouched']),before);
    expect((await db.query('sleep_override')).single['payload_json'],isNull);
  });
  // catches: nap ownership uses the end/wake date or UTC date. The matrix pins
  // the expected local labels independently for UTC/Denver/Kolkata.
  test('S11 nap ownership uses its start, and main ownership throws', () {
    final s = DateTime(2026,10,31,23,30).millisecondsSinceEpoch ~/ 1000;
    expect(SleepOwnership.dayOf(SleepBlockKind.nap,s,s+14400),'2026-10-31');
    expect(()=>SleepOwnership.dayOf(SleepBlockKind.main,s,s+14400),throwsArgumentError);
  });
  // catches: a 24-hour walk duplicates/skips a date on the fall-back boundary.
  test('S12 daysOf walks calendar midnights across the 25-hour day', () {
    final lo = localDayStartSec('2026-11-01')!, hi = localDayEndSec('2026-11-02')!;
    expect(SleepOwnership.daysOf(lo,hi-1),['2026-11-01','2026-11-02']);
    // The matrix's Denver run crosses 49 elapsed hours; enumeration must still
    // produce exactly these two calendar dates. No host-zone skip is used.
  });
}
