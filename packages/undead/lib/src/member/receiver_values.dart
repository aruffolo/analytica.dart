import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';

import 'flow.dart';

/// Immutable receiver values at expression evaluation points in a body.
/// Unsupported control flow discards the entire refinement, not just a write.
class ReceiverValues {
  final ReceiverOrigin Function(Expression) fallback;
  final FunctionExpression? Function(Element?) lookupFunction;
  AstNode? _declaration;
  bool _passingFunctions = false;
  FunctionExpression? _escaping;
  FunctionExpression? _asyncFrame;
  final List<_ReceiverTask> _pending = [];
  final Map<Expression, _ReceiverTask> _futureExpressions = {};
  final Map<Element, _ReceiverTask> _futures = {};
  final Map<FunctionExpression, Set<Element>> _frames = {};
  bool _resuming = false;
  final Map<Expression, ReceiverOrigin> values = {};
  Map<Element, ReceiverOrigin> _state = {};
  Map<Element, Object> _constants = {};
  final Map<Expression, _Evaluation> _shortening = {};
  Map<Element, FunctionExpression> _functions = {};
  final Set<FunctionExpression> _activeCalls = {};
  var _callCount = 0;
  var _steps = 0;

  ReceiverValues(this.fallback, this.lookupFunction);

  Map<Expression, ReceiverOrigin> analyze(AstNode? declaration) {
    _declaration = declaration;
    final body = switch (declaration) {
      FunctionDeclaration(:final functionExpression) => functionExpression.body,
      MethodDeclaration(:final body) => body,
      _ => null,
    };
    if (body == null || body.isGenerator) return {};
    try {
      switch (body) {
        case BlockFunctionBody(:final block):
          _statement(block);
        case ExpressionFunctionBody(:final expression):
          _expression(expression);
        default:
          return {};
      }
      _drainTasks();
      return values;
    } on _ReturnFlow {
      try {
        _drainTasks();
        return values;
      } on _UnsupportedFlow {
        return {};
      }
    } on _UnsupportedFlow {
      return {};
    }
  }

  void _statement(Statement node) {
    _step();
    switch (node) {
      case Block(:final statements):
        _block(statements);
      case VariableDeclarationStatement(:final variables):
        _variables(variables);
      case ExpressionStatement(:final expression):
        _expression(expression);
      case FunctionDeclarationStatement():
        break;
      case ReturnStatement(:final expression):
        final function = _functionValue(expression);
        if (function != null) {
          if (_activeCalls.isNotEmpty || _pending.isNotEmpty) {
            throw const _UnsupportedFlow();
          }
          _escaping = function;
          _invoke(function, null);
          _escaping = null;
        } else if (expression != null) {
          _expression(expression);
        }
        throw const _ReturnFlow();
      case IfStatement(
        :final expression,
        :final thenStatement,
        :final elseStatement,
      ):
        if (node.caseClause != null) throw const _UnsupportedFlow();
        _expression(expression);
        _branches(() => _statement(thenStatement), () {
          if (elseStatement != null) _statement(elseStatement);
        });
      case ForStatement():
        _for(node);
      case WhileStatement(:final condition, :final body):
        _loop(body, condition, const []);
      case DoStatement(:final condition, :final body):
        _loop(body, condition, const [], atLeastOnce: true);
      case ContinueStatement(:final label):
        if (label != null) throw const _UnsupportedFlow();
        throw const _ContinueFlow();
      case EmptyStatement():
        break;
      default:
        throw const _UnsupportedFlow();
    }
  }

  void _block(Iterable<Statement> statements) {
    for (final declaration
        in statements.whereType<FunctionDeclarationStatement>()) {
      final function = declaration.functionDeclaration;
      final element = function.declaredFragment?.element;
      if (element != null) _functions[element] = function.functionExpression;
    }
    for (final statement in statements) {
      _statement(statement);
    }
  }

  ReceiverOrigin _expression(Expression node) {
    _step();
    final value = _evaluate(node);
    if (_inFamily(node)) {
      values[node] = values.containsKey(node)
          ? _union(values[node]!, value)
          : value;
    }
    return value;
  }

