# Changelog

All notable changes to Spectre Kinetic are documented in this file.

## [Unreleased]

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

[Unreleased]: https://github.com/elchemista/spectre_kinetic/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/elchemista/spectre_kinetic/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/elchemista/spectre_kinetic/compare/v0.1.3...v0.1.4
