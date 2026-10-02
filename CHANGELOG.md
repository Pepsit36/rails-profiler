# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Released sections are written by the `release` CI job, which derives the version
from the last tag and the conventional commit types, stamps the `[Unreleased]`
section below and commits the result as `chore(release): vX.Y.Z [skip ci]`.
Add your own entries under `[Unreleased]`; do not edit released sections.

## [Unreleased]

## [0.30.4] - 2026-07-01

### Fixed

- **cluster**: resolve profiles across slaves from master ProfilesController

## [0.30.3] - 2026-06-29

### Fixed

- wrap profile dashboards and TestRunnerPage with QueryClientProvider

## [0.30.2] - 2026-06-29

### Fixed

- **middleware**: dup downstream headers before mutation

## [0.30.1] - 2026-06-29

### Fixed

- **cluster**: sentinel mismatch, profile list pagination, nil safety in MCP tools and HTTPS slave URLs

## [0.30.0] - 2026-06-28

### Added

- **cluster**: master/slave profiler clustering

## [0.29.0] - 2026-06-28

### Added

- **sse**: live profile updates via server-sent events

## [0.28.0] - 2026-06-06

### Added

- **http**: add http_backtrace_depth config option

## [0.27.1] - 2026-06-06

### Changed

- **api**: replace manual fetch() calls with orval-generated TanStack Query hooks

### Fixed

- **file-store**: prevent ENOENT errors on concurrent profile file deletion

## [0.27.0] - 2026-06-02

### Added

- **mcp**: console profiling, mailer detail, logs/env/i18n sections and full documentation

## [0.26.0] - 2026-06-02

### Added

- **test-profiler**: add run_tests MCP tool, track_tests config, specs and docs
- **test-profiler**: enrich reporter, add SSE streaming, MCP tools and env safety
- **test-profiler**: add test profiling, test runner UI and MCP tool

## [0.25.0] - 2026-06-01

### Added

- **console**: add console profiling tab with IRB instrumentation

### Changed

- document the console profiling tab and the env override behavior

### Fixed

- **spec**: update sidekiq and toolbar specs to match current implementation

## [0.24.0] - 2026-06-01

### Added

- **mcp**: add ENV variable management tools

## [0.23.0] - 2026-05-27

### Added

- **profile-list**: global clear-all button and auto-refresh on tab switch

## [0.22.1] - 2026-05-26

### Fixed

- **http**: propagate collector to child threads, add fire-and-forget support, fix deep backtrace capture

## [0.22.0] - 2026-05-04

### Added

- **mailer**: body preview, variables display, queued badge, and design alignment
- **collector**: implement MailerCollector with ActionMailer tracking

### Fixed

- **mailer**: add Mailers tab to JobProfileDashboard
- **mailer**: thread isolation and deliver_later mode detection
- **mailer**: add MailerCollector to job profiler and align toolbar item design
- **mailer**: handle Rails 7 encoded mail string in deliver.action_mailer payload
- **mailer**: replace Thread.current.delete with read+nil for fiber-local vars
- **version**: remove pre-release suffix to fix bundler resolution
- **mailer**: address code review findings from MR !32

## [0.21.0] - 2026-05-02

### Added

- **toolbar**: add collapse/expand toggle

## [0.20.0] - 2026-05-01

### Added

- **ui**: display gem version and warn on mismatch

## [0.19.2] - 2026-04-24

### Fixed

- **http**: capture RestClient body_stream, remove body size limits, show bodies in MCP

## [0.19.1] - 2026-04-17

### Fixed

- **env-vars**: fix revert restoring wrong value, SQLite busy, middleware rescue and UI

## [0.19.0] - 2026-04-15

### Added

- **env**: propagate env var overrides to Sidekiq workers

## [0.18.0] - 2026-04-14

### Changed

- **ui**: extract shared tab utilities and redesign Request tab

### Fixed

- **http**: capture outbound request body passed as 2nd arg to http.request()

## [0.17.0] - 2026-04-13

### Added

- **dashboard**: add env tab to home page and env/job toolbar items

## [0.16.0] - 2026-04-13

### Added

- **function-profiler**: add stackprof sampling mode with multi-clock and GC visibility