  ReceiverOrigin _evaluate(Expression node) {
    switch (node) {
      case SimpleIdentifier(:final element):
        if (_functions.containsKey(element) &&
            !_isAliasCopy(node) &&
            !_passingFunctions) {
          throw const _UnsupportedFlow();
        }
        return _state[element] ?? fallback(node);
      case FunctionExpression():
        if (!_isAliasCopy(node) && !_passingFunctions) {
          throw const _UnsupportedFlow();
        }
        return ReceiverOrigin.unknownValue;
      case ParenthesizedExpression(:final expression):
      case AsExpression(:final expression):
        return _expression(expression);
      case AssignmentExpression():
        return _assignment(node);
      case ConditionalExpression():
        return _conditional(node);
      case BinaryExpression():
        return _binary(node);
      case MethodInvocation():
        return _method(node);
      case InstanceCreationExpression(:final argumentList):
        _arguments(argumentList);
        return fallback(node);
      case AwaitExpression(:final expression):
        return _await(expression);
      case FunctionExpressionInvocation(:final function, :final argumentList):
        final local = _functionValue(function);
        if (local != null) return _invoke(local, argumentList, callSite: node);
        _expression(function);
        _arguments(argumentList);
        return fallback(node);
      case PropertyAccess(:final target):
        return _guarded(node, target, node.isNullAware, () => fallback(node));
      case PrefixedIdentifier(:final prefix):
        _expression(prefix);
        return fallback(node);
      case IsExpression(:final expression):
        _expression(expression);
        return ReceiverOrigin.unknownValue;
      case PrefixExpression(:final operand):
      case PostfixExpression(:final operand):
        return _update(node, operand);
      case IntegerLiteral() ||
          DoubleLiteral() ||
          BooleanLiteral() ||
          NullLiteral() ||
          SimpleStringLiteral() ||
          ThisExpression() ||
          SuperExpression():
        return fallback(node);
      default:
        throw const _UnsupportedFlow();
    }
  }

  ReceiverOrigin _conditional(ConditionalExpression node) {
    _expression(node.condition);
    var a = ReceiverOrigin.unknownValue;
    var b = ReceiverOrigin.unknownValue;
    _branches(
      () {
        a = _expression(node.thenExpression);
      },
      () {
        b = _expression(node.elseExpression);
      },
    );
    return _union(a, b);
  }

  ReceiverOrigin _binary(BinaryExpression node) {
    _expression(node.leftOperand);
    if (const {'&&', '||', '??'}.contains(node.operator.lexeme)) {
      _branches(() => _expression(node.rightOperand), () {});
    } else {
      _expression(node.rightOperand);
    }
    return fallback(node);
  }

  ReceiverOrigin _method(MethodInvocation node) {
    final target = node.target;
    final function = target == null
        ? _functions[node.methodName.element]
        : node.methodName.name == 'call'
        ? _functionValue(target)
        : null;
    if (function != null) {
      return _invoke(function, node.argumentList, callSite: node);
    }
    if (target == null &&
        node.argumentList.arguments.any(
          (argument) => _functionValue(_argumentExpression(argument)) != null,
        )) {
      final helper = lookupFunction(node.methodName.element);
      if (helper == null) throw const _UnsupportedFlow();
      return _invoke(helper, node.argumentList, callSite: node);
    }
    if (target == null && node.methodName.element is LocalFunctionElement) {
      throw const _UnsupportedFlow();
    }
    return _guarded(node, target, node.isNullAware, () {
      _arguments(node.argumentList);
      return fallback(node);
    });
  }

  // Null shortening covers the rest of an unparenthesized selector chain,
  // including arguments and setter RHSs, not only the node carrying `?.`.
  ReceiverOrigin _guarded(
    Expression node,
    Expression? target,
    bool nullAware,
    ReceiverOrigin Function() evaluate,
  ) {
    if (target != null) _expression(target);
    final inherited = _shortening[target] ?? _Evaluation.always;
    var evaluation = inherited;
    if (nullAware && inherited != _Evaluation.never) {
      final guard = _nullEvaluation(target);
      if (guard == _Evaluation.never || inherited == _Evaluation.always) {
        evaluation = guard;
      }
    }
    _shortening[node] = evaluation;
    return _optional(evaluation, evaluate);
  }

