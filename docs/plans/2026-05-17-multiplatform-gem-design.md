# Multi-platform Precompiled Gem — Design

Date: 2026-05-17
Status: Approved (brainstorming complete; ready for implementation planning)

## Goal

Allow users to `gem install redact_ner` **without a Rust toolchain** by
distributing precompiled native-extension gems per platform, with a source gem
as fallback for uncovered platforms / future Ruby versions.

## Scope

### Distribution artifacts (6 gems total)

> **Revised (option B, 2026-05-17):** macOS dropped from precompiled. Vendored
> OpenSSL cannot cross-build for `*-darwin` via `rb-sys-dock`/osxcross
> (`ranlib: libcrypto.a.new: malformed archive`), proven version- and
> image-independent. `openssl-sys` is unavoidably forced by `redact-ner` 0.8.3 +
> `ort` 2.0.0-rc.12 defaults (cannot be dropped via Cargo feature unification).
> macOS users install the source gem (native Apple cctools toolchain does not
> hit the osxcross bug).

Precompiled platform gems (each fat-packs Ruby 3.2 / 3.3 / 3.4 `.so`; Ruby 4.0
is excluded from precompiled gems for 0.1.0 — see "Ruby 4.0" below):

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-linux-musl`
- `aarch64-linux-musl`
- `x64-mingw-ucrt`

Plus 1 platform-generic **source gem** (built from source via the Rust
toolchain) for any platform / Ruby version not covered above — notably
**macOS** (`*-darwin`), which needs a Rust toolchain + Xcode CLT at install.

### Out of scope (YAGNI)

- FreeBSD / other-arch dedicated binaries (covered by source gem).
- Real model inference in CI verification (requires ONNX Runtime + model files).
- Bundling ONNX Runtime into precompiled gems — unnecessary because `ort` uses
  the `load-dynamic` feature (runtime `ORT_DYLIB_PATH` resolution), and bundling
  would be inappropriate for size/licensing reasons.

## Key technical risk: transitive OpenSSL dependency

Dependency chain:

```
redact_ner(ext) → redact-ner 0.8.3 (default) → ort (default) → ort "tls-native"
  → ort-sys "tls-native" → ureq "native-tls" → native-tls → openssl-sys
