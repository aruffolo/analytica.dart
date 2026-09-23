import 'dart:io';

import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:undead/undead.dart';

import 'support/member_fixture.dart';

const _payload = '''
class Payload {
  Map<String, Object> toJson() { encodingEffect(); return {'value': 7}; }
  void dormant() {}
}
void encodingEffect() {}
class Unallocated { Map<String, Object> toJson() => {}; }
''';

Future<UndeadReport> _jsonReport(String entry) => memberFixture('''
import 'dart:convert';
void main() { $entry }
$_payload
''');

void _expectResolved(UndeadReport report) {
  expect(
    report.coverageLimitations.where(
      (l) => l.code == 'resolutionError' || l.code == 'unresolvedUnit',
    ),
    isEmpty,
  );
}

Future<void> _checkEncoding(String entry) async {
  final report = await _jsonReport(entry);
  _expectResolved(report);
  await _expectRuns();
  expect(findingNames(report), {'Payload.dormant', 'Unallocated'});
  expect(
    report.coverageLimitations.map((l) => l.code),
    contains('implicitJsonProtocol'),
  );
}

Future<void> _checkDynamic(String member, String entry) async {
  final report = await memberFixture('''
void main() { dynamic value = Transport(); $entry }
class Transport {
  $member
  void dormant() {}
}
void delivered() {}
class Unallocated { void dispatch() {} }
''');
  _expectResolved(report);
  await _expectRuns();
  expect(findingNames(report), {'Transport.dormant', 'Unallocated'});
}

Future<void> _expectRuns() async {
  final result = await Process.run(Platform.resolvedExecutable, [
    d.path('app/lib/main.dart'),
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
}

void main() {
  const encodings = {
    'direct': 'print(jsonEncode(Payload()));',
    'nested containers': "print(jsonEncode({'items': [Payload()]}));",
    'codec': 'print(json.encode(Payload()));',
    'encoder': 'print(JsonEncoder().convert(Payload()));',
    'indented encoder':
        "print(JsonEncoder.withIndent(' ').convert(Payload()));",
    'UTF8 encoder': 'print(JsonUtf8Encoder().convert(Payload()));',
    'codec constructor': 'print(JsonCodec().encode(Payload()));',
    'function tear-off': 'final encode = jsonEncode; print(encode(Payload()));',
    'encoder getter': 'print(json.encoder.convert(Payload()));',
    'erased encoder':
        'Converter<Object?, String> encoder = JsonEncoder(); '
        'print(encoder.convert(Payload()));',
    'dynamic codec': 'dynamic codec = json; print(codec.encode(Payload()));',
    'constructor tear-off':
        'final create = JsonEncoder.new; print(create().convert(Payload()));',
    'fused codec': 'print(json.fuse(utf8).encode(Payload()));',
    'chunked encoder':
        'final sink = StringConversionSink.fromStringSink(StringBuffer()); '
        'final conversion = JsonEncoder().startChunkedConversion(sink); '
        'conversion.add(Payload()); conversion.close();',
    'explicit converter':
        'print(jsonEncode(Payload(), '
        'toEncodable: (value) => (value as Payload).toJson()));',
  };
  for (final entry in encodings.entries) {
    test('SDK JSON ${entry.key}', () => _checkEncoding(entry.value));
  }

  test('reachable encoding preserves recursively produced receivers', () async {
    final report = await memberFixture('''
import 'dart:convert';
void main() { print(jsonEncode(Envelope())); }
class Envelope {
  Map<String, Object> toJson() => {'child': Item()};
  void dormant() {}
}
class Item {
  Map<String, Object> toJson() { effect(); return {}; }
  void dormant() {}
}
void effect() {}
''');
    _expectResolved(report);
    expect(findingNames(report), {'Envelope.dormant', 'Item.dormant'});
  });

  test('SDK-like names in local code do not activate JSON protocol', () async {
    final report = await memberFixture('''
void main() { print(jsonEncode(Payload())); }
Object jsonEncode(Object value) => value;
$_payload
''');
    _expectResolved(report);
    expect(findingNames(report), {
      'Payload.toJson',
      'Payload.dormant',
      'encodingEffect',
      'Unallocated',
    });
    expect(report.coverageLimitations, isEmpty);
  });

  test(
    'unreachable encoder does not activate production JSON protocol',
    () async {
      final report = await memberFixture('''
import 'dart:convert';
void main() { print(Payload()); }
void unusedEncoder() { jsonEncode(Payload()); }
$_payload
''');
      expect(
        findingNames(report),
        containsAll(['Payload.toJson', 'encodingEffect']),
      );
    },
  );

  test(
    'test-only encoding does not activate production JSON protocol',
    () async {
      final report = await memberFixture(
        'void main() { print(Payload()); }\n$_payload',
        tests: '''
import 'dart:convert';
import 'package:app/main.dart';
void main() { jsonEncode(Payload()); }
''',
      );
      _expectResolved(report);
      expect(
        report.undead
            .singleWhere((f) => f.name == 'Payload.toJson')
            .classification,
        UndeadClassification.testedUndead,
      );
    },
  );

  test(
    'dynamic method property read preserves tear-off',
    () => _checkDynamic(
      'void dispatch() { delivered(); }',
      'final callback = value.dispatch; callback();',
    ),
  );
  test(
    'dynamic invocation preserves callable getter',
    () => _checkDynamic(
      'void Function() get dispatch => delivered;',
      'value.dispatch();',
    ),
  );
  test(
    'dynamic invocation preserves callable field',
    () => _checkDynamic('final dispatch = delivered;', 'value.dispatch();'),
  );
  test(
    'dynamic null-aware property preserves method tear-off',
    () => _checkDynamic(
      'void dispatch() { delivered(); }',
      'final callback = value?.dispatch; callback();',
    ),
  );

  test('dynamic callable getter result invokes returned object', () async {
    final report = await memberFixture('''
void main() { dynamic receiver = Transport(); receiver.dispatch(); }
class Transport { Worker get dispatch => Worker(); void dormant() {} }
class Worker { void call() { delivered(); } void dormant() {} }
void delivered() {}
''');
    _expectResolved(report);
    expect(findingNames(report), {'Transport.dormant', 'Worker.dormant'});
  });

  test('JSON convention also supports a callable getter', () async {
    final report = await memberFixture('''
import 'dart:convert';
void main() { print(jsonEncode(Payload())); }
class Payload { Map<String, Object> Function() get toJson => encode; void dormant() {} }
Map<String, Object> encode() { effect(); return {}; }
void effect() {}
''');
    _expectResolved(report);
    expect(findingNames(report), {'Payload.dormant'});
  });
}