  _Evaluation _nullEvaluation(Expression? target) {
    final constant = _constant(target);
    if (constant == _NullValue.instance) return _Evaluation.never;
    if (constant != null) return _Evaluation.always;
    final type = target?.staticType;
    if ((type is InterfaceType || type is FunctionType) &&
        type!.nullabilitySuffix == NullabilitySuffix.none &&
        !type.isDartCoreNull &&
        !type.isDartAsyncFutureOr) {
      return _Evaluation.always;
    }
    return _Evaluation.maybe;
  }

  ReceiverOrigin _optional(
    _Evaluation evaluation,
    ReceiverOrigin Function() evaluate,
  ) {
    if (evaluation == _Evaluation.never) return ReceiverOrigin.unknownValue;
    if (evaluation == _Evaluation.always) return evaluate();
    var value = ReceiverOrigin.unknownValue;
    _branches(() => value = evaluate(), () {});
    return _union(value, ReceiverOrigin.unknownValue);
  }

  ReceiverOrigin _update(Expression node, Expression operand) {
    final value = _expression(operand);
    final operator = switch (node) {
      PostfixExpression(:final operator) => operator.lexeme,
      PrefixExpression(:final operator) => operator.lexeme,
      _ => null,
    };
    if (node is PostfixExpression && operator == '!') return value;
    if (const {'++', '--'}.contains(operator)) {
      _write(operand, ReceiverOrigin.unknownValue);
    }
    return ReceiverOrigin.unknownValue;
  }

  ReceiverOrigin _assignment(AssignmentExpression node) {
    if (node.operator.lexeme == '??=') throw const _UnsupportedFlow();
    _expression(node.leftHandSide);
    return _optional(_shortening[node.leftHandSide] ?? _Evaluation.always, () {
      final function = _functionValue(node.rightHandSide);
      final constant = _constant(node.rightHandSide);
      final right = _expression(node.rightHandSide);
      final future = _futureValue(node.rightHandSide);
      final value = node.operator.lexeme == '='
          ? right
          : ReceiverOrigin.unknownValue;
      _write(node.leftHandSide, value);
      if (node.operator.lexeme == '=') {
        _copyMetadata(node.leftHandSide, function, constant);
        if (node.leftHandSide case SimpleIdentifier(
          :final element,
        ) when future != null) {
          if (element is LocalVariableElement ||
              element is FormalParameterElement) {
            _futures[element!] = future;
          }
        }
      }
      return value;
    });
  }

  void _copyMetadata(
    Expression target,
    FunctionExpression? function,
    Object? constant,
  ) {
    if (target case SimpleIdentifier(:final element)
        when element is LocalVariableElement ||
            element is FormalParameterElement) {
      if (function != null) _functions[element!] = function;
      if (constant != null) _constants[element!] = constant;
    }
  }

  void _write(Expression target, ReceiverOrigin value) {
    if (target case SimpleIdentifier(:final element)) {
      if (element is LocalVariableElement ||
          element is FormalParameterElement) {
        if (_escaping != null && !_calleeLocal(element!, _escaping!)) {
          throw const _UnsupportedFlow();
        }
        _state[element!] = value;
        _constants.remove(element);
        _functions.remove(element);
        _futures.remove(element);
      }
    }
  }

  void _arguments(ArgumentList arguments) {
    final before = _passingFunctions;
    _passingFunctions = false;
    try {
      for (final argument in arguments.arguments) {
        _expression(_argumentExpression(argument));
      }
    } finally {
      _passingFunctions = before;
    }
  }

  Expression _argumentExpression(AstNode argument) {
    final named = argument.beginToken.next?.lexeme == ':';
    final expression = argument is Expression && !named
        ? argument
        : argument.childEntities.whereType<Expression>().lastOrNull;
    if (expression == null) throw const _UnsupportedFlow();
    return expression;
  }

