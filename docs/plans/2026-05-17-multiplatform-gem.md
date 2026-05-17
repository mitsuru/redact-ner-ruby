# Multi-platform Precompiled Gem Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Distribute precompiled native-extension gems for 7 platforms (plus a source fallback) so users can `gem install redact_ner` without a Rust toolchain, published automatically via GitHub Actions + RubyGems Trusted Publishing.

**Architecture:** The gem is a Rust extension built with `rb-sys` + `magnus`. We add a `vendored` OpenSSL build to eliminate the transitive system-OpenSSL dependency pulled by `ort`'s default features, declare cross-compile targets in the Rakefile, and add a tag-triggered `release.yml` that cross-builds via `oxidize-rb/actions/cross-gem` (rb-sys-dock) and publishes through OIDC behind a protected GitHub Environment. ONNX Runtime is resolved at runtime (`load-dynamic`), so it is never bundled.

**Tech Stack:** Ruby 3.2–3.4 (precompiled; 4.0 via source fallback for now), Rust (magnus 0.8, ort 2.0-rc), rb-sys 0.9, rake-compiler, oxidize-rb GitHub Actions, rb-sys-dock, RubyGems Trusted Publishing (OIDC).

**Design reference:** `docs/plans/2026-05-17-multiplatform-gem-design.md`

**Target platforms:** `x86_64-linux`, `aarch64-linux`, `x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-darwin`, `arm64-darwin`, `x64-mingw-ucrt`
**Ruby ABIs per precompiled gem (initial release):** 3.2, 3.3, 3.4
**Ruby 4.0:** intentionally NOT in precompiled gems for 0.1.0 (cross-gem `ruby-versions` is a single comma-joined list with no per-ABI failure isolation; 4.0 is not yet GA). 4.0 users fall back to the source gem; precompiled 4.0 is a post-GA follow-up.

---

## Pre-flight: clean up the unpushed release tag

The local `Release v0.1.0` commit and `v0.1.0` tag predate this work. The tag must be recreated only after the workflow lands (Task 9), so remove it now to avoid an accidental premature release trigger.

**Step 1: Inspect current state**

Run: `git log --oneline -5 && git tag -l`
Expected: `v0.1.0` tag present; recent commits include `Release v0.1.0` and the design/plan-doc commits.

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
Expected: build succeeds; `Cargo.lock` updated.

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
  # 4.0 is allowed here so 4.0 users can still install via the source gem
  # until precompiled 4.0 binaries ship post-GA.
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

**Step 3: Verify cross-compile rake tasks are registered**

`rb_sys`/`rake-compiler` 1.3.x exposes cross-compile targets under the
`native:*` namespace (NOT a `gem:*` namespace) and gives them no description,
so they are hidden from `rake -T` — use `rake -AT`.

Run: `bundle exec rake -AT 2>/dev/null | grep -E '^rake (cross|native(:|$)|native:redact_ner:)' | head -10`
Expected: at least `rake cross`, `rake native`, and `rake native:redact_ner:x86_64-linux` are listed (proof `ext.cross_compile = true` + `ext.cross_platform` took effect; non-host platforms expand at invocation time with `RUBY_CC_VERSION`/rb-sys-dock).

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

Run (verify the exact flag against `bundle exec rb-sys-dock --help`; recent rb-sys-dock takes `--ruby-versions`):
```bash
bundle exec rb-sys-dock --platform x86_64-linux --ruby-versions 3.2,3.3,3.4 --build 2>&1 | tail -15
```
Expected: build completes; `pkg/redact_ner-0.1.0-x86_64-linux.gem` produced.

**Step 3: Verify the gem is platform-tagged and fat-packed**

Run:
```bash
gem spec pkg/redact_ner-0.1.0-x86_64-linux.gem platform 2>/dev/null && \
tar -xf pkg/redact_ner-0.1.0-x86_64-linux.gem -O data.tar.gz | tar -tzf - | grep -E 'lib/redact_ner/.*\.so' | sort
```
Expected: platform reads `x86_64-linux`; one `.so` per Ruby ABI (3.2/3.3/3.4) under `lib/redact_ner/`.

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

## Task 4: Add release.yml with publishing disabled (build + full smoke)

Wire the workflow but keep publishing off until CI is proven green. The smoke
gate covers all 7 platforms per the design (native GH runners where possible,
QEMU emulation for aarch64).

**Files:**
- Create: `.github/workflows/release.yml`

