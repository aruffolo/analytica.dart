import 'package:test/test.dart';
import 'package:undead/undead.dart';

import 'support/member_fixture.dart';

void main() {
  test(
    'interface dispatch does not run disconnected implementations',
    () async {
      final report = await memberFixture(
        '''
void main() { Contract value = Active(); value.run(); }
abstract interface class Contract { void run(); }
class Active implements Contract { void run() { liveDependency(); } }
class Dormant implements Contract { void run() { deadDependency(); } }
void liveDependency() {}
void deadDependency() {}
''',
        tests: '''
import 'package:app/main.dart';
void main() { Dormant().run(); }
''',
      );
      expect(findingNames(report), containsAll(['Dormant', 'deadDependency']));
      expect(
        findingNames(
          report,
        ).intersection({'Active', 'Active.run', 'liveDependency', 'Contract'}),
        isEmpty,
      );
      expect(
        report.undead
            .singleWhere((f) => f.name == 'deadDependency')
            .classification,
        UndeadClassification.testedUndead,
      );
    },
  );

  test('implicit super and eager field initializers execute', () async {
    final report = await memberFixture('''
void main() { Child(); }
class Base { Base() { constructorEffect(); initialize(); } void initialize() {} }
class Child extends Base {
  final field = fieldEffect();
  @override void initialize() { overrideEffect(); }
  void unused() { deadEffect(); }
}
void constructorEffect() {}
int fieldEffect() => 1;
void overrideEffect() {}
void deadEffect() {}
''');
    expect(findingNames(report), containsAll(['Child.unused', 'deadEffect']));
    expect(
      findingNames(report).intersection({
        'constructorEffect',
        'fieldEffect',
        'overrideEffect',
        'Child.initialize',
      }),
      isEmpty,
    );
  });

  test('mixin order and explicit super dispatch', () async {
    final report = await memberFixture('''
void main() { Child().run(); }
class Base { void run() { baseEffect(); } }
mixin First on Base { @override void run() { firstEffect(); super.run(); } }
mixin Second on Base { @override void run() { secondEffect(); super.run(); } }
class Child extends Base with First, Second {}
void baseEffect() {}
void firstEffect() {}
void secondEffect() {}
''');
    expect(
      findingNames(report).intersection({
        'baseEffect',
        'firstEffect',
        'secondEffect',
        'Base.run',
        'First.run',
        'Second.run',
      }),
      isEmpty,
    );
  });

  test(
    'redirecting constructors and factories allocate concrete receivers',
    () async {
      final report = await memberFixture('''
void main() { Factory().run(); Redirect(); }
abstract class Factory { factory Factory() = Product; void run(); }
class Product implements Factory {
  Product() { productEffect(); }
  void run() { methodEffect(); }
}
class Redirect { Redirect() : this.named(); Redirect.named() { redirectEffect(); } }
void productEffect() {}
void methodEffect() {}
void redirectEffect() {}
''');
      expect(findingNames(report), isEmpty);
    },
  );

  test(
    'type-only references preserve signatures without executing bodies',
    () async {
      final report = await memberFixture('''
void main() { print(Service); }
class Service {
  Result run() { deadEffect(); return Result(); }
}
class Result {}
void deadEffect() {}
''');
      expect(findingNames(report), containsAll(['Service.run', 'deadEffect']));
      expect(findingNames(report).intersection({'Service', 'Result'}), isEmpty);
    },
  );

  test('late and static initializers run only when accessed', () async {
    final report = await memberFixture('''
void main() { Holder().used++; print(Holder.staticUsed); }
class Holder {
  late int used = usedEffect();
  late int unused = unusedEffect();
  static int staticUsed = staticEffect();
  static int staticUnused = unusedStaticEffect();
}
int usedEffect() => 0;
int unusedEffect() => 0;
int staticEffect() => 0;
int unusedStaticEffect() => 0;
''');
    expect(
      findingNames(report),
      containsAll(['unusedEffect', 'unusedStaticEffect']),
    );
    expect(
      findingNames(report).intersection({'usedEffect', 'staticEffect'}),
      isEmpty,
    );
  });
  test(
    'enum instances and object-pattern getters execute dependencies',
    () async {
      final report = await memberFixture('''
void main() {
  Mode.active.run();
  final Value(:data) = Value();
  print(data);
}
enum Mode { active; void run() { enumEffect(); } void unused() {} }
class Value { int get data { getterEffect(); return 1; } }
void enumEffect() {}
void getterEffect() {}
''');
      expect(findingNames(report), {'Mode.unused'});
    },
  );
  test(
    'applied mixin field initializers execute during construction',
    () async {
      final report = await memberFixture('''
void main() { Child(); }
mixin Storage { final value = initialize(); }
class Child with Storage { void unused() {} }
int initialize() { constructorDependency(); return 1; }
void constructorDependency() {}
''');
      expect(findingNames(report), {'Child.unused'});
    },
  );
  test('mixin super getters and setters follow applied order', () async {
    final report = await memberFixture('''
void main() { final child = Child(); print(child.value); child.value = 1; }
class Base { int get value => 0; set value(int value) {} }
mixin First on Base {
  @override int get value { readEffect(); return super.value; }
  @override set value(int value) { writeEffect(); super.value = value; }
}
mixin Second on Base {
  @override int get value => super.value;
  @override set value(int value) { super.value = value; }
}
class Child extends Base with First, Second {}
void readEffect() {}
void writeEffect() {}
''');
    expect(findingNames(report), isEmpty);
  });
  test(
    'a later call preserves a receiver allocated by an earlier call',
    () async {
      final report = await memberFixture('''
abstract interface class Channel { void send(); }
Channel current = First();
Channel selected() => current;
class First implements Channel { void send() { current = Second(); } }
class Second implements Channel { void send() { delivered(); } }
class Decoy { void send() { unrelated(); } void close() {} }
void delivered() {}
void unrelated() {}
void main() { selected().send(); selected().send(); Decoy().close(); }
''');
      expect(findingNames(report), {'Decoy.send', 'unrelated'});
    },
  );
}
