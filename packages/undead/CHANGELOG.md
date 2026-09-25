## 0.1.2-wip

- Track receiver values at individual uses to find obsolete method bodies and
  their helpers after assignments, alias snapshots, loop writes and bounded
  callback execution. Preserve skipped null-aware effects and distinguish
  supported completed-future suspension from synchronous execution.

- Reuse compatible receiver filtering within each dispatch pass to reduce
  repeated work in large applications with many test witnesses.

- Invalidate receiver origins on destructuring and existing-variable `for-in`
  writes, preserving methods reached after those mutations.

- Separate uncalled named local bodies and narrow member dispatch using bounded
  receiver origins from assignments, arguments and returns.
- Expose assumption-only retained declarations and exclusive helper chains as
  separate uncertain review candidates with retention reasons; keep ordinary
  dead-code counts and default reports unchanged.

- Preserve implicit SDK JSON conversion, dynamic method tear-offs and callable
  getter/field invocations in member analysis, including returned callable
  objects. Disclose conservative JSON protocol retention.
- Add opt-in `--member-level` closed-app analysis and
  `UndeadOptions.memberLevel` to find unused ordinary methods and dependencies
  hidden by live classes.
- Model constructor initialization, receiver dispatch, callbacks and external
  protocol overrides with separate production and test reachability.
- Add qualified review findings, inherited-contract indicators, transitive test
  witnesses and coverage limitations. Default analysis is unchanged.

- Adopt centralized `PathFilter` in `UndeadOptions` and CLI for `--exclude` and
  `--[no-]ignore-generated` file filtering.
- Add `ensure_cli_readme_test.dart` to verify CLI `--help` documentation in
  `README.md`.

## 0.1.1

- Support `--suggest-private` flag to detect unexported top-level declarations
  that can be made library-private (#45).
- Add `suggestPrivate` option to `UndeadOptions`,
  `UndeadReport.privateCandidatesFound`,
  `UndeadClassification.privateCandidate`, and `SuggestedAction.makePrivate`.
- Require `package:analytica ^0.1.1`.

## 0.1.0

- Initial release of reachability and dead/unused declaration analyzer.
- Support for CLI execution, package entrypoint harvesting, and Flutter/test
  framework adapters.
- Deterministic analysis modes: open-world (libraries) and closed-app
  (standalone/executables).
- Custom suppression directives: `// undead:ignore` and
  `// undead:ignore_for_file`.
