import 'package:test/test.dart';

import 'support/member_fixture.dart';

const _types = '''
abstract interface class Port { void run(); }
class North implements Port { void run() { northEffect(); } }
class South implements Port { void run() { southEffect(); } }
void northEffect() {}
void southEffect() {}
''';

void main() {
  const controls = {
    'anonymous reads before and after a write': '''
void main() {
  Port receiver = North(); final read = () { receiver.run(); };
  read(); receiver = South(); read();
}
''',
    'helper invokes reader on both sides of captured mutation': '''
void around(void Function() read, void Function() write) {
  read(); write(); read();
}
void main() {
  Port receiver = North();
  around(() { receiver.run(); }, () { receiver = South(); });
}
''',
    'returned mutable closure keeps both invocation states': '''
void Function() prepare() {
  Port receiver = North();
  return () { receiver.run(); receiver = South(); };
}
void main() { final read = prepare(); read(); read(); }
''',
    'returned readers from separate activations preserve both inputs': '''
void Function() prepare(Port receiver) {
  return () { receiver.run(); };
}
void main() { prepare(North())(); prepare(South())(); }
''',
    'escaped writer can change a returned reader cell': '''
late void Function() write;
void Function() prepare() {
  Port receiver = North();
  write = () { receiver = South(); };
  return () { receiver.run(); };
}
void main() { final read = prepare(); read(); write(); read(); }
''',
    'async prefix runs before caller write, tail after suspension': '''
Future<void> main() async {
  Port receiver = North();
  Future<void> read() async {
    receiver.run(); await Future<void>.value(); receiver.run();
  }
  final work = read(); receiver = South(); await work;
}
''',
    'async local snapshot survives caller write': '''
Future<void> main() async {
  Port receiver = North();
  Future<void> read() async {
    final saved = receiver;
    await Future<void>.value(); saved.run(); receiver.run();
  }
  final work = read(); receiver = South(); await work;
}
''',
    'suspended caller can observe a scheduled writer': '''
Future<void> main() async {
  Port receiver = North();
  Future<void> write() async {
    await Future<void>.value(); receiver = South();
  }
  receiver.run(); final work = write(); await work; receiver.run();
}
''',
    'async reads on both sides of a subsequent caller suspension': '''
Future<void> main() async {
  Port receiver = North();
  Future<void> read() async {
    await Future<void>.value(); receiver.run();
  }
  await read(); receiver = South(); await read();
}
''',
    'unknown scheduling retains all reachable receivers': '''
Future<void> main() async {
  Port receiver = North();
  final read = () { receiver.run(); };
  read();
  await Future<void>.delayed(Duration.zero, () { receiver = South(); });
  read();
}
''',
    'pending activations keep independent parameter snapshots': '''
Future<void> main() async {
  Future<void> read(Port receiver) async {
    final saved = receiver;
    await Future<void>.value(); saved.run();
  }
  final first = read(North()); final second = read(South());
  await first; await second;
}
''',
  };
  for (final entry in controls.entries) {
    test(entry.key, () async {
      final report = await memberFixture('$_types\n${entry.value}');
      expect(findingNames(report), isEmpty);
    });
  }

  test('helper passes an anonymous snapshot through another helper', () async {
    final report = await memberFixture('''
$_types
void invoke(void Function() action) { action(); }
void forward(void Function() action) { invoke(action); }
void main() {
  Port receiver = North(); final saved = receiver;
  final read = () { saved.run(); };
  receiver = South(); forward(read);
}
''');
    expect(findingNames(report), {'South.run', 'southEffect'});
  });
}
