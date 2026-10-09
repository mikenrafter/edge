import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

/// One place in a Dart file where it may read source text.
class SourceSite {
  const SourceSite(this.line, this.rule, this.detail);
  final int line;

  /// Short rule id: `source-path`, `path-not-literal`, `read-call`,
  /// `Platform.script`, `cwd`, `unparsable`.
  final String rule;
  final String detail;

  String describe(String file) => '$file:$line [$rule] $detail';
}

/// What reading one Dart file as an AST showed.
class SourceFacts {
  const SourceFacts(this.sites, [this.uris = const []]);
  final List<SourceSite> sites;

  /// Every URI of every import, export and part directive, the URIs of
  /// conditional configurations (`if (dart.library.io) 'b.dart'`) included.
  final List<String> uris;
}

/// The top-level directories whose text counts as source whatever is mutated.
const defaultSourceRoots = ['lib', 'tool', 'packages', 'bin'];

/// Finds every place in [text] that may read source text: a file-system access
/// whose path is NOT a compile-time string that lies outside [sourceRoots].
///
/// Conservative by construction, because a path that cannot be resolved here
/// could be anything (a variable, a parameter, `Platform.script`, a call):
///
/// - `File(x)` / `Directory(x)` / `Link(x)` (also `new`, `io.File`, `.fromUri`,
///   `.new` tear-offs and `typedef` aliases of them) is a site unless `x`
///   resolves, through string literals, interpolation, `+`, adjacent strings,
///   `final` / `const` variables of the file and `package:path` `join`, to a
///   path that is not under a source root, not the package root (`.`, `..`,
///   `/`), and not inside `lib` after normalisation (`test/../lib/a`);
/// - a call of `readAsString*` / `readAsBytes*` / `readAsLines*` / `openRead` /
///   `list*` on a receiver that is not itself such a
///   construction (or a `final` variable initialised with one) is a site: its
///   path is unknown;
/// - `Platform.script`, `Platform.packageConfig`, `Isolate.resolvePackageUri`,
///   `Isolate.packageConfig`, and `Directory.current` / `Uri.base` (the bases
///   of paths built at run time);
/// - any string literal that starts at a source root (`lib/...`,
///   `../lib/...`, `${x}/lib/...`), and a `join` whose first part is a root;
/// - a file with syntax errors (it cannot be checked).
SourceFacts analyseSourceReads(String text, {required List<String> sourceRoots}) {
  final parsed = parseString(content: text, throwIfDiagnostics: false);
  if (parsed.errors.isNotEmpty) {
    final first = parsed.errors.first;
    return SourceFacts([
      SourceSite(parsed.lineInfo.getLocation(first.offset).lineNumber, 'unparsable',
          'syntax error (${first.message}); the file cannot be checked')
    ]);
  }
  final scope = _Scope();
  parsed.unit.accept(scope);
  final finder = _Finder(scope, sourceRoots.toSet(), parsed.lineInfo);
  parsed.unit.accept(finder);
  return SourceFacts(finder.sites, scope.uris);
}

const _fsClasses = {'File', 'Directory', 'Link'};
const _readCalls = {
  'readAsString', 'readAsStringSync', 'readAsBytes', 'readAsBytesSync', 'readAsLines',
  'readAsLinesSync', 'openRead', 'list', 'listSync',
};

/// Declarations of the file: which names are declared exactly once as a
/// `final` / `const` variable with an initializer (only those resolve).
class _Scope extends RecursiveAstVisitor<void> {
  final Map<String, int> declared = {};
  final Map<String, Expression> initializers = {};
  final Set<String> fsAliases = {..._fsClasses};

  final List<String> uris = [];

  void _uri(StringLiteral? uri) {
    final v = uri?.stringValue;
    if (v != null && !uris.contains(v)) uris.add(v);
  }

  @override
  void visitExportDirective(ExportDirective node) {
    _uri(node.uri);
    for (final c in node.configurations) {
      _uri(c.uri);
    }
    super.visitExportDirective(node);
  }

  @override
  void visitPartDirective(PartDirective node) {
    _uri(node.uri);
    super.visitPartDirective(node);
  }

  @override
  void visitPartOfDirective(PartOfDirective node) {
    _uri(node.uri);
    super.visitPartOfDirective(node);
  }

  /// Prefixes (null: unprefixed) under which `package:path/path.dart` is imported.
  final Set<String?> pathPrefixes = {};