```

`ort`'s default features pull `ureq` + `native-tls` + `openssl-sys` (links
system OpenSSL) for build-time ONNX Runtime binary download. This gem resolves
ONNX Runtime at runtime via `load-dynamic`, so that download path is logically
unneeded, but `redact-ner` 0.8.3 (external crates.io crate) enables it via
default features.

### Mitigation (decided): vendored OpenSSL

Add to `ext/redact_ner/Cargo.toml`:

```toml
openssl-sys = { version = "0.9", features = ["vendored"] }
```

OpenSSL is then statically compiled from source per target at build time,
removing the system-OpenSSL dependency. `rb-sys-dock` cross-compile containers
ship the per-target C toolchain needed for the vendored build.

Alternative considered and deferred: switch `ort`/`ureq` to a pure-Rust TLS
(rustls) or fully disable the download feature via `redact-ner` features. Not
chosen as primary because `redact-ner` 0.8.3 is an external crate whose feature
controllability is uncertain; if feasible during implementation, this is a
cleaner follow-up.

## Build tooling & local development

- `Rakefile` already uses `RbSys::ExtensionTask`, which provides
  `native:*` / `gem:*` cross-build tasks. Add explicit cross-platform
  declaration only; minimal change.
- `redact_ner.gemspec`:
  - Set `required_ruby_version` upper bound (e.g. `>= 3.2.0, < 4.1`) — required
    for ABI-fixed precompiled gems (rb-sys recommendation).
  - Keep `rubygems_mfa_required = "true"` (compatible with Trusted Publishing).
  - Source gem keeps `spec.extensions`; rb-sys auto-clears extensions for
    platform gems and ships the compiled `.so`.
- Document `rb-sys-dock` usage in Rakefile/README so developers can reproduce a
  specific platform locally (do not rely on CI alone).
- `vendored` feature changes `Cargo.lock`; regenerate via `cargo build`, keep
  `Cargo.lock` shipped in the gem for reproducibility.
- Existing local `Release v0.1.0` commit + `v0.1.0` tag are unpushed. Fold
  multi-platform work into this release; **re-create the `v0.1.0` tag** after
  the workflow lands (tag push triggers release; do not tag until ready).

## GitHub Actions release workflow

New `.github/workflows/release.yml`; keep existing `ci.yml` (tests) unchanged.

- Trigger: `push: tags: ['v*']` + `workflow_dispatch`.
- Jobs:
  1. `cross-gem` (matrix, 5 platforms in parallel) — `oxidize-rb/actions/cross-gem@v1`,
     `ruby-versions: "3.2,3.3,3.4"`, builds via `rb-sys-dock` with vendored
     OpenSSL; uploads `.gem` artifacts.
  2. `source-gem` — `gem build redact_ner.gemspec`; uploads artifact.
  3. `smoke-native` + `smoke-emulated` — full 5-platform load gate (see
     Verification).
  4. `publish` (needs all above) — download all artifacts, **RubyGems Trusted
     Publishing** via OIDC (`rubygems/configure-rubygems-credentials` + `gem
     push`), `permissions: id-token: write`, behind a protected GitHub
     Environment `rubygems`, push all 6 gems, create a GitHub Release with
     `.gem` assets and generated notes.

### Ruby 4.0

Excluded from precompiled gems for 0.1.0. `oxidize-rb/actions/cross-gem`'s
`ruby-versions` is a single comma-joined list per job with no per-ABI failure
isolation, and 4.0 is not yet GA. 4.0 users install via the source gem
(`required_ruby_version` keeps `< 4.1`). Precompiled 4.0 is a tracked
post-GA follow-up.

### User prerequisites (cannot be done in code)

1. **Create a GitHub Environment** named exactly `rubygems` (repo Settings →
   Environments), optionally with a required reviewer as a publish-approval
   gate. No secrets needed (OIDC is keyless).
2. **Register a RubyGems pending Trusted Publisher** for gem `redact_ner` bound
   to repo `mitsuru/redact-ner-ruby`, workflow `release.yml`, environment
   `rubygems` (must byte-match the GitHub Environment). Because the gem is not
   yet published, this **pending** registration also reserves the gem name.

## Verification strategy

1. **Build-time (per cross-build job):** rb-sys-dock build success (incl.
   vendored OpenSSL link); assert resulting `Gem::Platform` and that the gem
   contains `.so` for all 4 Ruby versions.
2. **Install/smoke (CI, before publish — mandatory gate):** for each precompiled
   gem, `gem install` → `require "redact_ner"` →
   `RedactNer::Recognizer.respond_to?(:from_file)`. Linux musl/aarch64 via
   QEMU emulation; Windows on a native runner (no macOS — source gem only). Confirm `from_file` returns
   an object with `ORT_DYLIB_PATH` unset (README graceful-fallback contract).
   Real inference is out of scope.
3. **Source gem fallback:** install source gem with Rust toolchain present;
   confirm build + load.
4. **Post-release manual (user):** install on 1–2 representative platforms and
   verify; document steps in README/CHANGELOG.

Existing `test/` minitest stays in `ci.yml` (source build + tests). Precompiled
path covered by load smoke test only; no duplication.

## Rollout order

1. Add `openssl-sys` vendored to `ext/redact_ner/Cargo.toml`; `cargo build` to
   update `Cargo.lock`; local native build + `require` smoke test.
2. gemspec `required_ruby_version` upper bound; Rakefile cross-platform decl.
3. Local `rb-sys-dock` cross-build of one platform (e.g. `x86_64-linux`).
4. Add `release.yml` with publish step disabled (artifact build only).
5. `workflow_dispatch` run: all 5 platforms + source build & load smoke green.
6. User creates GitHub Environment `rubygems` and registers the pending
   Trusted Publisher (reserve `redact_ner` + bind repo/workflow/environment).
7. Enable publish step in `release.yml`.
8. Append multi-platform note to CHANGELOG; re-create `v0.1.0` tag and push →
   workflow auto-publishes all 6 gems.
9. Post-release `gem install` verification on representative platforms.

Version note: discard/recreate the local `Release v0.1.0` commit + tag; ship
0.1.0 as the first public release including multi-platform support (no version
bump since unpublished).

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Vendored OpenSSL fails to build for a cross target | rb-sys-dock per-target C toolchain; verify early in step 3 |
| Ruby 4.0 not GA / no per-ABI isolation in cross-gem | Exclude 4.0 from precompiled 0.1.0; 4.0 served by source gem; precompiled 4.0 is a post-GA follow-up |
| First publish fails: Trusted Publisher unregistered | Pending-publisher registration is an explicit prerequisite (step 6) before enabling publish |
| Environment name mismatch (workflow / GitHub Env / RubyGems) blocks or fails publish | Single canonical name `rubygems`; byte-identical in all three; created as an explicit prerequisite |
| musl / aarch64 build divergence | Smoke gate includes both musl targets and both aarch64 targets (QEMU) before publish |