  void _branches(void Function() first, void Function() second) {
    if (_pending.isNotEmpty) throw const _UnsupportedFlow();
    _step(
      _state.length * 3 +
          _constants.length * 3 +
          _functions.length * 3 +
          _futures.length,
    );
    final futuresBefore = Map.of(_futures);
    final before = Map<Element, ReceiverOrigin>.of(_state);
    final constantsBefore = Map<Element, Object>.of(_constants);
    final functionsBefore = Map<Element, FunctionExpression>.of(_functions);
    try {
      first();
    } on _ReturnFlow {
      throw const _UnsupportedFlow();
    } on _ContinueFlow {
      // A conditional transfer needs separate loop-exit states.
      throw const _UnsupportedFlow();
    }
    _checkBranchFutures(futuresBefore);
    final afterFirst = _state;
    final constantsFirst = _constants;
    final functionsFirst = _functions;
    _state = Map.of(before);
    _constants = Map.of(constantsBefore);
    _functions = Map.of(functionsBefore);
    _futures
      ..clear()
      ..addAll(futuresBefore);
    try {
      second();
    } on _ReturnFlow {
      throw const _UnsupportedFlow();
    } on _ContinueFlow {
      throw const _UnsupportedFlow();
    }
    _checkBranchFutures(futuresBefore);
    _state = _join(afterFirst, _state);
    if (functionsFirst.length != _functions.length ||
        functionsFirst.entries.any((e) => _functions[e.key] != e.value)) {
      throw const _UnsupportedFlow();
    }
    _constants = {
      for (final entry in constantsFirst.entries)
        if (_constants[entry.key] == entry.value) entry.key: entry.value,
    };
  }

  void _checkBranchFutures(Map<Element, _ReceiverTask> before) {
    if (_pending.isNotEmpty ||
        _futures.length != before.length ||
        _futures.entries.any((e) => before[e.key] != e.value)) {
      throw const _UnsupportedFlow();
    }
  }

  Map<Element, ReceiverOrigin> _join(
    Map<Element, ReceiverOrigin> first,
    Map<Element, ReceiverOrigin> second,
  ) {
    _step(first.length + second.length);
    return {
      for (final key in {...first.keys, ...second.keys})
        key: _union(
          first[key] ?? ReceiverOrigin.unknownValue,
          second[key] ?? ReceiverOrigin.unknownValue,
        ),
    };
  }

  void _variables(VariableDeclarationList variables) {
    if (variables.isLate) throw const _UnsupportedFlow();
    for (final variable in variables.variables) {
      final function = _functionValue(variable.initializer);
      final constant = _constant(variable.initializer);
      final value = variable.initializer == null
          ? ReceiverOrigin.unknownValue
          : _expression(variable.initializer!);
      final element = variable.declaredFragment?.element;
      if (element != null) {
        _state[element] = value;
        _futures.remove(element);
        final future = _futureValue(variable.initializer);
        if (future != null) _futures[element] = future;
        _functions.remove(element);
        if (function != null) _functions[element] = function;
        _constants.remove(element);
        if (constant != null) _constants[element] = constant;
      }
    }
  }

  void _for(ForStatement node) {
    final parts = node.forLoopParts;
    switch (parts) {
      case ForPartsWithDeclarations(:final variables):
        _variables(variables);
      case ForPartsWithExpression(:final initialization):
        if (initialization != null) _expression(initialization);
      default:
        throw const _UnsupportedFlow();
    }
    if (parts is! ForParts) throw const _UnsupportedFlow();
    _loop(node.body, parts.condition, parts.updaters);
  }

  void _loop(
    Statement body,
    Expression? condition,
    Iterable<Expression> updates, {
    bool atLeastOnce = false,
  }) {
    if (_pending.isNotEmpty) throw const _UnsupportedFlow();
    final functionsBefore = Map<Element, FunctionExpression>.of(_functions);
    Map<Element, ReceiverOrigin>? exits;
    if (!atLeastOnce) {
      final first = condition == null ? true : _constant(condition);
      if (condition != null) _expression(condition);
      if (first != true) exits = Map.of(_state);
      if (first == false) return;
    }
    _loopBody(body);
    _checkLoopFunctions(functionsBefore);
    _updates(updates);
    _recurrence(body, condition, updates, functionsBefore, exits);
  }

