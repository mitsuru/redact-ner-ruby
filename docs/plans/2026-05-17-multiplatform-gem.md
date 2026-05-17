# Multi-platform Precompiled Gem Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Distribute precompiled native-extension gems for 7 platforms (plus a source fallback) so users can `gem install redact_ner` without a Rust toolchain, published automatically via GitHub Actions + RubyGems Trusted Publishing.

**Architecture:** The gem is a Rust extension built with `rb-sys` + `magnus`. We add a `vendored` OpenSSL build to eliminate the transitive system-OpenSSL dependency pulled by `ort`'s default features, declare cross-compile targets in the Rakefile, and add a tag-triggered `release.yml` that cross-builds via `oxidize-rb/actions/cross-gem` (rb-sys-dock) and publishes through OIDC. ONNX Runtime is resolved at runtime (`load-dynamic`), so it is never bundled.

**Tech Stack:** Ruby 3.2–4.0, Rust (magnus 0.8, ort 2.0-rc), rb-sys 0.9, rake-compiler, oxidize-rb GitHub Actions, rb-sys-dock, RubyGems Trusted Publishing (OIDC).

**Design reference:** `docs/plans/2026-05-17-multiplatform-gem-design.md`

**Target platforms:** `x86_64-linux`, `aarch64-linux`, `x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-darwin`, `arm64-darwin`, `x64-mingw-ucrt`
**Ruby ABIs per gem:** 3.2, 3.3, 3.4, 4.0

---

## Pre-flight: clean up the unpushed release tag

The local `Release v0.1.0` commit and `v0.1.0` tag predate this work. The tag must be recreated only after the workflow lands (Task 9), so remove it now to avoid an accidental premature release trigger.

**Step 1: Inspect current state**

Run: `git log --oneline -3 && git tag -l`
Expected: `v0.1.0` tag present; recent commits include `Release v0.1.0` and the design-doc commits.

**Step 2: Delete the local tag**

Run: `git tag -d v0.1.0`
Expected: `Deleted tag 'v0.1.0'`

**Step 3: Confirm the tag is gone and not on the remote**

Run: `git tag -l && git ls-remote --tags origin | grep v0.1.0 || echo "not on remote"`
Expected: no `v0.1.0` line; `not on remote`.

No commit (tag deletion only).

---

## Task 1: Add vendored OpenSSL to the Rust extension

**Files:**
- Modify: `ext/redact_ner/Cargo.toml`
- Regenerate: `Cargo.lock`

**Step 1: Add the dependency**

Add to `ext/redact_ner/Cargo.toml` under `[dependencies]`:

```toml
# Force a vendored, statically-linked OpenSSL so cross-compilation does not
# depend on a per-target system OpenSSL. openssl-sys is pulled transitively
# via ort -> ort-sys -> ureq -> native-tls; we only pin its build mode here.
openssl-sys = { version = "0.9", features = ["vendored"] }
```

**Step 2: Regenerate the lockfile**

Run: `cargo build --manifest-path ext/redact_ner/Cargo.toml 2>&1 | tail -5`
Expected: build succeeds; `Cargo.lock` updated (openssl-sys now reflects vendored build via the `openssl-src` crate appearing in `Cargo.lock`).

**Step 3: Verify openssl-src entered the lockfile**

Run: `grep -A2 'name = "openssl-src"' Cargo.lock | head -3`
Expected: an `openssl-src` package entry exists (proof the vendored path is wired).

**Step 4: Local native build + load smoke test**

Run:
```bash
bundle exec rake compile 2>&1 | tail -3 && \
ruby -Ilib -e 'require "redact_ner"; puts RedactNer::VERSION; puts RedactNer::Recognizer.respond_to?(:from_file)'
```
Expected: compile succeeds; prints `0.1.0` then `true`.

**Step 5: Commit**

```bash
git add ext/redact_ner/Cargo.toml Cargo.lock
git commit -m "Vendor OpenSSL to decouple cross-compile from system libssl"
```

---

## Task 2: gemspec Ruby upper bound + Rakefile cross-platform declaration

**Files:**
- Modify: `redact_ner.gemspec`
- Modify: `Rakefile`

