import 'package:test/test.dart';
import 'package:undead/undead.dart';

import 'support/member_fixture.dart';

void main() {
  for (final selector in ['make()', 'made', '(maker)()']) {
    test(
      'virtual return origins preserve implementations for $selector',
      () async {
        final report = await memberFixture('''
abstract class Action { void run(); }
class A implements Action { void run() { aEffect(); } }
class B implements Action { void run() { bEffect(); } }
class Spare implements Action { void run() { deadEffect(); } }
class Maker {
  Action call() => A();
  Action make() => A();
  Action get made => A();
}
class Derived extends Maker {
  @override Action call() => B();
  @override Action make() => B();
  @override Action get made => B();
}
void consume(Maker maker) { ${selector == '(maker)()' ? selector : 'maker.$selector'}.run(); }
void aEffect() {}
void bEffect() {}
void deadEffect() {}
void main() { Spare(); consume(Maker()); consume(Derived()); }
''');
        expect(findingNames(report), containsAll(['Spare.run', 'deadEffect']));
        expect(
          findingNames(
            report,
          ).intersection({'A.run', 'B.run', 'aEffect', 'bEffect'}),
          isEmpty,
        );
      },
    );
  }

  for (final selector in ['run()', 'value', 'value = 1']) {
    test('ordinary super forwards receivers through $selector', () async {
      final report = await memberFixture('''
class Base {
  void run() { hook(); }
  int get value { hook(); return 0; }
  set value(int input) { hook(); }
  void hook() { baseEffect(); }
}
class Child extends Base {
  @override void run() { super.run(); }
  @override int get value => super.value;
  @override set value(int input) { super.value = input; }
  @override void hook() { childEffect(); }
  void unused() { deadEffect(); }
}
void baseEffect() {}
void childEffect() {}
void deadEffect() {}
void main() { Base().$selector; Child().$selector; }
''');
      expect(findingNames(report), containsAll(['Child.unused', 'deadEffect']));
      expect(
        findingNames(report).intersection({
          'Base.hook',
          'Child.hook',
          'baseEffect',
          'childEffect',
        }),
        isEmpty,
      );
    });
  }

  _constructorForwardingTests();
  _constructorCallFormTests();
  _abstractMixinTests();

  for (final selector in ['make()', 'made']) {
    test('mixin super joins the dispatched $selector return', () async {
      final report = await memberFixture('''
class A { void run() { aEffect(); } }
class B extends A { @override void run() { bEffect(); } }
class Spare extends A { @override void run() { deadEffect(); } }
class Base { A make() => A(); A get made => A(); }
mixin First on Base {
  @override A make() => B();
  @override A get made => B();
}
mixin Second on Base { A relay() => super.$selector; }
class Child extends Base with First, Second {}
void aEffect() {}
void bEffect() {}
void deadEffect() {}
void main() { Spare(); Base().$selector.run(); Child().relay().run(); }
''');
      expect(findingNames(report), containsAll(['Spare.run', 'deadEffect']));
      expect(findingNames(report).intersection({'B.run', 'bEffect'}), isEmpty);
    });
  }

  test('unnamed extensions keep same-name members distinct', () async {
    final report = await memberFixture('''
extension on int { void run() { liveEffect(); } }
extension on String { void run() { deadEffect(); } }
void liveEffect() {}
void deadEffect() {}
void main() { 1.run(); }
''');
    expect(findingNames(report), contains('deadEffect'));
    expect(findingNames(report), isNot(contains('liveEffect')));
  });

  test('extension type calls on representation casts execute bodies', () async {
    final report = await memberFixture('''
extension type Id(int value) {
  void run() { liveEffect(); }
  void unused() { deadEffect(); }
}
void liveEffect() {}
void deadEffect() {}
void main() { final id = 1 as Id; id.run(); }
''');
    expect(findingNames(report), {'Id.unused', 'deadEffect'});
  });

  test('return origins do not merge separate virtual call sites', () async {
    final report = await memberFixture('''
class A { void run() { aEffect(); } }
class B extends A { @override void run() { deadEffect(); } }
class Maker { A make() => A(); }
class Derived extends Maker { @override A make() => B(); }
void aEffect() {}
void deadEffect() {}
void main() { Maker().make().run(); Derived().make(); }
''');
    expect(findingNames(report), {'B.run', 'deadEffect'});
  });

  test(
    'super calls through redirected constructors retain subclass receivers',
    () async {
      final report = await memberFixture('''
class Base {
  Base() : this.named();
  Base.named() { initialize(); }
  void initialize() { baseEffect(); }
}
class Child extends Base {
  Child() : super();
  @override void initialize() { childEffect(); }
  void unused() { deadEffect(); }
}
void baseEffect() {}
void childEffect() {}
void deadEffect() {}
void main() { Base(); Child(); }
''');
      expect(findingNames(report), {'Child.unused', 'deadEffect'});
    },
  );

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
void main() { Base(); Child(); }
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

void _constructorForwardingTests() {
  for (final (forwarding, named) in const [
    ('factory', false),
    ('factory', true),
    ('super-formal', false),
    ('super-formal', true),
    ('mixed-super-formal', false),
  ]) {
    test(
      '$forwarding forwards ${named ? 'named' : 'positional'} arguments',
      () async {
        final argument = named ? 'value: ' : '';
        final declarations = _forwardingDeclarations(forwarding, named);
        final report = await memberFixture('''
abstract class Action { void run(); }
class A implements Action { void run() { aEffect(); } }
class B implements Action { void run() { bEffect(); } }
class Spare implements Action { void run() { deadEffect(); } }
$declarations
void aEffect() {}
void bEffect() {}
void deadEffect() {}
void main() { Spare(); Impl(${argument}A()); API(${argument}B()); }
''');
        expect(findingNames(report), {'Spare.run', 'deadEffect'});
      },
    );
  }
}

void _constructorCallFormTests() {
  for (final form in [
    'implicit',
    'tearoff',
    'forwarded',
    'escaped',
    'global',
    'field',
    'field-formal',
    'field-initializer',
    'assigned',
    'sdk',
    'getter',
    'instance-getter',
    'explicit-call',
    'list',
    'map',
    'record',
  ]) {
    test('$form constructor calls preserve compatible dead methods', () async {
      final constructors = _callFormConstructors(form);
      final call = switch (form) {
        'implicit' => 'B(); Child();',
        'forwarded' => 'invoke(Box.new, B());',
        'escaped' => 'B(); register(Box.new);',
        'global' => 'make(B());',
        'field' => 'Holder().make(B());',
        'field-formal' || 'field-initializer' => 'Holder(Box.new).make(B());',
        'assigned' => 'final alias = Box.new; stored = alias; stored!(B());',
        'sdk' => '<Action>[B()].map(Box.new).toList();',
        'getter' => 'make(B()).finish();',
        'instance-getter' => 'Holder().make(B()).finish();',
        'explicit-call' => 'final make = Box.new; make.call(B());',
        'list' =>
          'final alias = Box.new; final makers = [alias]; makers.single(B());',
        'map' => "final makers = {'box': Box.new}; makers['box']!(B());",
        'record' => 'final makers = (Box.new,); makers.\$1(B());',
        _ => 'final make = Box.new; final alias = make; alias(B());',
      };
      final helper = switch (form) {
        'forwarded' =>
          'void invoke(Box Function(Action) make, Action value) '
              '{ make(value); }',
        'escaped' => 'external void register(Box Function(Action) make);',
        'global' => 'final make = Box.new;',
        'field' => 'class Holder { final make = Box.new; }',
        'field-formal' =>
          'class Holder { final Box Function(Action) make; '
              'Holder(this.make); }',
        'field-initializer' =>
          'class Holder { final Box Function(Action) make; '
              'Holder(Box Function(Action) value) : make = value; }',
        'assigned' => 'Box Function(Action)? stored;',
        'getter' => 'Box Function(Action) get make => Box.new;',
        'instance-getter' =>
          'class Holder { '
              'Box Function(Action) get make => Box.new; }',
        _ => '',
      };
      final precise = const {
        'tearoff',
        'forwarded',
        'getter',
        'instance-getter',
        'explicit-call',
      }.contains(form);
      final report = await memberFixture('''
abstract class Action { void run(); }
class A implements Action { void run() { aEffect(); } }
class B implements Action { const B(); void run() { bEffect(); } }
class Spare implements Action { void run() { deadEffect(); } }
$constructors
$helper
void aEffect() {}
void bEffect() {}
void deadEffect() {}
void main() { Spare(); Box(A()); $call }
''');
      const dead = {'Spare.run', 'deadEffect'};
      // Opaque calls may still report live B.run. Do not hide compatible dead
      // methods merely to avoid that accepted false positive.
      expect(findingNames(report), precise ? dead : containsAll(dead));
      expect(findingNames(report), isNot(contains('aEffect')));
    });
  }
  test('mixin super lookup respects private library identity', () async {
    final report = await memberFixture(
      '''
import 'base.dart';
import 'first.dart';
class Child extends Base with First, Second {}
void main() { Child().run(); }
''',
      files: {
        'base.dart': '''
class Base { void _step() { liveEffect(); } }
mixin Second on Base { void run() { super._step(); } }
void liveEffect() {}
''',
        'first.dart': '''
import 'base.dart';
mixin First on Base { void _step() { deadEffect(); } }
void deadEffect() {}
''',
      },
    );
    expect(findingNames(report), contains('deadEffect'));
    expect(findingNames(report), isNot(contains('liveEffect')));
  });
}

String _forwardingDeclarations(String forwarding, bool named) {
  final parameter = named ? '{required Action value}' : 'Action value';
  final superParameter = named ? '{required super.value}' : 'super.value';
  final extra = forwarding == 'mixed-super-formal' ? ', {int tag = 0}' : '';
  final initializer = forwarding == 'mixed-super-formal'
      ? ': super(tag: 1)'
      : '';
  return forwarding == 'factory'
      ? 'abstract class API { factory API($parameter) = Impl; } '
            'class Impl implements API { '
            'Impl($parameter) { value.run(); } }'
      : 'class Impl { Impl($parameter$extra) { value.run(); } } '
            'class API extends Impl { '
            'API($superParameter) $initializer; }';
}

void _abstractMixinTests() {
  test(
    'abstract mixin requirements do not replace super implementations',
    () async {
      final report = await memberFixture('''
class Base {
  void run() { methodEffect(); }
  int get value { readEffect(); return 0; }
  set value(int input) { writeEffect(); }
}
mixin First on Base { void run(); int get value; set value(int input); }
mixin Second on Base {
  void invoke() { super.run(); print(super.value); super.value = 1; }
}
class Child extends Base with First, Second {
  void unused() { deadEffect(); }
}
void methodEffect() {}
void readEffect() {}
void writeEffect() {}
void deadEffect() {}
void main() { Child().invoke(); }
''');
      expect(findingNames(report), {'Child.unused', 'deadEffect'});
    },
  );
}

String _callFormConstructors(String form) {
  final finish = form.contains('getter') ? 'void finish() {}' : '';
  return form == 'implicit'
      ? 'class Box { Box([Action value = const B()]) { value.run(); } } '
            'class Child extends Box {}'
      : 'class Box { Box(Action value) { value.run(); } $finish }';
}