**Step 1: Create the workflow**

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
          ruby-versions: "3.2,3.3,3.4"
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

  # Native-runner smoke: install the precompiled gem and confirm it loads
  # with NO Rust toolchain present. (Setting up Rust is simply omitted.)
  smoke-native:
    needs: cross-gem
    strategy:
      fail-fast: false
      matrix:
        include:
          - platform: x86_64-linux
            os: ubuntu-latest
          - platform: x86_64-darwin
            os: macos-13
          - platform: arm64-darwin
            os: macos-14
          - platform: x64-mingw-ucrt
            os: windows-latest
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: cross-gem-${{ matrix.platform }}
          path: pkg
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"
      - name: Install and load (no Rust toolchain)
        shell: bash
        run: |
          gem install pkg/*.gem
          ruby -e 'require "redact_ner"; raise "load failed" unless RedactNer::Recognizer.respond_to?(:from_file); puts "ok #{RedactNer::VERSION}"'

  # Emulated smoke for musl + aarch64. musl runs in an Alpine container;
  # aarch64 runs an arm64 container under QEMU/binfmt. Verify the binfmt +
  # container recipe against current oxidize-rb examples while implementing.
  smoke-emulated:
    needs: cross-gem
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include:
          - platform: x86_64-linux-musl
            image: ruby:3.4-alpine
            arch: amd64
          - platform: aarch64-linux
            image: ruby:3.4-slim
            arch: arm64
          - platform: aarch64-linux-musl
            image: ruby:3.4-alpine
            arch: arm64
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: cross-gem-${{ matrix.platform }}
          path: pkg
      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3
      - name: Install and load in ${{ matrix.arch }} ${{ matrix.image }}
        run: |
          docker run --rm --platform linux/${{ matrix.arch }} \
            -v "$PWD/pkg:/pkg" -w /pkg ${{ matrix.image }} sh -c '
              gem install ./*.gem &&
              ruby -e '\''require "redact_ner"; raise "load failed" unless RedactNer::Recognizer.respond_to?(:from_file); puts "ok #{RedactNer::VERSION}"'\'''

  # publish: intentionally NOT defined yet. Added in Task 6 after CI is green
  # and the RubyGems pending Trusted Publisher + GitHub Environment exist.
```

**Step 2: Lint the workflow YAML locally**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); puts "yaml ok"'`
Expected: `yaml ok`.

**Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Add release workflow (cross-build + full smoke, publishing disabled)"
```

---

## Task 5: Prove the workflow green (temporary push trigger)

**GitHub constraint:** `workflow_dispatch` can only be triggered via API/`gh`
when the workflow file exists on the **default branch**. `release.yml` is only
on the feature branch, so `gh workflow run release.yml` returns
`HTTP 404: workflow release.yml not found on the default branch`. Workaround:
add a **temporary** `push` trigger scoped to the feature branch (push/tag/PR
triggers fire from the branch the file lives on; only `workflow_dispatch` /
`schedule` need the default branch). This temporary trigger MUST be removed
before Task 6 — see Step 5 (hard completion condition).

**Files:** `.github/workflows/release.yml` (temporary trigger add, then remove)

**Step 1: Add a temporary branch push trigger**

In `.github/workflows/release.yml`, change the `on:` block to also include:

```yaml
on:
  push:
    tags: ["v*"]
    branches: ["feature/multiplatform-gem"]   # TEMPORARY — remove in Step 5
  workflow_dispatch:
```

Commit: `git add .github/workflows/release.yml && git commit -m "TEMP: trigger release.yml on feature branch for CI validation"`

**Step 2: Push to trigger the run**

Run: `git push 2>&1 | tail -2` (branch already tracks origin)
Expected: push succeeds; the push event starts a `release.yml` run.

**Step 3: Watch the run to completion**

Run: `gh run watch "$(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status 2>&1 | tail -25`
Expected: all `cross-gem` (7), `source-gem`, `smoke-native` (4), and `smoke-emulated` (3) jobs succeed. Wall time ~30–60 min. If a vendored-OpenSSL cross-build fails for a non-x86_64-linux target (only x86_64-linux was validated locally in Task 3), debug per superpowers:systematic-debugging and iterate (commit fix → push → re-watch). Do NOT weaken the smoke gate to go green.

**Step 4: Confirm artifacts uploaded**

Run: `gh run view "$(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')" --json jobs -q '[.jobs[].name]'`
Expected: 7 cross jobs + source-gem + 4 smoke-native + 3 smoke-emulated, all listed.

**Step 5: Remove the temporary trigger (HARD completion condition)**

Revert the `on:` block to ONLY `push: tags: ["v*"]` + `workflow_dispatch`
(remove the `branches:` line). Commit:
`git commit -am "Revert temporary feature-branch CI trigger"` and `git push`.
Task 5 is NOT complete until `release.yml` on the feature branch no longer
contains the temporary `branches:` trigger. This prevents the workflow from
re-running on every feature-branch push after the branch merges to main.

---

## Task 6: Add the publish job (Trusted Publishing via OIDC)

Only after Task 5 is green AND Task 7 (GitHub Environment + RubyGems pending
Trusted Publisher) is confirmed.

**Files:**
- Modify: `.github/workflows/release.yml`

**Step 1: Append the publish job**

Add to `.github/workflows/release.yml`:

```yaml
  publish:
    needs: [cross-gem, source-gem, smoke-native, smoke-emulated]
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

**Step 3: Verify publish is tag-gated and Environment-bound**

Confirm both `if: startsWith(github.ref, 'refs/tags/v')` (so `workflow_dispatch`
never publishes) and `environment: rubygems` (so the protected Environment
gates the OIDC token) are present.

**Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Enable Trusted Publishing for tagged releases"
```

---

## Task 7: User prerequisites — GitHub Environment + RubyGems pending Trusted Publisher

**Two manual user actions; cannot be done in code. The Environment name must be
identical on both sides (`rubygems`). Block here until both are confirmed.**

### 7a. Create the GitHub Environment

Instruct the user: GitHub repo → **Settings → Environments → New environment**,
name it exactly `rubygems`. Optionally add a required reviewer / branch
protection so publishing requires manual approval (recommended for a publish
gate). No secrets are needed (OIDC is keyless).

### 7b. Register the RubyGems pending Trusted Publisher

Instruct the user: on https://rubygems.org while signed in (MFA), under
**Trusted Publishers → Register a new pending publisher**:

- Gem name: `redact_ner`
- Repository owner: `mitsuru`
- Repository name: `redact-ner-ruby`
- Workflow filename: `release.yml`
- Environment: `rubygems`  ← must exactly match the GitHub Environment from 7a

This reserves the gem name and authorizes the workflow's first publish without
an API key or OTP.

**Step 1: Confirm with the user**

Ask the user to confirm BOTH 7a and 7b are done. Do not proceed to Task 9 until
both are confirmed.

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
  and `x64-mingw-ucrt` (Ruby 3.2–3.4); installs without a Rust toolchain.
  A source gem remains available as a fallback for other platforms and for
  Ruby 4.0 (precompiled 4.0 binaries are a post-GA follow-up).
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

Only after Tasks 5 (green), 6 (publish job), and 7 (Environment + pending
publisher confirmed) are done, and the branch is merged to `main` (open a PR if
the team requires review; otherwise fast-forward `main`).

**Step 1: Land on main and tidy the release commit**

Merge the branch to `main`. The pre-existing `Release v0.1.0` commit predates
multi-platform work; reword it (or add a final `Release v0.1.0 (multi-platform)`
commit) so the release log reflects the shipped scope. Then:
Run: `git checkout main && git log --oneline -8`
Expected: all multi-platform commits on `main`; a clear release commit at/near HEAD.

**Step 2: Create the annotated tag**

Run: `git tag -a v0.1.0 -m "redact_ner 0.1.0 (multi-platform)"`
Expected: tag created.

**Step 3: Push main and the tag**

Run: `git push origin main && git push origin v0.1.0`
Expected: tag push triggers the `release.yml` workflow.

**Step 4: Watch the release run and confirm publish**

Run: `gh run watch "$(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status 2>&1 | tail -25`
Expected: all jobs incl. `publish` succeed (publish waits for Environment
approval if a reviewer was configured in 7a).

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
- Ruby 4.0 is deliberately excluded from precompiled gems for 0.1.0. Do not add
  it back to `ruby-versions` to "be complete" — it has no per-ABI failure
  isolation in cross-gem and is not GA. It is a tracked follow-up.
- The GitHub Environment name (`rubygems`) MUST be byte-identical in
  `release.yml`, the GitHub Environment, and the RubyGems Trusted Publisher
  registration, or publish fails / the job won't start.
- `smoke-emulated` (musl + aarch64 via QEMU) is the highest-effort leg; verify
  the `docker/setup-qemu-action` + container recipe against current oxidize-rb
  examples rather than assuming the snippet is final.
- Verify exact action inputs (`oxidize-rb/actions/cross-gem`,
  `rubygems/configure-rubygems-credentials`) and the `rb-sys-dock` flags
  against their current docs at implementation time; pin major versions.
- Tasks 3 and 5 require Docker / a pushed branch + `gh`; if the environment
  lacks them, stop and surface it rather than skipping verification.
```
