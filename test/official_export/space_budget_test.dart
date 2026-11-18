// WHY: CLAIM(official-export-live-space-floor), growth must stop BEFORE the WAL
// reserve, including exact archive expansion. P3 connects platform free space.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/space_budget.dart';
class FreeSpace implements ExportFreeSpace {
 FreeSpace(this.bytes);
 int bytes;
 @override
 Future<int> readAvailableBytes() async => bytes;
}
void main() {
  test('literal peak budget includes snapshot, mapped growth and expansion', () {
    expect(ExportSpaceBudget.mappedPeakBytes(100, 300), 8389608);
  });
  test('preflight and each growing write preserve a separate live floor', () async {
    final free = FreeSpace(101);
    final budget = ExportSpaceBudget(source: free, liveFloorBytes: 64);
    await budget.requireAvailable(37);
    free.bytes = 100;
    await expectLater(budget.requireAvailable(37), throwsA(isA<ExportSpaceExhausted>()));
    await budget.requireAvailable(36);
  });
}
