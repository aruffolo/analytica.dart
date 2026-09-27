import 'package:test/test.dart';

import 'support/member_fixture.dart';

void main() {
  _foreignArgumentTests();

  test('external root parameters remain open to external callers', () async {
    final report = await memberFixture('''
abstract class Action { void run(); }
class A implements Action { void run() { aEffect(); } }
class B implements Action { void run() { bEffect(); } }
class Spare { void run() { deadEffect(); } }
void aEffect() {}
void bEffect() {}
void deadEffect() {}
@pragma('vm:entry-point')
void enter(Action value) { value.run(); }
void main() { enter(A()); B(); Spare(); }
''');
    expect(findingNames(report), {'Spare.run', 'deadEffect'});
  });

  test('class roots allocate receivers for inherited calls', () async {
    final report = await memberFixture('''
class Base {
  void inherited() { liveEffect(); }
  void unused() { deadEffect(); }
}
@pragma('vm:entry-point')
class Child extends Base {
  Child();
  void enter() { inherited(); }
}
void liveEffect() {}
void deadEffect() {}
void main() {}
''');
    expect(findingNames(report), {'Base.unused', 'deadEffect'});
  });

  for (final boundary in ['protocol', 'escape']) {
    test(
      '$boundary retention binds inherited implementation receivers',
      () async {
        final entry = boundary == 'protocol'
            ? 'Base().toString(); print(Child());'
            : 'Base().invoke(); register(Child());';
        final protocol = boundary == 'protocol'
            ? "@override String toString() { _hook(); return ''; }"
            : '';
        final report = await memberFixture('''
external void register(dynamic value);
class Base {
  $protocol
  void invoke() { _hook(); }
  void _hook() { baseEffect(); }
}
class Child extends Base { @override void _hook() { childEffect(); } }
class Spare { void unused() { deadEffect(); } }
void baseEffect() {}
void childEffect() {}
void deadEffect() {}
void main() { Spare(); $entry }
''');
        expect(
          findingNames(report),
          containsAll(['Spare.unused', 'deadEffect']),
        );
        expect(findingNames(report), isNot(contains('childEffect')));
      },
    );
  }

  test(
    'reachable tear-offs preserve dependencies; dead closures do not',
    () async {
      final report = await memberFixture('''
void register(void Function() callback) { callback(); }
void main() { register(Service().callback); }
class Service {
  void callback() { liveEffect(); }
  void dead() { register(() { hiddenEffect(); }); }
}
void liveEffect() {}
void hiddenEffect() {}
''');
      expect(
        findingNames(report),
        containsAll(['Service.dead', 'hiddenEffect']),
      );
      expect(
        findingNames(report).intersection({'Service.callback', 'liveEffect'}),
        isEmpty,
      );
    },
  );

  test(
    'member entrypoint on an otherwise unreferenced owner is live',
    () async {
      final report = await memberFixture('''
void main() {}
class NativeBridge {
  @pragma('vm:entry-point')
  static void enter() { callbackEffect(); }
  static void unused() { deadEffect(); }
}
void callbackEffect() {}
void deadEffect() {}
''');
      expect(
        findingNames(report),
        containsAll(['NativeBridge.unused', 'deadEffect']),
      );
      expect(
        findingNames(report).intersection({
          'NativeBridge',
          'NativeBridge.enter',
          'callbackEffect',
        }),
        isEmpty,
      );
    },
  );

  test(
    'dynamic selectors retain compatible allocated owners with disclosure',
    () async {
      final report = await memberFixture('''
void main() { dynamic value = Service(); value.run(); }
class Service { void run() { effect(); } void unused() {} }
class Unallocated { void run() {} }
void effect() {}
''');
      expect(
        findingNames(report),
        containsAll(['Service.unused', 'Unallocated']),
      );
      expect(
        findingNames(report).intersection({'Service.run', 'effect'}),
        isEmpty,
      );
      expect(
        report.coverageLimitations.map((l) => l.code),
        contains('dynamicDispatch'),
      );
    },
  );

  test(
    'external protocol overrides retained only for instantiated owners',
    () async {
      final report = await memberFixture('''
void main() { print(Service()); }
class Service {
  @override String toString() { effect(); return ''; }
  void unused() {}
}
class Dormant { @override String toString() { hidden(); return ''; } }
void effect() {}
void hidden() {}
''');
      expect(
        findingNames(report),
        containsAll(['Service.unused', 'Dormant', 'hidden']),
      );
      expect(
        findingNames(report).intersection({'Service.toString', 'effect'}),
        isEmpty,
      );
    },
  );

  test('excluded generated part contributes dependency edges', () async {
    final report = await memberFixture(
      '''
part 'generated.g.dart';
void main() { generated(); }
void effect() {}
void unused() {}
''',
      files: {
        'generated.g.dart':
            "part of 'main.dart'; void generated() { effect(); }",
      },
    );
    expect(findingNames(report), contains('unused'));
    expect(findingNames(report), isNot(contains('effect')));
    expect(report.undead.where((f) => f.file.endsWith('.g.dart')), isEmpty);
  });

  test('resolution errors are visible in the report', () async {
    final report = await memberFixture('''
void main() { Missing().unknown(); }
void unused() {}
''');
    expect(
      report.coverageLimitations.map((l) => l.code),
      contains('resolutionError'),
    );
  });
  test('dynamic getter and setter access preserve bodies', () async {
    final report = await memberFixture('''
void main() { dynamic value = Value(); print(value.data); value.data = 2; }
class Value {
  int get data { readEffect(); return 1; }
  set data(int value) { writeEffect(); }
  void unused() {}
}
void readEffect() {}
void writeEffect() {}
''');
    expect(findingNames(report), {'Value.unused'});
  });

  test('foreign object exposure retains compatible receiver surface', () async {
    final report = await memberFixture('''
external void register(Service value);
void main() { register(Service()); }
class Service { void callback() { callbackEffect(); } }
class Other { void callback() { deadEffect(); } }
void callbackEffect() {}
void deadEffect() {}
''');
    expect(findingNames(report), containsAll(['Other', 'deadEffect']));
    expect(
      findingNames(
        report,
      ).intersection({'Service', 'Service.callback', 'callbackEffect'}),
      isEmpty,
    );
    expect(
      report.coverageLimitations.map((l) => l.code),
      contains('externalEscape'),
    );
  });
  test('callable objects retain call bodies and dependencies', () async {
    final report = await memberFixture('''
void main() { Service()(); }
class Service {
  void call() { helper(); }
  void helper() {}
  void unused() {}
}
''');
    expect(findingNames(report), {'Service.unused'});
  });

  test('dynamic index reads and writes retain operator bodies', () async {
    final report = await memberFixture('''
void main() { dynamic value = Indexed(); print(value[0]); value[0] = 2; }
class Indexed {
  int operator [](int index) { readEffect(); return 1; }
  void operator []=(int index, int value) { writeEffect(); }
  void unused() {}
}
void readEffect() {}
void writeEffect() {}
''');
    expect(findingNames(report), {'Indexed.unused'});
  });
  test(
    'implicit callable tear-offs and dynamic calls preserve targets',
    () async {
      final report = await memberFixture('''
void accept(void Function() callback) { callback(); }
void main() { accept(Callable()); dynamic other = DynamicCallable(); other(); }
class Callable { void call() { implicitEffect(); } void unused() {} }
class DynamicCallable { void call() { dynamicEffect(); } void unused() {} }
void implicitEffect() {}
void dynamicEffect() {}
''');
      expect(findingNames(report), {
        'Callable.unused',
        'DynamicCallable.unused',
      });
    },
  );
  test('dynamic operators retain their invoked bodies', () async {
    final report = await memberFixture('''
void main() { dynamic value = Meter(); value + 1; -value; value += 1; }
class Meter {
  Meter operator +(int other) { addEffect(); return this; }
  Meter operator -() { negateEffect(); return this; }
  Meter operator -(int other) { hiddenEffect(); return this; }
  void unused() {}
}
void addEffect() {}
void negateEffect() {}
void hiddenEffect() {}
''');
    expect(findingNames(report), {'Meter.unused', 'Meter.-', 'hiddenEffect'});
  });
}

void _foreignArgumentTests() {
  for (final (named, dynamicValue) in [
    (false, false),
    (true, false),
    (false, true),
    (true, true),
  ]) {
    test(
      'foreign named=$named dynamic=$dynamicValue preserves dead methods',
      () async {
        final report = await memberFixture(_foreignSource(named, dynamicValue));
        const dead = {'Other.callback', 'deadEffect'};
        expect(findingNames(report), dynamicValue ? containsAll(dead) : dead);
        if (!dynamicValue) {
          expect(
            report.coverageLimitations.map((l) => l.code),
            contains('externalEscape'),
          );
        }
      },
    );
  }
}

String _foreignSource(bool named, bool dynamicValue) {
  final parameter = named ? '{required dynamic value}' : 'dynamic value';
  final argument = named ? 'value: value' : 'value';
  final type = dynamicValue ? 'dynamic' : 'Service';
  final inheritance = dynamicValue ? 'extends Service' : '';
  return '''
external void register($parameter);
void main() { $type value = Service(); Other(); register($argument); }
class Service { void callback() { callbackEffect(); } }
class Other $inheritance { void callback() { deadEffect(); } }
void callbackEffect() {}
void deadEffect() {}
''';
}
