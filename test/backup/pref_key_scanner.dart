// Source-only preference key resolution. Class members keep their owner so two
// stores named `key` cannot hide each other or capture an enum's instance key.
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';

class PrefKeyScanner {
  PrefKeyScanner(Map<String, String> sources) {
    for (final entry in sources.entries) {
      final scopes = <(int, int, String)>[];
      final unit = parseString(content: entry.value, throwIfDiagnostics: false).unit;
      void visit(AstNode node) {
        if (node is VariableDeclaration &&
            node.parent is VariableDeclarationList &&
            (node.parent as VariableDeclarationList).isFinal &&
            node.initializer is StringLiteral) {
          AstNode scope = node;
          while (scope.parent != null && scope is! Block &&
              scope is! ClassDeclaration && scope is! CompilationUnit) {
            scope = scope.parent!;
          }
          final literal = node.initializer!;
          final source = entry.value.substring(literal.offset, literal.end);
          final value = literal is SimpleStringLiteral
              ? literal.value : source.substring(1, source.length - 1);
          (_runtime[entry.key] ??= []).add(
              (node.offset, scope.end, node.name.lexeme, value));
        }

        if (node is ClassDeclaration || node is EnumDeclaration) {
          final name = RegExp(r'\b(?:class|enum)\s+(\w+)')
              .firstMatch(node.toSource())!.group(1)!;
          scopes.add((node.offset, node.end, name));
          if (node is EnumDeclaration) {
            final source = node.toSource();
            final field = RegExp('const $name\\(this\\.(\\w+)\\)')
                .firstMatch(source)?.group(1);
            if (field != null) {
              final values = <String>{};
              final constants = source.substring(0, source.indexOf(';'));
              for (final m in RegExp(r'''(\w+)\(\s*['"]([^'"$]+)['"]\s*\)''')
                  .allMatches(constants)) {
                _add(entry.key, '$name.${m.group(1)}.$field', m.group(2)!);
                values.add(m.group(2)!);
              }
              for (final value in values) {
                _add(entry.key, '$name.$field', value);
              }
            }
          }
        }
        for (final child in node.childEntities.whereType<AstNode>()) {
          visit(child);
        }
      }
      visit(unit);
      _scopes[entry.key] = scopes;
      for (final match in _constants.allMatches(entry.value)) {
        final owner = _owner(entry.key, match.start);
        final name = '${owner == null ? '' : '$owner.'}${match.group(1)}';
        _add(entry.key, name, match.group(2) ?? match.group(3)!);
      }
    }
    for (var round = 0; round < 3; round++) {
      for (final entry in sources.entries) {
        for (final match in _aliases.allMatches(entry.value)) {
          final owner = _owner(entry.key, match.start);
          final name = '${owner == null ? '' : '$owner.'}${match.group(1)}';
          for (final value in resolve(entry.key, match.group(2)!, match.start)) {
            _add(entry.key, name, value);
          }
        }
      }
    }
  }

  static final _constants = RegExp(
      r'''(?:static\s+)?const\s+(?:String\s+)?(\w+)\s*=\s*(?:'([^'$]*)'|"([^"$]*)")\s*;''');
  static final _aliases = RegExp(
      r'(?:static\s+)?const\s+(?:String\s+)?(\w+)\s*=\s*([A-Za-z_]\w*(?:\.\w+)?)\s*;');
  final _runtime = <String, List<(int, int, String, String)>>{};
  final _scopes = <String, List<(int, int, String)>>{};
  final _local = <String, Map<String, Set<String>>>{};
  final _global = <String, Set<String>>{};

  String? _owner(String file, int offset) {
    for (final scope in _scopes[file] ?? <(int, int, String)>[]) {
      if (scope.$1 <= offset && offset < scope.$2) return scope.$3;
    }
    return null;
  }

  void _add(String file, String name, String value) {
    ((_local[file] ??= {})[name] ??= {}).add(value);
    (_global[name] ??= {}).add(value);
    (_global[name.split('.').last] ??= {}).add(value);
  }

  Set<String> resolve(String file, String expr, int offset,
      {bool interpolated = false}) {
    if ((expr.startsWith("'") && expr.endsWith("'")) ||
        (expr.startsWith('"') && expr.endsWith('"'))) {
      return !interpolated && expr.contains(r'$')
          ? {} : {expr.substring(1, expr.length - 1)};
    }
    if (interpolated) {
      for (final local in (_runtime[file] ?? <(int, int, String, String)>[]).reversed) {
        if (local.$1 < offset && offset < local.$2 && local.$3 == expr) {
          return {local.$4};
        }
      }
    }
    final owner = _owner(file, offset);
    if (!expr.contains('.') && owner != null) {
      final scoped = _local[file]?['$owner.$expr'];
      if (scoped != null) return scoped;
    }
    final local = _local[file]?[expr];
    if (local != null) return local;
    final global = _global[expr];
    return global?.length == 1 ? global! : {};
  }
}
