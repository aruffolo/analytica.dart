import 'package:analyzer/dart/element/element.dart';

/// A bounded, flow-insensitive origin: concrete allocations, value references,
/// or an explicit unknown. Each reachability run owns the resolved bindings.
class ReceiverOrigin {
  final Set<InterfaceElement> types;
  final Set<ConstructorElement> constructors;
  final Set<String> references;
  final bool unknown;
  const ReceiverOrigin({
    this.types = const {},
    this.constructors = const {},
    this.references = const {},
    this.unknown = false,
  });
  static const unknownValue = ReceiverOrigin(unknown: true);
}

class CallArgument {
  final String? name;
  final ReceiverOrigin value;
  const CallArgument(this.name, this.value);
}

class ConstructorCall {
  final ReceiverOrigin target;
  final List<CallArgument> arguments;
  const ConstructorCall(this.target, this.arguments);
}

class ReceiverBindings {
  final Map<String, Set<ReceiverOrigin>> _values = {};
  final Map<ReceiverOrigin, ReceiverOrigin> _resolved = {};
  int revision = 0;

  void add(String key, ReceiverOrigin value) {
    if (_values.putIfAbsent(key, () => {}).add(value)) {
      revision++;
      _resolved.clear();
    }
  }

  ReceiverOrigin resolve(ReceiverOrigin origin) =>
      _resolved.putIfAbsent(origin, () => _resolve(origin));

  ReceiverOrigin _resolve(ReceiverOrigin origin) {
    final types = <InterfaceElement>{};
    final constructors = <ConstructorElement>{};
    final visited = <String>{};
    final pending = <ReceiverOrigin>[origin];
    var unknown = false;
    while (pending.isNotEmpty) {
      final value = pending.removeLast();
      types.addAll(value.types);
      constructors.addAll(value.constructors);
      unknown |= value.unknown;
      for (final key in value.references) {
        if (!visited.add(key)) continue;
        final bindings = _values[key];
        if (bindings == null) {
          unknown = true;
        } else {
          pending.addAll(bindings);
        }
      }
    }
    return ReceiverOrigin(
      types: types,
      constructors: constructors,
      references: visited,
      unknown: unknown || (types.isEmpty && constructors.isEmpty),
    );
  }
}

Map<FormalParameterElement, ReceiverOrigin> callBindings(
  ExecutableElement target,
  List<CallArgument> arguments, {
  Map<Element, ReceiverOrigin> forwarded = const {},
}) {
  final result = <FormalParameterElement, ReceiverOrigin>{};
  final positional = target.formalParameters
      .where((p) => p.isPositional)
      .toList();
  var index = 0;
  for (final argument in arguments) {
    final parameter = argument.name == null
        ? (index < positional.length ? positional[index++] : null)
        : target.formalParameters
              .where((p) => p.name == argument.name)
              .firstOrNull;
    if (parameter != null) result[parameter] = argument.value;
  }
  // Omitted defaults and escaped tear-offs have no modeled actual value.
  // An earlier supplied argument must not narrow those other invocations.
  for (final parameter in target.formalParameters) {
    result.putIfAbsent(
      parameter,
      () => forwarded[parameter.baseElement] ?? ReceiverOrigin.unknownValue,
    );
  }
  return result;
}