  void _name(Token? t) {
    if (t != null) declared[t.lexeme] = (declared[t.lexeme] ?? 0) + 1;
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    _name(node.name);
    final list = node.parent;
    final init = node.initializer;
    if (init != null && list is VariableDeclarationList && (list.isFinal || list.isConst)) {
      initializers[node.name.lexeme] = init;
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter node) {
    _name(node.name);
    super.visitSimpleFormalParameter(node);
  }

  @override
  void visitFieldFormalParameter(FieldFormalParameter node) {
    _name(node.name);
    super.visitFieldFormalParameter(node);
  }

  @override
  void visitSuperFormalParameter(SuperFormalParameter node) {
    _name(node.name);
    super.visitSuperFormalParameter(node);
  }

  @override
  void visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    _name(node.name);
    super.visitFunctionTypedFormalParameter(node);
  }

  @override
  void visitCatchClauseParameter(CatchClauseParameter node) {
    _name(node.name);
    super.visitCatchClauseParameter(node);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    _name(node.name);
    super.visitDeclaredIdentifier(node);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    _name(node.name);
    super.visitDeclaredVariablePattern(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _name(node.name);
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    final t = node.type;
    if (t is NamedType && _fsClasses.contains(t.name.lexeme)) fsAliases.add(node.name.lexeme);
    super.visitGenericTypeAlias(node);
  }

  @override
  void visitImportDirective(ImportDirective node) {
    _uri(node.uri);
    for (final c in node.configurations) {
      _uri(c.uri);
    }
    if (node.uri.stringValue == 'package:path/path.dart') pathPrefixes.add(node.prefix?.name);
    super.visitImportDirective(node);
  }
}

class _Finder extends RecursiveAstVisitor<void> {
  _Finder(this.scope, this.roots, this.lines);
  final _Scope scope;
  final Set<String> roots;
  final LineInfo lines;
  final List<SourceSite> sites = [];

  void _site(AstNode node, String rule, String detail) {
    final line = lines.getLocation(node.offset).lineNumber;
    // One site per line and rule: `File('lib/a.dart')` is also a source literal.
    if (sites.any((s) => s.line == line && s.rule == rule)) return;
    sites.add(SourceSite(line, rule, detail));
  }

  static String _snip(AstNode n) {
    final s = n.toSource().replaceAll(RegExp(r'\s+'), ' ');
    return s.length > 70 ? '${s.substring(0, 67)}...' : s;
  }

  // ----- constant string evaluation -----

  String? _eval(Expression? e, [int depth = 0]) {
    if (e == null || depth > 12) return null;
    switch (e) {
      case SimpleStringLiteral():
        return e.value;
      case AdjacentStrings():
        final parts = [for (final s in e.strings) _eval(s, depth + 1)];
        return parts.contains(null) ? null : parts.join();
      case StringInterpolation():
        final b = StringBuffer();
        for (final el in e.elements) {
          if (el is InterpolationString) {
            b.write(el.value);
          } else if (el is InterpolationExpression) {
            final v = _eval(el.expression, depth + 1);
            if (v == null) return null;
            b.write(v);
          }
        }
        return b.toString();
      case ParenthesizedExpression():
        return _eval(e.expression, depth + 1);
      case BinaryExpression() when e.operator.lexeme == '+':
        final l = _eval(e.leftOperand, depth + 1), r = _eval(e.rightOperand, depth + 1);
        return l == null || r == null ? null : l + r;
      case SimpleIdentifier():
        if (scope.declared[e.name] != 1) return null;
        return _eval(scope.initializers[e.name], depth + 1);
      case MethodInvocation() when _isPathJoin(e):
        final parts = <String>[];
        for (final a in e.argumentList.arguments) {
          if (a is NamedExpression) return null;
          final v = _eval(a, depth + 1);
          if (v == null) return null;
          parts.add(v);
        }
        return parts.isEmpty ? null : p.posix.joinAll(parts);
      default:
        return null;
    }
  }

  bool _isPathJoin(MethodInvocation e) {
    if (e.methodName.name != 'join') return false;
    final t = e.realTarget;
    if (t == null) return scope.pathPrefixes.contains(null);
    if (t is SimpleIdentifier) return scope.pathPrefixes.contains(t.name);
    // p.posix.join / p.windows.join
    if (t is PrefixedIdentifier) {
      return scope.pathPrefixes.contains(t.prefix.name) && (t.identifier.name == 'posix' || t.identifier.name == 'windows');
    }
    if (t is PropertyAccess && t.target is SimpleIdentifier) {
      return scope.pathPrefixes.contains((t.target as SimpleIdentifier).name) &&
          (t.propertyName.name == 'posix' || t.propertyName.name == 'windows');
    }
    return false;
  }

