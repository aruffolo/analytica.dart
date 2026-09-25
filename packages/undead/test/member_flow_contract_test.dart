import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'support/member_fixture.dart';

// The oracle comes from the source-level contracts, never from scanner output.
// These former review holdouts are now development regressions.
void main() {
  final contract =
      jsonDecode(
            File('test/fixtures/member_flow_contract.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final value in contract['cases'] as List<dynamic>) {
    final fixture = value as Map<String, dynamic>;
    final name = fixture['name'] as String;
    test(name, () async {
      final report = await memberFixture(fixture['source'] as String);
      final process = await Process.start(Platform.resolvedExecutable, [
        d.path('app/lib/main.dart'),
      ], workingDirectory: d.path('app'));
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      final exit = await process.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          throw StateError('Runtime witness timed out: $name');
        },
      );
      expect(exit, 0, reason: await stderr);
      expect(await stdout, fixture['stdout']);

      final dead = (fixture['dead'] as List<dynamic>).cast<String>().toSet();
      final live = (fixture['live'] as List<dynamic>).cast<String>().toSet();
      final ordinary = findingNames(report);
      final uncertain = report.uncertainCandidates.map((f) => f.name).toSet();
      // A preservation-only assertion would miss a recall regression caused by
      // a broad conservative fallback. Require every dead target as well.
      expect(
        {
          'missingDead': dead.difference(ordinary).toList()..sort(),
          'liveReportedDead': live.intersection(ordinary).toList()..sort(),
          'liveReportedUncertain': live.intersection(uncertain).toList()
            ..sort(),
          if (fixture['exact'] == true)
            'unexpectedDead': ordinary.difference(dead).toList()..sort(),
        },
        {
          'missingDead': <String>[],
          'liveReportedDead': <String>[],
          'liveReportedUncertain': <String>[],
          if (fixture['exact'] == true) 'unexpectedDead': <String>[],
        },
        reason: fixture['rationale'] as String,
      );
    });
  }
}