**Step 1: Add the required_ruby_version upper bound**

In `redact_ner.gemspec`, replace the `required_ruby_version` line with:

```ruby
  # Lower bound matches the dev-time onnxruntime gem. Upper bound is required
  # for ABI-fixed precompiled gems; raise it as new Ruby ABIs are supported.
  spec.required_ruby_version = [">= 3.2.0", "< 4.1"]
```

**Step 2: Declare cross-compile targets in the Rakefile**

In `Rakefile`, replace the `RbSys::ExtensionTask.new` block with:

```ruby
CROSS_PLATFORMS = %w[
  x86_64-linux
  aarch64-linux
  x86_64-linux-musl
  aarch64-linux-musl
  x86_64-darwin
  arm64-darwin
  x64-mingw-ucrt
].freeze

RbSys::ExtensionTask.new("redact_ner", GEMSPEC) do |ext|
  ext.lib_dir = "lib/redact_ner"
  ext.cross_compile = true
  ext.cross_platform = CROSS_PLATFORMS
end
```

**Step 3: Verify rake tasks are generated**

Run: `bundle exec rake -T 2>/dev/null | grep -E 'native|gem:' | head -10`
Expected: `native:*` and `gem:*` tasks listed for the declared platforms (e.g. `gem:x86_64-linux`).

**Step 4: Verify gemspec still loads and builds**

Run: `gem build redact_ner.gemspec -o /tmp/rn-src.gem 2>&1 | tail -2`
Expected: `Successfully built RubyGem` (the homepage_uri/source_code_uri WARNING is benign and expected).

**Step 5: Commit**

```bash
git add redact_ner.gemspec Rakefile
git commit -m "Declare cross-compile platforms and pin Ruby ABI upper bound"
```

---

## Task 3: Local rb-sys-dock cross-build of one platform

Validates the vendored-OpenSSL cross-build before wiring CI. `x86_64-linux` is the cheapest representative target.

**Files:** none (verification only)

**Step 1: Confirm Docker is available**

Run: `docker version --format '{{.Server.Version}}' 2>&1 | tail -1`
Expected: a Docker server version string. If Docker is unavailable, STOP and report — Task 3 must be done where Docker exists (or deferred to CI in Task 5 with explicit user sign-off).

**Step 2: Cross-build the gem for x86_64-linux**

Run:
```bash
RUBY_CC_VERSION="3.2.0:3.3.0:3.4.0:4.0.0" \
bundle exec rb-sys-dock --platform x86_64-linux --build 2>&1 | tail -15
```
Expected: build completes; a `pkg/redact_ner-0.1.0-x86_64-linux.gem` is produced.

**Step 3: Verify the gem is platform-tagged and fat-packed**

Run:
```bash
gem spec pkg/redact_ner-0.1.0-x86_64-linux.gem platform 2>/dev/null && \
tar -xf pkg/redact_ner-0.1.0-x86_64-linux.gem -O data.tar.gz | tar -tzf - | grep -E 'lib/redact_ner/.*\.so' | sort
```
Expected: platform reads `x86_64-linux`; one `.so` per Ruby ABI (3.2/3.3/3.4[/4.0]) under `lib/redact_ner/`.

**Step 4: Install + load smoke test (clean GEM_HOME)**

Run:
```bash
rm -rf /tmp/xgem && GEM_HOME=/tmp/xgem GEM_PATH=/tmp/xgem \
  gem install pkg/redact_ner-0.1.0-x86_64-linux.gem 2>&1 | tail -2 && \
GEM_HOME=/tmp/xgem GEM_PATH=/tmp/xgem \
  ruby -e 'gem "redact_ner"; require "redact_ner"; puts RedactNer::Recognizer.respond_to?(:from_file)'
```
Expected: install reports `redact_ner-0.1.0-x86_64-linux`; prints `true`. No Rust toolchain invoked (precompiled).

No commit (verification only; `pkg/` is gitignored).

---

## Task 4: Add release.yml with publishing disabled (build-only)

Wire the workflow but keep publishing off until CI is proven green.

**Files:**
- Create: `.github/workflows/release.yml`

**Step 1: Create the workflow (build + smoke only, no publish)**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ["v*"]
  workflow_dispatch:

