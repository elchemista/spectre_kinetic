# Changelog

All notable changes to Spectre Kinetic are documented in this file.

## [Unreleased]

### Fixed

- Added an explicit `allow_unmounted_actions: true` planner boundary for
  role-scoped provider catalogs backed by a shared registry artifact. Mounted
  action schemas are still verified exactly, and unmounted selections remain
  non-executable at catalog resolution.

### Changed

- Raised the test-only Spectre integration dependency and the Stack
  compatibility contract to `~> 0.3.2`.
- Read generic-provider argument aliases from action metadata instead of the
  action schema. Spectre `0.3.2` validates declared schemas against a closed
  JSON-Schema subset, so an extra `aliases` keyword now fails dispatch closed.

### Added

- Declared `Spectre.Kinetic.Planner.incremental_cleaner?/0` as `false`. Action
  Language blocks are only recognizable in a complete reply, so streaming
  cannot certify individual deltas and fails closed.

## [0.3.0] - 2026-08-13

### Changed

- Kept Kinetic distribution GitHub-only without Hex package metadata.
- Resolved the test-only Spectre integration dependency from Hex with the
  `~> 0.3.0` requirement.
- Raised the Kinetic package and Stack compatibility contract to `0.3.0` and
  Spectre `~> 0.3.0`.
- Ran default Credo checks in CI alongside the existing Dialyzer job.
- Made provider catalog construction and exact-example lookup linear, cached
  complete ETS embedding matrices, and replaced linear candidate ID indexing.

### Fixed

- Preserved planner error diagnostics in public actions and rejected duplicate
  AL/slot keys before they could silently overwrite values.
- Returned structured errors for incompatible embedding dimensions and faulty
  registry mutation backends instead of crashing planner calls.
- Rejected ambiguous provider examples and created temporary provider
  registries with unpredictable, exclusive files.

## [0.2.0] - 2026-08-01

### Changed

- Kept the core package independent from Spectre; the optional integration is
  compiled without a runtime dependency and implements Stack contract 1
  without pinning a Spectre release line.
- Spectre is fetched directly from GitHub's `0.2.0` tag only in the test
  environment.
- Verified standalone planning, classifier pipelines, provider catalogs, and
  staged Action integration against the Spectre 0.2.0 operational runtime.

### Compatibility

- Kinetic remains a planner boundary; core retains policy, execution, Run,
  Work, Vigil, and Instance ownership.

## [0.1.6] - 2026-07-31

### Changed

- Established a recoverable consolidation baseline with an explicit normative
  public API manifest and uniform release documentation.
- Added no runtime functionality and made no intentional breaking API change.

## [0.1.5] - 2026-07-30

### Changed

- Raised the library and Stack manifest requirement to Spectre 0.1.5.
- Verified that Kinetic-planned Actions inherit the owning core Run and remain
  independently resumable inside one subject Instance.

## [0.1.4] - 2026-07-30

### Changed

- Updated the library, GitHub dependency source, and Stack manifest for
  Spectre 0.1.4 compatibility.
- Documented Kinetic as a passive decision interpreter inside a core-owned
  subject-scoped Agent Instance.

### Added

- Multi-Run Agent Instance conformance coverage for planned Actions and
  revision-fenced core Invocation resumption.

### Not included

- Frame compilation, the final closed-Move IR, and continuity-plane lifecycle
  remain later migration phases.

[Unreleased]: https://github.com/elchemista/spectre_kinetic/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/elchemista/spectre_kinetic/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/elchemista/spectre_kinetic/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/elchemista/spectre_kinetic/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/elchemista/spectre_kinetic/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/elchemista/spectre_kinetic/compare/v0.1.3...v0.1.4
