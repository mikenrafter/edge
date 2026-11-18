// WHY: a set maintained by one derive path but never consulted made the
// tonight-pending fence inert. Scan private fields in compute/data, including
// their uses in part files. Collection mutations alone do not count as reads.
// Proves CLAIM(private-field-consumer).
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

const _mutators = {
  'add', 'addAll', 'remove', 'removeAll', 'removeWhere', 'retainAll',
  'retainWhere', 'clear', 'insert', 'insertAll', 'sort', 'setAll',
  'setRange', 'fillRange', 'removeRange', 'replaceRange', 'shuffle',
};

class _Fields extends RecursiveAstVisitor<void> {
  final declarations = <String>{};
  final reads = <String>{};
  final writes = <String>{};

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    for (final field in node.fields.variables) {
      final name = field.name.lexeme;
      if (name.startsWith('_')) declarations.add(name);
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final name = node.name;
    if (!name.startsWith('_') || node.inDeclarationContext()) return;
    AstNode reference = node;
    final parent = node.parent;
    if (parent is MethodInvocation && identical(parent.methodName, node)) return;
    if (parent is PropertyAccess && identical(parent.propertyName, node)) {
      reference = parent;
    } else if (parent is PrefixedIdentifier && identical(parent.identifier, node)) {
      reference = parent;
    }
    final use = reference.parent;
    if (use is AssignmentExpression && identical(use.leftHandSide, reference) &&
            use.operator.lexeme != '??=' ||
        use is PostfixExpression && use.parent is ExpressionStatement ||
        use is PrefixExpression && const {'++', '--'}.contains(use.operator.lexeme) &&
            use.parent is ExpressionStatement) {
      writes.add(name);
    } else if (use is MethodInvocation && identical(use.target, reference) &&
        _mutators.contains(use.methodName.name) && use.parent is ExpressionStatement) {
      writes.add(name);
    } else {
      reads.add(name);
    }
  }
}

Set<String> _writeOnly(Iterable<String> sources) {
  final fields = _Fields();
  for (final source in sources) {
    parseString(content: source, throwIfDiagnostics: false).unit.accept(fields);
  }
  return fields.declarations.intersection(fields.writes).difference(fields.reads);
}

void main() {
  test('detects mutation-only fields and accepts actual consumers across parts', () {
    const broken = '''
class Engine {
  final Set<String> _unfinished = {};
  int _counter = 0;
  void pool() { _unfinished.addAll(['day']); _unfinished.remove('day'); _counter++; }
}
''';
    expect(_writeOnly([broken]), {'_unfinished', '_counter'});
    expect(_writeOnly([broken, '''
extension Prepare on Engine {
  bool pending(String day) => _unfinished.contains(day) && _counter > 0;
}
''']), isEmpty);
    expect(_writeOnly(['''
class Gate {
  final Set<String> _owners = {};
  bool release(String owner) => _owners.remove(owner);
}
''']), isEmpty, reason: 'a consumed mutation result is an observable use');
    expect(_writeOnly(['''
class Counter {
  int _next = 0;
  Object? _memo;
  int claim() => ++_next;
  Object memo() => _memo ??= Object();
}
''']), isEmpty, reason: 'consumed increments and memoization read the field');
  });

  test('private compute/data fields have consumers beyond writes', () {
    final files = [
      for (final root in ['lib/compute', 'lib/data'])
        ...Directory(root).listSync(recursive: true).whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
    ];
    expect(files, isNotEmpty);
    // Existing reserved M5 diagnostic: derive_prepare.dart documents that the
    // mixed-unit drop count cannot yet be carried by Substrate. Keep this one
    // explicit exception until that output has an owner; new dead fields fail.
    const reserved = {'_skinTempUnitDrops'};
    expect(_writeOnly(files.map((f) => f.readAsStringSync())).difference(reserved), isEmpty,
        reason: 'remove dead state or wire it into its owning policy');
  });
}