  /// A `Uri.file('x')` / `Uri.parse('x')` / `Uri.directory('x')` with a constant argument.
  String? _evalUri(Expression? e) {
    if (e is MethodInvocation) {
      final t = e.realTarget;
      if (t is SimpleIdentifier &&
          t.name == 'Uri' &&
          const {'file', 'parse', 'directory'}.contains(e.methodName.name) &&
          e.argumentList.arguments.isNotEmpty) {
        final v = _eval(e.argumentList.arguments.first);
        if (v == null) return null;
        return v.startsWith('file://') ? v.substring(7) : v;
      }
    }
    return null;
  }

  /// Why [path] reaches source, or null when it clearly does not.
  String? _sourceReach(String path) {
    var n = p.posix.normalize(path);
    if (n == '.' || n == '' || n == '/' || n == '..' || RegExp(r'^(\.\./?)+$').hasMatch(n)) {
      return 'covers the package root';
    }
    final absolute = n.startsWith('/');
    final segments = n.split('/').where((s) => s.isNotEmpty && s != '.').toList();
    while (segments.isNotEmpty && segments.first == '..') {
      segments.removeAt(0);
    }
    if (segments.isEmpty) return 'covers the package root';
    final hit = absolute ? segments.where(roots.contains).firstOrNull : (roots.contains(segments.first) ? segments.first : null);
    return hit == null ? null : 'is under the source root $hit/';
  }

  // ----- constructions and calls -----

  /// The receiver is a construction judged at its own site, or a `final`
  /// variable initialised with one.
  bool _isConstruction(Expression? e, [int depth = 0]) {
    if (e == null || depth > 8) return false;
    if (e is ParenthesizedExpression) return _isConstruction(e.expression, depth + 1);
    if (e is InstanceCreationExpression) return scope.fsAliases.contains(e.constructorName.type.name.lexeme);
    if (e is MethodInvocation) return _constructionOf(e) != null;
    if (e is SimpleIdentifier) {
      if (scope.declared[e.name] != 1) return false;
      return _isConstruction(scope.initializers[e.name], depth + 1);
    }
    return false;
  }

  /// `File(...)`, `io.File(...)`, `File.fromUri(...)` as a method invocation.
  ({String cls, String ctor})? _constructionOf(MethodInvocation e) {
    final name = e.methodName.name;
    final t = e.realTarget;
    if (scope.fsAliases.contains(name) && (t == null || t is SimpleIdentifier)) return (cls: name, ctor: '');
    if ((name == 'fromUri' || name == 'fromRawPath' || name == 'new') && t != null) {
      final cls = t is SimpleIdentifier ? t.name : (t is PrefixedIdentifier ? t.identifier.name : null);
      if (cls != null && scope.fsAliases.contains(cls)) return (cls: cls, ctor: name);
    }
    return null;
  }