  void _recurrence(
    Statement body,
    Expression? condition,
    Iterable<Expression> updates,
    Map<Element, FunctionExpression> functionsBefore,
    Map<Element, ReceiverOrigin>? exits,
  ) {
    var header = Map<Element, ReceiverOrigin>.of(_state);
    // Recurrent integers can grow without bound; only receiver sets are kept.
    _constants.clear();
    for (var iteration = 0; iteration < 64; iteration++) {
      _state = Map.of(header);
      if (condition != null) _expression(condition);
      exits = exits == null ? Map.of(_state) : _join(exits, _state);
      _loopBody(body);
      _checkLoopFunctions(functionsBefore);
      _updates(updates);
      final next = _join(header, _state);
      if (_same(header, next)) {
        _state = exits;
        _constants.clear();
        return;
      }
      header = next;
      _constants.clear();
    }
    // Budget exhaustion discards all precision for the body, never a path.
    throw const _UnsupportedFlow();
  }

  void _loopBody(Statement body) {
    try {
      _statement(body);
    } on _ReturnFlow {
      throw const _UnsupportedFlow();
    } on _ContinueFlow {
      // The nearest loop owns an unlabelled continue. Updaters/condition still
      // run; statements after the continue do not.
    }
  }

  void _updates(Iterable<Expression> updates) {
    for (final update in updates) {
      _expression(update);
    }
  }

  void _checkLoopFunctions(Map<Element, FunctionExpression> before) {
    if (_pending.isNotEmpty) throw const _UnsupportedFlow();
    if (before.length != _functions.length ||
        before.entries.any((entry) => _functions[entry.key] != entry.value)) {
      throw const _UnsupportedFlow();
    }
  }

  bool _same(Map<Element, ReceiverOrigin> a, Map<Element, ReceiverOrigin> b) =>
      a.length == b.length &&
      a.entries.every((entry) {
        final other = b[entry.key];
        return other != null &&
            entry.value.unknown == other.unknown &&
            entry.value.types.length == other.types.length &&
            entry.value.types.containsAll(other.types) &&
            entry.value.references.length == other.references.length &&
            entry.value.references.containsAll(other.references);
      });

  Object? _constant(Expression? node) => switch (node) {
    NullLiteral() => _NullValue.instance,
    InstanceCreationExpression() => _NonNullValue.instance,
    IntegerLiteral(:final value) => value,
    BooleanLiteral(:final value) => value,
    SimpleIdentifier(:final element) => _constants[element],
    ParenthesizedExpression(:final expression) => _constant(expression),
    BinaryExpression() => _comparison(node),
    _ => null,
  };

  bool? _comparison(BinaryExpression node) {
    final a = _constant(node.leftOperand);
    final b = _constant(node.rightOperand);
    if (a is! int || b is! int) return null;
    return switch (node.operator.lexeme) {
      '<' => a < b,
      '<=' => a <= b,
      '>' => a > b,
      '>=' => a >= b,
      '==' => a == b,
      '!=' => a != b,
      _ => null,
    };
  }

  FunctionExpression? _functionValue(Expression? expression) =>
      switch (expression) {
        FunctionExpression() => expression,
        SimpleIdentifier(:final element) => _functions[element],
        ParenthesizedExpression(:final expression) => _functionValue(
          expression,
        ),
        _ => null,
      };

  bool _isAliasCopy(Expression expression) {
    AstNode child = expression;
    while (child.parent is ParenthesizedExpression) {
      child = child.parent!;
    }
    final parent = child.parent;
    if (parent is VariableDeclaration && parent.initializer == child) {
      return true;
    }
    if (parent is AssignmentExpression &&
        parent.operator.lexeme == '=' &&
        parent.rightHandSide == child &&
        parent.leftHandSide is SimpleIdentifier) {
      final target = (parent.leftHandSide as SimpleIdentifier).element;
      return target is LocalVariableElement || target is FormalParameterElement;
    }
    return false;
  }

