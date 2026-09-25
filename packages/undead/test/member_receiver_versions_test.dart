import 'package:test/test.dart';
import 'package:undead/undead.dart';

import 'support/member_fixture.dart';

const _types = '''
abstract interface class Port { void run(); }
class North implements Port { void run(){ northEffect(); } }
class South implements Port { void run(){ southEffect(); } }
void northEffect() {}
void southEffect() {}
''';

void main() {
  test('FutureOr with a nullable value can still skip a chain', () async {
    final report = await memberFixture('''
import 'dart:async';
$_types
void route(FutureOr<int?> value) {
  Port receiver = North();
  value?.toString().padLeft(1, (receiver = South()).toString());
  receiver.run();
}
void main() { route(null); }
''');
    expect(
      findingNames(report).intersection({'North.run', 'northEffect'}),
      isEmpty,
    );
  });
  test('nonnullable formal cannot skip a null-aware argument write', () async {
    final report = await memberFixture('''
$_types
class Sink { void accept(Port value) {} }
void route(Sink sink) {
  Port receiver = North();
  sink?.accept(receiver = South()); receiver.run();
}
void main() { route(Sink()); }
''');
    expect(findingNames(report), {'North.run', 'northEffect'});
  });
  for (final nullable in [true, false]) {
    for (final write in [
      'sink?.identity().accept(receiver = South());',
      'sink?.value = (receiver = South());',
    ]) {
      test(
        'null-shortening preserves skipped writes: $nullable $write',
        () async {
          final report = await memberFixture('''
$_types
class Sink {
  Sink identity() => this;
  void accept(Port value) {}
  set value(Port value) {}
}
void main() {
  Port receiver = North();
  Sink? sink = ${nullable ? 'null' : 'Sink()'};
  $write
  receiver.run();
}
''');
          final live = nullable
              ? {'North.run', 'northEffect'}
              : {'South.run', 'southEffect'};
          expect(findingNames(report).intersection(live), isEmpty);
        },
      );
    }
  }
  test('null assertion preserves the reaching receiver', () async {
    final report = await memberFixture('''
$_types
void main() {
  Port? receiver = North(); receiver = South(); receiver!.run();
}
''');
    expect(findingNames(report), {'North.run', 'northEffect'});
  });
  const precision = {
    'overwritten formal': '''
void deliver(Port receiver) { receiver = South(); receiver.run(); }
void main() { deliver(North()); }
''',
    'copied value survives rebinding': '''
void main() {
  Port receiver = South(); final saved = receiver;
  receiver = North(); saved.run();
}
''',
    'assignment uses previous RHS value': '''
void main() {
  Port receiver = South(); Port saved = North();
  saved = receiver; receiver = North(); saved.run();
}
''',
    'both branches overwrite incoming value': '''
void main(List<String> args) {
  Port receiver = North();
  if (args.isEmpty) { receiver = South(); } else { receiver = South(); }
  receiver.run();
}
''',
  };
  for (final entry in precision.entries) {
    test(entry.key, () async {
      final report = await memberFixture('$_types\n${entry.value}');
      expect(findingNames(report), {'North.run', 'northEffect'});
      expect(report.uncertainCandidates, isEmpty);
    });
  }
  const preservation = {
    'call before parameter write': '''
void deliver(Port receiver) { receiver.run(); receiver = South(); receiver.run(); }
void main() { deliver(North()); }
''',
    'both alias values called': '''
void main() {
  Port receiver = North(); final saved = receiver;
  receiver = South(); saved.run(); receiver.run();
}
''',
    'branch may retain old value': '''
void main(List<String> args) {
  Port receiver = North(); if(args.isNotEmpty) receiver = South();
  receiver.run();
}
''',
    'short circuit assignment may not execute': '''
void main(List<String> args) {
  Port receiver = North();
  args.isNotEmpty && ((receiver = South()) is South);
  receiver.run();
}
''',
    'conditional expression alternative assignments': '''
void main(List<String> args) {
  Port receiver = North();
  args.isEmpty ? receiver.run() : (receiver = South()).run();
  receiver.run();
}
''',
    'shadowed variable has independent state': '''
void main() {
  Port receiver = North();
  { Port receiver = South(); receiver.run(); }
  receiver.run();
}
''',
    'assignment argument updates subsequent reads': '''
void consume(Port value) { value.run(); }
void main() {
  Port receiver = North();
  receiver.run(); consume(receiver = South()); receiver.run();
}
''',
    'two callers contribute formal entry values': '''
void deliver(Port receiver) { receiver.run(); }
void main() { deliver(North()); deliver(South()); }
''',
  };
  for (final entry in preservation.entries) {
    test(entry.key, () async {
      final report = await memberFixture('$_types\n${entry.value}');
      expect(findingNames(report), isEmpty);
    });
  }
  test('receiver value is captured before evaluating call arguments', () async {
    final report = await memberFixture('''
${_types.replaceAll('void run()', 'void run([Port? unused])')}
void main() {
  Port receiver = North();
  receiver.run(receiver = South()); receiver.run();
}
''');
    expect(findingNames(report), isEmpty);
  });
  test('null-aware arguments may leave another receiver unchanged', () async {
    final report = await memberFixture('''
$_types
class Sink { void accept(Port value) {} }
void main(List<String> args) {
  Port receiver = North();
  Sink? sink = args.isEmpty ? null : Sink();
  sink?.accept(receiver = South()); receiver.run();
}
''');
    expect(findingNames(report), isEmpty);
  });
  test('test-only argument does not enter production flow', () async {
    final report = await memberFixture(
      '''
$_types
void deliver(Port receiver) { final saved = receiver; saved.run(); }
void main() { deliver(North()); South(); }
''',
      tests: '''
import 'package:app/main.dart';
void main() { deliver(South()); }
''',
    );
    expect(findingNames(report), {'South.run', 'southEffect'});
    expect(report.undead.map((f) => f.classification).toSet(), {
      UndeadClassification.testedUndead,
    });
  });
}
