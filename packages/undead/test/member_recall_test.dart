import 'package:test/test.dart';
import 'package:undead/undead.dart';

import 'support/member_fixture.dart';

const _receivers = '''
abstract interface class Port { void send(); }
class Active implements Port { void send() { activeEffect(); } }
class Passive implements Port {
  void send() { hiddenEffect(); }
  void close() {}
}
void activeEffect() {}
void hiddenEffect() {}
''';

void main() {
  test('uncalled local function does not activate its body', () async {
    final report = await memberFixture('''
void main() {
  void abandoned() { Service().run(); }
  Service().ping();
}
class Service { void run() { hiddenEffect(); } void ping() {} }
void hiddenEffect() {}
''');
    expect(findingNames(report), {'Service.run', 'hiddenEffect'});
  });

  test('called locals and escaped callbacks preserve their bodies', () async {
    final report = await memberFixture('''
void invoke(void Function() callback) { callback(); }
void main() {
  void direct() { directEffect(); }
  void callback() { callbackEffect(); }
  void recursive(int count) { recursiveEffect(); if (count > 0) recursive(count - 1); }
  direct();
  final alias = callback;
  invoke(alias);
  recursive(1);
}
void directEffect() {}
void callbackEffect() {}
void recursiveEffect() {}
''');
    expect(findingNames(report), isEmpty);
  });

  test('local names are scoped by their enclosing declaration', () async {
    final report = await memberFixture('''
void main() { first(); second(); }
void first() { void same() { liveEffect(); } same(); }
void second() { void same() { hiddenEffect(); } }
void liveEffect() {}
void hiddenEffect() {}
''');
    expect(findingNames(report), {'hiddenEffect'});
  });

  test('an uncalled local recursion cycle does not become a root', () async {
    final report = await memberFixture('''
void main() {
  void recurse() { hiddenEffect(); recurse(); }
}
void hiddenEffect() {}
''');
    expect(findingNames(report), {'hiddenEffect'});
  });

  test('interface parameters use actual argument receivers', () async {
    final report = await memberFixture('''
void transmit(Port value) { value.send(); }
void main() { transmit(Active()); Passive().close(); }
$_receivers
''');
    expect(findingNames(report), {'Passive.send', 'hiddenEffect'});
  });

  test('dynamic locals preserve receiver identity through aliases', () async {
    final report = await memberFixture('''
void main() {
  dynamic selected = Active();
  final alias = selected;
  alias.send();
  Passive().close();
}
$_receivers
''');
    expect(findingNames(report), {'Passive.send', 'hiddenEffect'});
  });

  test('all reached callers contribute receiver types', () async {
    final report = await memberFixture('''
void transmit(Port value) { value.send(); }
void main() { transmit(Active()); transmit(Passive()); Passive().close(); }
$_receivers
''');
    expect(findingNames(report), isEmpty);
  });

  test('test-side arguments do not widen production receivers', () async {
    final report = await memberFixture(
      '''
void transmit(Port value) { value.send(); }
void main() { transmit(Active()); Passive().close(); }
$_receivers
''',
      tests: '''
import 'package:app/main.dart';
void main() { transmit(Passive()); }
''',
    );
    expect(findingNames(report), {'Passive.send', 'hiddenEffect'});
    expect(report.undead.map((f) => f.classification).toSet(), {
      UndeadClassification.testedUndead,
    });
  });

  test('assignments and both branches contribute possible receivers', () async {
    final report = await memberFixture('''
void main(List<String> args) {
  dynamic selected = Active();
  if (args.isNotEmpty) selected = Passive();
  selected.send();
  Passive().close();
}
$_receivers
''');
    expect(findingNames(report), isEmpty);
  });
  test(
    'named arguments and wrapper returns preserve receiver origins',
    () async {
      final report = await memberFixture('''
Port identity(Port input) => input;
void transmit({required Port value}) { value.send(); }
void main() { transmit(value: identity(Active())); Passive().close(); }
$_receivers
''');
      expect(findingNames(report), {'Passive.send', 'hiddenEffect'});
    },
  );

  test(
    'omitted default arguments cannot inherit only supplied origins',
    () async {
      final report = await memberFixture('''
void transmit([Port value = const Passive()]) { value.send(); }
void main() { transmit(Active()); transmit(); Passive().close(); }
abstract interface class Port { void send(); }
class Active implements Port { void send() {} }
class Passive implements Port {
  const Passive();
  void send() { hiddenEffect(); }
  void close() {}
}
void hiddenEffect() {}
''');
      expect(findingNames(report), isEmpty);
    },
  );

  test('mutable object storage does not narrow to its initializer', () async {
    final report = await memberFixture('''
class Box { Port selected = Active(); }
void main() {
  final box = Box();
  box.selected = Passive();
  box.selected.send();
  Passive().close();
}
$_receivers
''');
    expect(findingNames(report), isEmpty);
  });

  test('unknown collection results retain all compatible receivers', () async {
    final report = await memberFixture('''
void main() {
  final values = <Port>[Active(), Passive()];
  values.last.send();
  Passive().close();
}
$_receivers
''');
    expect(findingNames(report), isEmpty);
  });

  test(
    'erased callable getter return does not retain unrelated call methods',
    () async {
      final report = await memberFixture('''
class Action { void call() {} }
class Decoy { void call() { hiddenEffect(); } void close() {} }
class Host { Object get operation => Action(); }
void main() { dynamic host = Host(); host.operation(); Decoy().close(); }
void hiddenEffect() {}
''');
      expect(findingNames(report), {'Decoy.call', 'hiddenEffect'});
    },
  );
  test(
    'operators and patterns use their receiver inside instance methods',
    () async {
      final report = await memberFixture('''
class Runner {
  void run() {
    final Item(:count) = Item();
    print(count);
    print(Item() + 1);
    print(Item()[0]);
  }
}
class Item {
  int get count => countEffect();
  int operator +(int other) => plusEffect();
  int operator [](int index) => indexEffect();
}
int countEffect() => 1;
int plusEffect() => 2;
int indexEffect() => 3;
void main() { Runner().run(); }
''');
      expect(findingNames(report), isEmpty);
    },
  );
  test(
    'recursive callable getter dispatch reaches a finite fixed point',
    () async {
      final report = await memberFixture('''
class RecursiveCallable { Object get call => this; }
void main() { dynamic target = RecursiveCallable(); target(); }
''');
      expect(findingNames(report), isEmpty);
    },
  );
  test(
    'super and redirecting constructors forward actual receiver arguments',
    () async {
      final report = await memberFixture('''
class Parent { Parent(Port value) { value.send(); } }
class Child extends Parent { Child(Port value) : super(value); }
class Redirect {
  Redirect(Port value) { value.send(); }
  Redirect.forward(Port value) : this(value);
}
void main() { Child(Active()); Redirect.forward(Active()); Passive().close(); }
$_receivers
''');
      expect(findingNames(report), {'Passive.send', 'hiddenEffect'});
    },
  );

  test('assignment accessors preserve the actual receiver', () async {
    final report = await memberFixture('''
abstract interface class Holder { set value(int input); }
class Active implements Holder { set value(int input) { liveEffect(); } }
class Passive implements Holder {
  set value(int input) { hiddenEffect(); }
  void close() {}
}
void liveEffect() {}
void hiddenEffect() {}
void main() { Holder selected = Active(); selected.value = 1; Passive().close(); }
''');
    expect(findingNames(report), {'hiddenEffect'});
  });
  for (final update in ['selected += 1', 'selected++', '++selected']) {
    test('compound update $update invalidates a narrowed receiver', () async {
      final report = await memberFixture('''
abstract interface class Port { void send(); }
class Initial implements Port {
  Port operator +(int value) => Replacement();
  void send() {}
}
class Replacement implements Port { void send() { replacementEffect(); } }
void replacementEffect() {}
void main() { dynamic selected = Initial(); $update; selected.send(); }
''');
      expect(findingNames(report), isEmpty);
    });
  }
}
