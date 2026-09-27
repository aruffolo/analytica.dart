import 'flow.dart';
import 'graph.dart';

/// Tracks conservative retention separately from ordinary unreachable findings.
class AssumptionTrace {
  final Map<String, Set<String>> _seeds = {};
  final Map<DispatchSlot, Set<String>> _targets = {};
  final Map<String, Set<DispatchSlot>> _indirect = {};

  void retain(String key, String reason) =>
      _seeds.putIfAbsent(key, () => {}).add(reason);

  void dispatch(DispatchSlot slot, String key) =>
      _targets.putIfAbsent(slot, () => {}).add(key);

  void indirect(String key, DispatchSlot slot) =>
      _indirect.putIfAbsent(key, () => {}).add(slot);

  void _connectReturns(ReceiverBindings bindings) {
    // Follow final value dependencies too: a call in an explicit body can
    // consume a receiver returned only by an assumption-retained method.
    for (final slot in _targets.keys) {
      final origin = bindings.resolve(
        slot.receiver ?? ReceiverOrigin.unknownValue,
      );
      for (final reference in origin.references) {
        if (reference.startsWith('return#')) {
          indirect(reference.substring('return#'.length), slot);
        }
      }
    }
  }

  Map<String, Set<String>> reasons(
    MemberGraph graph,
    Set<String> live,
    ReceiverBindings bindings,
  ) {
    _connectReturns(bindings);
    final result = <String, Set<String>>{};
    final pending = <(String, String)>[
      for (final entry in _seeds.entries)
        for (final reason in entry.value) (entry.key, reason),
    ];
    while (pending.isNotEmpty) {
      final (key, reason) = pending.removeLast();
      if (!live.contains(key) ||
          !result.putIfAbsent(key, () => {}).add(reason)) {
        continue;
      }
      final edges = graph.nodes[key]!.edges;
      final targets = {
        ...edges.direct,
        for (final constructor in edges.constructions) ...[
          elementKey(constructor),
          elementKey(constructor.enclosingElement),
        ],
        for (final slot in {...edges.slots, ...?_indirect[key]})
          ...?_targets[slot],
      };
      pending.addAll(targets.map((target) => (target, reason)));
    }
    return result;
  }
}
