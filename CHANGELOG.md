# Changelog

All notable changes to Spectre Kinetic are documented in this file.

## [Unreleased]

### Changed

- Made distribution GitHub-only by removing Hex package metadata and package
  build CI.
- Pinned the test-only Spectre integration dependency directly to the GitHub
  `0.2.0` tag.

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

[Unreleased]: https://github.com/elchemista/spectre_kinetic/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/elchemista/spectre_kinetic/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/elchemista/spectre_kinetic/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/elchemista/spectre_kinetic/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/elchemista/spectre_kinetic/compare/v0.1.3...v0.1.4
