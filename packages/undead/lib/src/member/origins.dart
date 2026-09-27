import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

import 'flow.dart';
import 'graph.dart';
import 'receiver_values.dart';

/// Collects value-flow equations, without mixing production and test state.
class ReceiverOrigins {
  final MemberGraph graph;
  final MemberEdges edges;
  final Element? source;
  ReceiverOrigins(this.graph, this.edges, this.source);

  ReceiverOrigin get implicitReceiver => source == null
      ? ReceiverOrigin.unknownValue
      : ReceiverOrigin(references: {'this#${elementKey(source!)}'});

  Map<Expression, ReceiverOrigin> collectValues() =>
      ReceiverValues(_legacyValue, (element) {
        if (element is! TopLevelFunctionElement) return null;
        final ast = graph.nodes[elementKey(element)]?.ast;
        return ast is FunctionDeclaration ? ast.functionExpression : null;
      }).analyze(source == null ? null : graph.nodes[elementKey(source!)]?.ast);

  ReceiverOrigin value(Expression? expression) => expression == null
      ? ReceiverOrigin.unknownValue
      : graph.receiverValues[expression] ?? _legacyValue(expression);

  ReceiverOrigin _legacyValue(Expression expression) => switch (expression) {
    InstanceCreationExpression(:final constructorName)
        when constructorName.element?.isFactory == false =>
      ReceiverOrigin(types: {constructorName.element!.enclosingElement}),
    ConstructorReference(:final constructorName)
        when constructorName.element != null =>
      ReceiverOrigin(constructors: {constructorName.element!}),
    SimpleIdentifier(:final element) => _elementValue(element, expression),
    PrefixedIdentifier(:final element) => _elementValue(element, expression),
    PropertyAccess(:final propertyName) => _elementValue(
      propertyName.element,
      expression,
    ),
    ParenthesizedExpression(:final expression) => _legacyValue(expression),
    AsExpression(:final expression) => _legacyValue(expression),
    ThisExpression() || SuperExpression() => implicitReceiver,
    ConditionalExpression(:final thenExpression, :final elseExpression) =>
      _union(_legacyValue(thenExpression), _legacyValue(elseExpression)),
    MethodInvocation(:final methodName) => _returnValue(
      methodName.element,
      expression,
    ),
    FunctionExpressionInvocation(:final element) => _returnValue(
      element,
      expression,
    ),
    _ => ReceiverOrigin.unknownValue,
  };

  ReceiverOrigin _elementValue(Element? element, Expression expression) {
    if (element is PropertyAccessorElement) {
      return element.isOriginVariable
          ? _elementValue(element.variable, expression)
          : _returnValue(element, expression);
    }
    if (element is VariableElement) {
      return ReceiverOrigin(references: {elementKey(element)});
    }
    return ReceiverOrigin.unknownValue;
  }

  ReceiverOrigin _returnValue(Element? element, [Expression? expression]) {
    if (expression != null &&
        element is ExecutableElement &&
        !element.isStatic &&
        element.enclosingElement is InterfaceElement &&
        element.enclosingElement is! ExtensionTypeElement &&
        !_isDirectSuper(expression)) {
      return ReceiverOrigin(references: {graph.resultKey(expression)});
    }
    return element == null
        ? ReceiverOrigin.unknownValue
        : ReceiverOrigin(references: {'return#${elementKey(element)}'});
  }

  bool _isDirectSuper(Expression expression) {
    if (source?.enclosingElement is MixinElement) return false;
    return (expression is MethodInvocation &&
            expression.realTarget is SuperExpression) ||
        (expression is PropertyAccess &&
            expression.realTarget is SuperExpression);
  }

  ReceiverOrigin _union(ReceiverOrigin a, ReceiverOrigin b) => ReceiverOrigin(
    types: {...a.types, ...b.types},
    constructors: {...a.constructors, ...b.constructors},
    references: {...a.references, ...b.references},
    unknown: a.unknown || b.unknown,
  );

  List<CallArgument> arguments(ArgumentList arguments) => [
    for (final argument in arguments.arguments) _argument(argument),
  ];

  CallArgument _argument(AstNode argument) {
    // Analyzer 12 represents arguments as expressions; 14 wraps them in
    // Argument nodes. Tokens and child expressions work across both APIs.
    final named = argument.beginToken.next?.lexeme == ':';
    final expression = argumentExpression(argument);
    return CallArgument(
      named ? argument.beginToken.lexeme : null,
      value(expression),
    );
  }

  static Expression? argumentExpression(AstNode argument) {
    final named = argument.beginToken.next?.lexeme == ':';
    return argument is Expression && !named
        ? argument
        : argument.childEntities.whereType<Expression>().lastOrNull;
  }

  void bindCall(
    Element? target,
    List<CallArgument> arguments, {
    bool forwardSuperParameters = false,
  }) {
    if (target is! ExecutableElement) return;
    final forwarded = forwardSuperParameters
        ? _superParameters()
        : const <Element, ReceiverOrigin>{};
    for (final entry in callBindings(
      target,
      arguments,
      forwarded: forwarded,
    ).entries) {
      edges.bind(elementKey(entry.key), entry.value);
    }
  }

  Map<Element, ReceiverOrigin> _superParameters() {
    final constructor = source;
    if (constructor is! ConstructorElement) return const {};
    return {
      for (final parameter
          in constructor.formalParameters
              .whereType<SuperFormalParameterElement>())
        if (parameter.superConstructorParameter case final parent?)
          parent.baseElement: ReceiverOrigin(
            references: {elementKey(parameter)},
          ),
    };
  }

  void variable(VariableDeclaration node) {
    final element = node.declaredFragment?.element;
    if (element == null || node.initializer == null) return;
    // Heap/global storage may be written through aliases or native code. Only
    // lexical locals are narrowed until those writes are modeled completely.
    edges.bind(
      elementKey(element),
      element is LocalVariableElement
          ? value(node.initializer)
          : ReceiverOrigin.unknownValue,
    );
  }

  void assignment(AssignmentExpression node) => _write(
    node.leftHandSide,
    node.operator.lexeme == '='
        ? value(node.rightHandSide)
        : ReceiverOrigin.unknownValue,
  );

  void update(Expression operand) =>
      _write(operand, ReceiverOrigin.unknownValue);

  void invalidate(Element? target) =>
      _bindWrite(target, ReceiverOrigin.unknownValue);

  void _write(Expression target, ReceiverOrigin origin) {
    final element = switch (target) {
      SimpleIdentifier(:final element) => element,
      PrefixedIdentifier(:final element) => element,
      PropertyAccess(:final propertyName) => propertyName.element,
      _ => null,
    };
    _bindWrite(element, origin);
  }

  void _bindWrite(Element? element, ReceiverOrigin origin) {
    if (element is LocalVariableElement || element is FormalParameterElement) {
      edges.bind(elementKey(element!), origin);
    }
  }

  void returned(Expression? expression, AstNode node) {
    if (source == null) return;
    final declaration = graph.nodes[elementKey(source!)]?.ast;
    final body = switch (declaration) {
      FunctionDeclaration(:final functionExpression) => functionExpression.body,
      MethodDeclaration(:final body) => body,
      _ => null,
    };
    // A closure nested in a function does not return from that function.
    if (node.thisOrAncestorOfType<FunctionBody>() != body) return;
    edges.bind('return#${elementKey(source!)}', value(expression));
  }
}