  ReceiverOrigin _invoke(
    FunctionExpression function,
    ArgumentList? arguments, {
    Expression? callSite,
  }) {
    final body = function.body;
    if (body.isGenerator ||
        _activeCalls.length >= 16 ||
        ++_callCount > 256 ||
        !_activeCalls.add(function)) {
      throw const _UnsupportedFlow();
    }
    _bindArguments(function, arguments);
    final enclosingAsync = _asyncFrame;
    if (body.isAsynchronous) _asyncFrame = function;
    try {
      if (body.isAsynchronous) {
        if (_resuming || callSite == null) throw const _UnsupportedFlow();
        _futureExpressions[callSite] = _startTask(function);
      } else {
        switch (body) {
          case BlockFunctionBody(:final block):
            _statement(block);
          case ExpressionFunctionBody(:final expression):
            _expression(expression);
          default:
            throw const _UnsupportedFlow();
        }
      }
    } on _ReturnFlow {
      // The local invocation ended; the caller continues with capture writes.
    }
    _asyncFrame = enclosingAsync;
    _activeCalls.remove(function);
    _discardFrame(function);
    return ReceiverOrigin.unknownValue;
  }

  _ReceiverTask _startTask(FunctionExpression function) {
    final body = function.body;
    if (body is! BlockFunctionBody) throw const _UnsupportedFlow();
    final statements = body.block.statements;
    for (var index = 0; index < statements.length; index++) {
      final statement = statements[index];
      if (statement case ExpressionStatement(
        expression: AwaitExpression(:final expression),
      )) {
        // Only already-completed SDK futures have a known scheduling point.
        // Other IO, completers and callback schedulers fall back.
        if (!_immediateFuture(expression)) throw const _UnsupportedFlow();
        _expression(expression);
        final task = _ReceiverTask(
          function,
          statements,
          index + 1,
          _frameValues(_state, function),
          _frameValues(_constants, function),
          _frameValues(_functions, function),
        );
        _pending.add(task);
        return task;
      }
      _statement(statement);
    }
    return _ReceiverTask(function, const [], 0, const {}, const {}, const {});
  }

  Map<Element, T> _frameValues<T>(
    Map<Element, T> source,
    FunctionExpression function,
  ) {
    final keys = _frameKeys(function);
    _step(keys.length);
    return {
      for (final key in keys)
        if (source.containsKey(key)) key: source[key] as T,
    };
  }

  void _discardFrame(FunctionExpression function) {
    final keys = _frameKeys(function);
    _step(keys.length * 4);
    for (final key in keys) {
      _state.remove(key);
      _constants.remove(key);
      _functions.remove(key);
      _futures.remove(key);
    }
  }

  ReceiverOrigin _await(Expression expression) {
    if (_asyncFrame != null || _resuming) throw const _UnsupportedFlow();
    _expression(expression);
    if (_futureValue(expression) == null && !_immediateFuture(expression)) {
      throw const _UnsupportedFlow();
    }
    _drainTasks();
    return ReceiverOrigin.unknownValue;
  }

  bool _immediateFuture(Expression expression) {
    if (expression is! InstanceCreationExpression) return false;
    final constructor = expression.constructorName.element;
    if (constructor?.library.uri.toString() != 'dart:async' ||
        constructor?.enclosingElement.name != 'Future' ||
        constructor?.name != 'value') {
      return false;
    }
    final arguments = expression.argumentList.arguments;
    if (arguments.isEmpty) return true;
    if (arguments.length != 1) return false;
    return switch (_argumentExpression(arguments.single)) {
      NullLiteral() ||
      IntegerLiteral() ||
      DoubleLiteral() ||
      BooleanLiteral() ||
      SimpleStringLiteral() => true,
      _ => false,
    };
  }

  _ReceiverTask? _futureValue(Expression? expression) => switch (expression) {
    SimpleIdentifier(:final element) => _futures[element],
    ParenthesizedExpression(:final expression) => _futureValue(expression),
    _ => _futureExpressions[expression],
  };

  void _drainTasks() {
    if (_pending.isEmpty) return;
    if (_resuming) throw const _UnsupportedFlow();
    _resuming = true;
    for (final task in _pending) {
      _state.addAll(task.locals);
      _constants.addAll(task.constants);
      _functions.addAll(task.functions);
      _activeCalls.add(task.function);
      try {
        _block(task.statements.skip(task.resume));
      } on _ReturnFlow {
        // This task completed before the end of its block.
      }
      _activeCalls.remove(task.function);
      _discardFrame(task.function);
      task.release();
    }
    _pending.clear();
    _resuming = false;
  }