jobs:
  cross-gem:
    name: cross ${{ matrix.platform }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        platform:
          - x86_64-linux
          - aarch64-linux
          - x86_64-linux-musl
          - aarch64-linux-musl
          - x86_64-darwin
          - arm64-darwin
          - x64-mingw-ucrt
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"
      - uses: oxidize-rb/actions/cross-gem@v1
        id: cross-gem
        with:
          platform: ${{ matrix.platform }}
          ruby-versions: "3.2,3.3,3.4,4.0"
      - uses: actions/upload-artifact@v4
        with:
          name: cross-gem-${{ matrix.platform }}
          path: pkg/*-${{ matrix.platform }}.gem
          if-no-files-found: error

  source-gem:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: oxidize-rb/actions/setup-ruby-and-rust@v1
        with:
          ruby-version: "3.4"
          rustup-toolchain: stable
          bundler-cache: true
      - run: gem build redact_ner.gemspec -o pkg/redact_ner-source.gem
      - uses: actions/upload-artifact@v4
        with:
          name: source-gem
          path: pkg/redact_ner-source.gem
          if-no-files-found: error

  smoke:
    name: smoke ${{ matrix.platform }}
    needs: cross-gem
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        platform: [x86_64-linux, x86_64-linux-musl]
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: cross-gem-${{ matrix.platform }}
          path: pkg
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"
      - name: Install and load (no Rust toolchain)
        run: |
          gem install pkg/*.gem
          ruby -e 'require "redact_ner"; raise "load failed" unless RedactNer::Recognizer.respond_to?(:from_file); puts "ok #{RedactNer::VERSION}"'

  # publish: intentionally NOT defined yet. Added in Task 6 after CI is green
  # and the RubyGems pending Trusted Publisher is registered.
```

**Step 2: Lint the workflow YAML locally**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); puts "yaml ok"'`
Expected: `yaml ok`.

**Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Add release workflow (cross-build + smoke, publishing disabled)"
```

---

## Task 5: Prove the workflow green via workflow_dispatch

**Files:** none (CI verification)

**Step 1: Push the branch**

Run: `git push -u origin HEAD 2>&1 | tail -2`
Expected: branch pushed.

**Step 2: Trigger the workflow manually**

Run: `gh workflow run release.yml --ref "$(git branch --show-current)" 2>&1 | tail -1`
Expected: workflow run queued.

**Step 3: Watch the run to completion**

Run: `gh run watch "$(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status 2>&1 | tail -20`
Expected: all `cross-gem` (7), `source-gem`, and `smoke` jobs succeed. If the Ruby 4.0 leg of any cross-gem job fails due to toolchain gaps, STOP and consult the user about applying `continue-on-error` to the 4.0 portion per the design's risk table.

**Step 4: Confirm artifacts uploaded**

Run: `gh run view "$(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')" --json jobs -q '[.jobs[].name]'`
Expected: 7 cross jobs + source-gem + 2 smoke jobs, all listed.

No commit (CI verification only).

---

## Task 6: Add the publish job (Trusted Publishing via OIDC)

Only after Task 5 is green. Requires the user to have completed the RubyGems pending Trusted Publisher registration first (see "User prerequisite" below).

**Files:**
- Modify: `.github/workflows/release.yml`

**Step 1: Append the publish job**

Add to `.github/workflows/release.yml`:

```yaml
  publish:
    needs: [cross-gem, source-gem, smoke]
    if: startsWith(github.ref, 'refs/tags/v')
    runs-on: ubuntu-latest
    environment: rubygems
    permissions:
      contents: write
      id-token: write
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"
      - uses: actions/download-artifact@v4
        with:
          path: dist
          merge-multiple: true
      - name: Configure RubyGems Trusted Publishing (OIDC)
        uses: rubygems/configure-rubygems-credentials@v1
      - name: Push all gems
        run: |
          shopt -s nullglob
          for g in dist/*.gem; do
            echo "Pushing $g"
            gem push "$g"
          done
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: dist/*.gem
          generate_release_notes: true
```

**Step 2: Lint YAML**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); puts "yaml ok"'`
Expected: `yaml ok`.

**Step 3: Verify publish is tag-gated**

Confirm `if: startsWith(github.ref, 'refs/tags/v')` is present so `workflow_dispatch` runs never publish.

**Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Enable Trusted Publishing for tagged releases"
```

---

## Task 7: User prerequisite — RubyGems pending Trusted Publisher

**This is a manual user action; it cannot be done in code. Block here until confirmed.**

Instruct the user to, on https://rubygems.org while signed in (MFA), under
**Trusted Publishers → Register a new pending publisher**:

- Gem name: `redact_ner`
- Repository owner: `mitsuru`
- Repository name: `redact-ner-ruby`
- Workflow filename: `release.yml`
- Environment: `rubygems`

This reserves the gem name and authorizes the workflow's first publish without
an API key or OTP.

**Step 1: Confirm with the user**

Ask the user to confirm the pending Trusted Publisher is registered. Do not
proceed to Task 9 until confirmed.

No commit.

---

## Task 8: CHANGELOG note for multi-platform support

**Files:**
- Modify: `CHANGELOG.md`

**Step 1: Add a bullet under the `## [0.1.0] - 2026-05-17` Added section**

Append to the existing `### Added` list in `CHANGELOG.md`:

```markdown
- Precompiled native gems for `x86_64-linux`, `aarch64-linux`,
  `x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-darwin`, `arm64-darwin`,
  and `x64-mingw-ucrt` (Ruby 3.2–4.0); installs without a Rust toolchain. A
  source gem remains available as a fallback for other platforms.
```

**Step 2: Verify it renders in the gem build**

Run: `gem build redact_ner.gemspec -o /tmp/rn.gem 2>&1 | tail -1 && tar -xf /tmp/rn.gem -O data.tar.gz | tar -xzO ./CHANGELOG.md 2>/dev/null | grep -c "Precompiled native gems"`
Expected: `Successfully built RubyGem`; grep count `1`.

**Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "Document multi-platform precompiled gems in CHANGELOG"
```

---

## Task 9: Tag and ship 0.1.0

Only after Tasks 5 (green), 6 (publish job), and 7 (pending publisher confirmed) are done, and the branch is merged to `main` (open a PR if the team requires review; otherwise fast-forward `main`).

**Step 1: Ensure work is on main**

Run: `git checkout main && git merge --ff-only -` (or merge the PR), then `git log --oneline -5`
Expected: all multi-platform commits on `main`.

**Step 2: Create the annotated tag**

Run: `git tag -a v0.1.0 -m "redact_ner 0.1.0 (multi-platform)"`
Expected: tag created.

**Step 3: Push main and the tag**

Run: `git push origin main && git push origin v0.1.0`
Expected: tag push triggers the `release.yml` workflow.

**Step 4: Watch the release run and confirm publish**

Run: `gh run watch "$(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status 2>&1 | tail -20`
Expected: all jobs incl. `publish` succeed.

**Step 5: Verify on RubyGems**

Run: `sleep 30; curl -s https://rubygems.org/api/v1/versions/redact_ner.json | ruby -rjson -e 'puts JSON.parse(STDIN.read).map { |v| v["platform"] }.sort.uniq'`
Expected: lists `ruby` plus the 7 platform strings.

**Step 6: Post-release manual verification**

On a representative machine: `gem install redact_ner && ruby -e 'require "redact_ner"; puts RedactNer::VERSION'`
Expected: `0.1.0`, no Rust toolchain build.

No further commit (release complete).

---

## Notes for the executor

- `pkg/`, `*.gem`, `/tmp/*` are gitignored — never `git add` build artifacts.
- The gem-build WARNING about `homepage_uri`/`source_code_uri` being identical
  is benign; do not "fix" it.
- ONNX Runtime is intentionally NOT bundled (`ort` `load-dynamic`); smoke tests
  only assert load + API presence, never inference.
- Ruby 4.0 cross-build is the highest-risk leg; if it blocks the matrix, apply
  `continue-on-error` to just that ABI and consult the user (design risk table).
- Tasks 3 and 5 require Docker / a pushed branch + `gh` respectively; if the
  environment lacks them, stop and surface it rather than skipping verification.
