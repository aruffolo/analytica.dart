import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

import 'flow.dart';
import 'graph.dart';

/// Collects value-flow equations, without mixing production and test state.
class ReceiverOrigins {
  final MemberGraph graph;
  final MemberEdges edges;
  final Element? source;
  ReceiverOrigins(this.graph, this.edges, this.source);

  ReceiverOrigin get implicitReceiver => source == null
      ? ReceiverOrigin.unknownValue
      : ReceiverOrigin(references: {'this#${elementKey(source!)}'});

  ReceiverOrigin value(Expression? expression) => switch (expression) {
    InstanceCreationExpression(:final constructorName)
        when constructorName.element?.isFactory == false =>
      ReceiverOrigin(types: {constructorName.element!.enclosingElement}),
    SimpleIdentifier(:final element) => _elementValue(element),
    PrefixedIdentifier(:final element) => _elementValue(element),
    PropertyAccess(:final propertyName) => _elementValue(propertyName.element),
    ParenthesizedExpression(:final expression) => value(expression),
    AsExpression(:final expression) => value(expression),
    ThisExpression() || SuperExpression() => implicitReceiver,
    ConditionalExpression(:final thenExpression, :final elseExpression) =>
      _union(value(thenExpression), value(elseExpression)),
    MethodInvocation(:final methodName) => _returnValue(methodName.element),
    FunctionExpressionInvocation(:final element) => _returnValue(element),
    _ => ReceiverOrigin.unknownValue,
  };

  ReceiverOrigin _elementValue(Element? element) {
    if (element is PropertyAccessorElement) {
      return element.isOriginVariable
          ? _elementValue(element.variable)
          : _returnValue(element);
    }
    if (element is VariableElement) {
      return ReceiverOrigin(references: {elementKey(element)});
    }
    return ReceiverOrigin.unknownValue;
  }

  ReceiverOrigin _returnValue(Element? element) => element == null
      ? ReceiverOrigin.unknownValue
      : ReceiverOrigin(references: {'return#${elementKey(element)}'});

  ReceiverOrigin _union(ReceiverOrigin a, ReceiverOrigin b) => ReceiverOrigin(
    types: {...a.types, ...b.types},
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
    final expression = argument is Expression && !named
        ? argument
        : argument.childEntities.whereType<Expression>().lastOrNull;
    return CallArgument(
      named ? argument.beginToken.lexeme : null,
      value(expression),
    );
  }

  void bindCall(Element? target, List<CallArgument> arguments) {
    if (target is! ExecutableElement) return;
    for (final entry in callBindings(target, arguments).entries) {
      edges.bind(elementKey(entry.key), entry.value);
    }
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