  void _bindArguments(FunctionExpression function, ArgumentList? arguments) {
    final parameters =
        function.parameters?.parameters
            .map((p) => p.declaredFragment?.element)
            .whereType<FormalParameterElement>()
            .toList() ??
        <FormalParameterElement>[];
    final positional = parameters.where((p) => p.isPositional).toList();
    final actuals =
        <FormalParameterElement, (ReceiverOrigin, FunctionExpression?)>{};
    var index = 0;
    final before = _passingFunctions;
    _passingFunctions = true;
    try {
      for (final argument in arguments?.arguments ?? <AstNode>[]) {
        final named = argument.beginToken.next?.lexeme == ':';
        final parameter = named
            ? parameters
                  .where((p) => p.name == argument.beginToken.lexeme)
                  .firstOrNull
            : index < positional.length
            ? positional[index++]
            : null;
        final expression = _argumentExpression(argument);
        final callback = _functionValue(expression);
        final value = _expression(expression);
        if (parameter != null) actuals[parameter] = (value, callback);
      }
    } finally {
      _passingFunctions = before;
    }
    for (final parameter in parameters) {
      final actual = actuals[parameter];
      _state[parameter] = actual?.$1 ?? ReceiverOrigin.unknownValue;
      _functions.remove(parameter);
      if (actual?.$2 case final callback?) _functions[parameter] = callback;
      _constants.remove(parameter);
    }
  }

  Set<Element> _frameKeys(FunctionExpression function) =>
      _frames.putIfAbsent(function, () {
        final collector = _FrameElements();
        function.accept(collector);
        _step(collector.visited);
        return collector.keys;
      });

  bool _calleeLocal(Element element, FunctionExpression function) =>
      _frameKeys(function).contains(element);

  bool _inFamily(AstNode node) {
    for (AstNode? current = node; current != null; current = current.parent) {
      if (identical(current, _declaration)) return true;
    }
    return false;
  }

  void _step([int cost = 1]) {
    // Shared by AST traversal, state copies, nested loops and callbacks.
    _steps += cost;
    if (_steps > 10000) throw const _UnsupportedFlow();
  }

  ReceiverOrigin _union(ReceiverOrigin a, ReceiverOrigin b) {
    _step(
      a.types.length +
          b.types.length +
          a.references.length +
          b.references.length,
    );
    return ReceiverOrigin(
      types: {...a.types, ...b.types},
      references: {...a.references, ...b.references},
      unknown: a.unknown || b.unknown,
    );
  }
}

class _UnsupportedFlow implements Exception {
  const _UnsupportedFlow();
}

enum _Evaluation { always, maybe, never }

enum _NullValue { instance }

enum _NonNullValue { instance }

class _ContinueFlow implements Exception {
  const _ContinueFlow();
}

class _ReturnFlow implements Exception {
  const _ReturnFlow();
}

class _ReceiverTask {
  final FunctionExpression function;
  List<Statement> statements;
  final int resume;
  final Map<Element, ReceiverOrigin> locals;
  final Map<Element, Object> constants;
  final Map<Element, FunctionExpression> functions;
  _ReceiverTask(
    this.function,
    this.statements,
    this.resume,
    this.locals,
    this.constants,
    this.functions,
  );

  void release() {
    statements = const [];
    locals.clear();
    constants.clear();
    functions.clear();
  }
}

/// Resolved declarations owned by an invocation, excluding outer captures.
/// Index once so empty helpers do not rescan all unrelated caller variables.
class _FrameElements extends GeneralizingAstVisitor<void> {
  final Set<Element> keys = {};
  int visited = 0;

  @override
  void visitNode(AstNode node) {
    visited++;
    final element = switch (node) {
      VariableDeclaration() => node.declaredFragment?.element,
      FunctionDeclaration() => node.declaredFragment?.element,
      FormalParameter() => node.declaredFragment?.element,
      _ => null,
    };
    if (element is LocalVariableElement ||
        element is FormalParameterElement ||
        element is LocalFunctionElement) {
      keys.add(element!);
    }
    super.visitNode(node);
  }
}
