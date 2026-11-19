// The export never spends the space reserved for ingestion/WAL writes.
// CLAIM(official-export-live-space-floor) [space_budget_test; spec §3.2].
abstract interface class ExportFreeSpace {
  Future<int> readAvailableBytes();
}

class ExportSpaceBudget {
  const ExportSpaceBudget({required this.source, this.liveFloorBytes = 64 * 1024 * 1024});
  final ExportFreeSpace source;
  final int liveFloorBytes;

  // Snapshot + up to 3x SQL/index expansion + exact archive expansion. P3 adds
  // ciphertext/provider overlap to this same stage budget, not another guess.
  static int mappedPeakBytes(int snapshotBytes, int exactArchiveRawBytes) =>
      snapshotBytes * 4 + exactArchiveRawBytes * 2 + 8 * 1024 * 1024;

  Future<void> requireAvailable(int nextWriteBytes) async {
    final free = await source.readAvailableBytes();
    if (free - nextWriteBytes < liveFloorBytes) {
      throw ExportSpaceExhausted(free, nextWriteBytes, liveFloorBytes);
    }
  }
}

class ExportSpaceExhausted implements Exception {
  const ExportSpaceExhausted(this.freeBytes, this.nextWriteBytes, this.floorBytes);
  final int freeBytes, nextWriteBytes, floorBytes;
  @override
  String toString() => 'Export needs $nextWriteBytes bytes plus the $floorBytes live-data reserve; $freeBytes bytes available';
}
