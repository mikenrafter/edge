// Generic executors accept a named work contract so their dispatch is visible
// to the heavy-work guard. Inline implementations keep lexical closure bodies
// traceable: unknown callback sources still fail the guard.
import 'package:sqflite/sqflite.dart';

abstract interface class AsyncWork<T> {
  Future<T> run();
}

final class InlineAsyncWork<T> implements AsyncWork<T> {
  const InlineAsyncWork(this.body);
  final Future<T> Function() body;
  @override
  Future<T> run() => body();
}

abstract interface class TransactionWork<T> {
  Future<T> run(Transaction transaction);
}

final class InlineTransactionWork<T> implements TransactionWork<T> {
  const InlineTransactionWork(this.body);
  final Future<T> Function(Transaction) body;
  @override
  Future<T> run(Transaction transaction) => body(transaction);
}
