import 'package:test/test.dart';

import 'support/member_fixture.dart';

void main() {
  for (final locals in [0, 100]) {
    test(
      'unrelated caller locals do not exhaust callee cleanup: $locals',
      () async {
        final declarations = [
          for (var index = 0; index < locals; index++)
            'final value$index = $index;',
        ].join('\n');
        final calls = List.filled(60, 'noop();').join('\n');
        final report = await memberFixture('''
abstract interface class Signal { void fire(); }
class Cyan implements Signal { void fire() { cyanEffect(); } }
class Magenta implements Signal { void fire() { magentaEffect(); } }
void cyanEffect() { print('cyan'); }
void magentaEffect() { print('magenta'); }
void main() {
  Signal current = Cyan();
  $declarations
  void noop() {}
  $calls
  current = Magenta();
  current.fire();
}
''');
        expect(findingNames(report), {'Cyan.fire', 'cyanEffect'});
      },
    );
  }
}
