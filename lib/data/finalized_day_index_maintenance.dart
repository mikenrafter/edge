import '../util/callable.dart';
import 'db.dart';

/// Optional foreground maintenance; the database owns its gates and lifetime.
class FinalizedDayIndexMaintenance implements Call0<Future<void>> {
  const FinalizedDayIndexMaintenance();

  @override
  Future<void> call() => LocalDb.prepareFinalizedDayIndex();
}