  void _judgeConstruction(AstNode node, String cls, String ctor, List<Expression> args) {
    final shown = _snip(node);
    if (ctor == 'fromRawPath' || args.isEmpty) {
      _site(node, 'path-not-literal', '$shown: the path is not a compile-time string literal');
      return;
    }
    final first = args.first;
    final path = ctor == 'fromUri' ? _evalUri(first) : _eval(first);
    if (path == null) {
      _site(node, 'path-not-literal', '$shown: the path is not a compile-time string literal');
      return;
    }
    final why = _sourceReach(path);
    if (why != null) _site(node, 'source-path', '$shown: "$path" $why');
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final cls = node.constructorName.type.name.lexeme;
    if (scope.fsAliases.contains(cls)) {
      final ctor = node.constructorName.name?.name ?? '';
      _judgeConstruction(node, cls, ctor == 'new' ? '' : ctor, node.argumentList.arguments);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final c = _constructionOf(node);
    if (c != null) {
      if (c.ctor == 'new' && node.argumentList.arguments.isEmpty) {
        _site(node, 'path-not-literal', '${_snip(node)}: the path is not a compile-time string literal');
      } else {
        _judgeConstruction(node, c.cls, c.ctor == 'new' ? '' : c.ctor, node.argumentList.arguments);
      }
    } else if (_readCalls.contains(node.methodName.name) && !_isConstruction(node.realTarget)) {
      _site(node, 'read-call',
          '${node.methodName.name}(): the receiver is not a File/Directory/Link with a known path');
    } else if (node.methodName.name == 'resolvePackageUri') {
      _site(node, 'Platform.script', '${_snip(node)}: resolves a package to a source location');
    } else if (node.methodName.name == 'join' && _isPathJoin(node)) {
      final v = _eval(node);
      if (v != null && _startsAtRoot(v)) _site(node, 'source-path', '${_snip(node)}: builds "$v", a path under a source root');
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final prefix = node.prefix.name, name = node.identifier.name;
    if (prefix == 'Platform' && (name == 'script' || name == 'packageConfig')) {
      _site(node, 'Platform.script', '${_snip(node)}: a path relative to the running script');
    } else if (prefix == 'Isolate' && name == 'packageConfig') {
      _site(node, 'Platform.script', '${_snip(node)}: the package configuration locates source');
    } else if (prefix == 'Directory' && name == 'current') {
      _location(node, 'Directory.current');
    } else if (prefix == 'Uri' && name == 'base') {
      _location(node, 'Uri.base');
    } else if (scope.fsAliases.contains(prefix) && (name == 'new' || name == 'fromUri' || name == 'fromRawPath')) {
      _site(node, 'path-not-literal', '${_snip(node)}: a constructor tear-off hides the path');
    } else if (_readCalls.contains(name) && node.parent is! MethodInvocation) {
      _site(node, 'read-call', '$name: a tear-off of a read; the path is unknown');
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final name = node.propertyName.name;
    final t = node.target;
    final targetName = t is SimpleIdentifier ? t.name : (t is PrefixedIdentifier ? t.identifier.name : null);
    if (targetName == 'Platform' && (name == 'script' || name == 'packageConfig')) {
      _site(node, 'Platform.script', '${_snip(node)}: a path relative to the running script');
    } else if (targetName == 'Isolate' && name == 'packageConfig') {
      _site(node, 'Platform.script', '${_snip(node)}: the package configuration locates source');
    } else if (targetName == 'Directory' && name == 'current') {
      _location(node, 'Directory.current');
    } else if (targetName == 'Uri' && name == 'base') {
      _location(node, 'Uri.base');
    }
    super.visitPropertyAccess(node);
  }

  // ----- string literals -----

  /// [value] is (or starts with) a path at a source root: `lib`, `lib/x`,
  /// `./lib/x`, `../lib/x`, `a/../lib/x`; an absolute path through one.
  bool _startsAtRoot(String value) {
    if (!value.contains('/') && !roots.contains(value)) return false;
    final n = p.posix.normalize(value);
    final segments = n.split('/').where((s) => s.isNotEmpty && s != '.').toList();
    while (segments.isNotEmpty && segments.first == '..') {
      segments.removeAt(0);
    }
    if (segments.isEmpty) return false;
    return n.startsWith('/') ? segments.any(roots.contains) : roots.contains(segments.first);
  }

  /// Where the program runs from: a base for paths built at run time.
  void _location(AstNode node, String what) =>
      _site(node, 'cwd', '${_snip(node)}: $what is a base for paths built at run time');

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (node.parent is Directive || node.parent is Configuration) return;
    if (node.value.contains('/') && _startsAtRoot(node.value)) _site(node, 'source-path', '${_snip(node)}: a path that starts at a source root');
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    final resolved = _eval(node);
    if (resolved != null) {
      if (_startsAtRoot(resolved)) {
        _site(node, 'source-path', '${_snip(node)}: builds "$resolved", a path under a source root');
      }
    } else {
      // Not resolvable: the parts that are literal still show a root.
      final els = node.elements;
      for (var i = 0; i < els.length; i++) {
        final el = els[i];
        if (el is! InterpolationString) continue;
        final starts = i == 0 ? _startsAtRoot(el.value) : roots.any((r) => el.value.startsWith('/$r/'));
        if (starts) {
          _site(node, 'source-path', '${_snip(node)}: a path that goes through a source root');
          break;
        }
      }
    }
    super.visitStringInterpolation(node);
  }

  @override
  void visitImportDirective(ImportDirective node) {}
  @override
  void visitExportDirective(ExportDirective node) {}
  @override
  void visitPartDirective(PartDirective node) {}
}