### Fixed

- **function-profiler**: fix stackprof bugs, remove minimal mode, improve perf

## [0.15.0] - 2026-04-11

### Added

- **env**: add environment variables tab

## [0.14.0] - 2026-04-09

### Added

- **profiler**: link jobs to their triggering request or parent job

## [0.13.0] - 2026-04-09

### Added

- **ui**: always show waterfall above HTTP request list
- **ui**: use SmartBodyPreview in RequestTab for copy/download on request and response bodies
- **ui**: add copy/download on HTTP bodies, waterfall view, date sort, UX improvements

### Fixed

- **ui**: derive download extension from actual MIME type instead of body category
- **ui**: move sortedJobs after filteredJobs to fix TDZ error

## [0.12.0] - 2026-04-09

### Added

- **profiler**: add function-level profiling with flamegraph and stats table

## [0.11.1] - 2026-04-09

### Added

- **config**: add tmp_path option to centralize storage directory

### Fixed

- **mcp**: decompress gzip+base64 bodies before returning to UI and MCP

## [0.11.0] - 2026-04-06

### Added

- **ui**: add load-more pagination to profile list

## [0.10.1] - 2026-04-06

### Changed

- add full user documentation with UI guide, MCP guide, and screenshots

## [0.10.0] - 2026-04-06

### Added

- **middleware**: configurable CORS origins, CSP nonce support, body compression

## [0.9.1] - 2026-04-06

### Changed

- **collectors**: remove PerformanceCollector in favor of FlameGraphCollector

## [0.9.0] - 2026-04-06

### Added

- **profiler**: add Profiler.measure custom instrumentation API

## [0.8.0] - 2026-04-05

### Added

- **ui**: sortable columns, quick filter presets, and flamegraph search

## [0.7.0] - 2026-04-05

### Added

- **database**: N+1 visual detection and EXPLAIN ANALYZE integration

## [0.6.0] - 2026-04-05

### Added

- **mcp**: reduce token usage with filtering, body file saving, and pagination

## [0.5.0] - 2026-04-04

### Added

- **mcp**: outbound IDs, domain filter, datetimes, latest token, exceptions and copy helpers

## [0.4.0] - 2026-04-03

### Added

- **collector**: add I18n panel to track translation lookups per request

## [0.3.0] - 2026-04-02

### Added

- **collector**: add routes panel and enrich request collector

## [0.2.0] - 2026-03-29

### Added

- **collector**: Logger/Logs panel - capture Rails.logger messages per request
- publish gem to RubyGems.org

### Fixed

- publish to rubygems.org with `GEM_HOST_API_KEY` instead of a credentials file entry

## [0.1.4] - 2026-03-29

### Added

- **profiler**: capture full request/response and add MCP history clear

## [0.1.3] - 2026-03-29

_No notable changes._

## [0.1.2] - 2026-03-25

_No notable changes._

## [0.1.1] - 2026-03-25

### Added

- **http**: decompress gzip/deflate response bodies before storing
- **flamegraph**: add interactive flame graph tab
- **config**: add .well-known and favicon.ico to default skip_paths
- **storage**: add SQLite backend, blob store, and delete/clear APIs
- **ui**: add filters to profile list action bar and fix badge colors
- **http**: binary download, inline preview, and smart text formatting
- rename HTTP tab, add outbound HTTP list, extend MCP coverage
- **jobs**: add background job profiling for Sidekiq and ActiveJob
- add outbound HTTP request collector
- **mcp**: migrate to official Ruby SDK with HTTP transport
- implement dashboard UI with tab system and design system
- add AJAX and dump collectors, CORS middleware
- initial gem implementation

### Changed

- update installation to use GitLab Package Registry
- **assets**: serve all gem assets exclusively under /_profiler/
- update README with correct installation and remove dashboard README

### Fixed

- **gemspec**: fix metadata, file glob, and exclude source assets
- **gem**: switch to yarn build scripts and update dependencies
- **gem**: fix http_collector require, collectors config override, and API-only asset serving
- **gemspec**: exclude .gem build artifacts from files list
- **profiler**: improve memory tracking and profile deserialization
