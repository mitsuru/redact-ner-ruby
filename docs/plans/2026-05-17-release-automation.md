# Release Automation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automate release prep (version bump, CHANGELOG roll, draft GitHub Release) via a manually-dispatched workflow that opens a Release PR; merging the PR auto-tags and the existing `release.yml` publishes.

**Architecture:** Two new workflows + one edit. `release-prep.yml` (workflow_dispatch, `bump` input) computes the next version from `lib/redact_ner/version.rb`, writes it, generates notes via the GitHub generate-notes API, rolls `CHANGELOG.md`, pushes a `release/vX.Y.Z` branch, opens a labelled Release PR, and creates a **draft** GitHub Release (no git tag yet). `release-tag-on-merge.yml` fires when that PR merges to `main`, creates+pushes the annotated `vX.Y.Z` tag. The existing `release.yml` (unchanged trigger) then builds/publishes the 6 gems; its GitHub-Release step is changed to **un-draft the existing draft release and attach assets** (preserving the reviewed notes) instead of creating a fresh one.

**Tech Stack:** GitHub Actions, `gh` CLI, GitHub generate-notes REST API, Ruby (version-bump helper + minitest), existing rb-sys/Trusted-Publishing `release.yml`.

**Issue:** `redact-ner-ruby-rvk` (design + acceptance live in the beads issue, not docs/plans).

**Repo facts the implementer needs:**
- Version source: `lib/redact_ner/version.rb` → `module RedactNer; VERSION = "X.Y.Z"; end`.
- `CHANGELOG.md`: Keep-a-Changelog style. Has `## [Unreleased]`, dated `## [X.Y.Z] - DATE` sections, and bottom link refs `[Unreleased]: <repo>/compare/vLATEST...HEAD` and `[X.Y.Z]: <repo>/releases/tag/vX.Y.Z`.
- Existing `.github/workflows/release.yml`: trigger `push: tags: ["v*"]` + `workflow_dispatch:`; jobs `cross-gem` (5 platforms), `source-gem`, `smoke-native` (2), `smoke-emulated` (3), `publish` (`if: startsWith(github.ref,'refs/tags/v')`, `environment: rubygems`, OIDC). The publish job currently ends with a `softprops/action-gh-release@v2` step (`generate_release_notes: true`, `files: dist/*.gem`).
- Repo: `mitsuru/redact-ner-ruby`. Tests: `bundle exec rake test` (minitest, `test/`).
- Build artifacts (`pkg/`, `*.gem`, `tmp/`, `.worktrees/`) are gitignored — never `git add` them.

---

## Task 1: Version-bump helper + local tests

**Files:**
- Create: `script/next_version.rb`
- Create: `test/test_next_version.rb`

**Step 1: Write the failing test**

`test/test_next_version.rb`:
```ruby
# frozen_string_literal: true
require "minitest/autorun"

class TestNextVersion < Minitest::Test
  def nv(cur, bump)
    `ruby #{File.expand_path("../script/next_version.rb", __dir__)} #{cur} #{bump}`.strip
  end

  def test_patch; assert_equal "0.1.2", nv("0.1.1", "patch"); end
  def test_minor; assert_equal "0.2.0", nv("0.1.1", "minor"); end
  def test_major; assert_equal "1.0.0", nv("0.1.1", "major"); end
  def test_patch_rollover; assert_equal "0.2.10", nv("0.2.9", "patch"); end
  def test_invalid_bump
    out = `ruby #{File.expand_path("../script/next_version.rb", __dir__)} 0.1.1 nope 2>&1`
    refute_equal 0, $?.exitstatus
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/test_next_version.rb 2>&1 | tail -5`
Expected: FAIL (script does not exist → non-zero / errors).

**Step 3: Write minimal implementation**

`script/next_version.rb`:
```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
# Usage: next_version.rb <current X.Y.Z> <patch|minor|major>  -> prints next version
cur, bump = ARGV
abort "usage: next_version.rb X.Y.Z patch|minor|major" unless cur && bump
m = cur.match(/\A(\d+)\.(\d+)\.(\d+)\z/)
abort "invalid version: #{cur}" unless m
major, minor, patch = m.captures.map(&:to_i)
case bump
when "major" then major += 1; minor = 0; patch = 0
when "minor" then minor += 1; patch = 0
when "patch" then patch += 1
else abort "invalid bump: #{bump}"
end
puts "#{major}.#{minor}.#{patch}"
```

**Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/test_next_version.rb 2>&1 | tail -3`
Expected: `5 runs, ... 0 failures, 0 errors`.

**Step 5: Confirm full suite still green**

Run: `bundle exec rake test 2>&1 | tail -3`
Expected: all runs, 0 failures (the existing 7 + the new file's 5; rake globs `test/test_*.rb`).

**Step 6: Commit**

```bash
git add script/next_version.rb test/test_next_version.rb
git commit -m "Add version-bump helper with tests"
```

---

## Task 2: `release-prep.yml` — bump + CHANGELOG + Release PR + draft Release

> **Superseded (auth) by `redact-ner-ruby-a2c` / `docs/plans/2026-05-17-release-app-token.md`:**
> the live `release-prep.yml` / `release-tag-on-merge.yml` no longer use
> `GITHUB_TOKEN`/`RELEASE_PAT` or apply a `release` label. They mint a
> dedicated GitHub App installation token (`actions/create-github-app-token@v1`,
> secrets `RELEASE_APP_ID`/`RELEASE_APP_PRIVATE_KEY`), use an App-bot git
> identity, and `release-tag-on-merge` triggers on the `release/v*` head ref.
> The embedded YAML below reflects this plan's original (PR #1) implementation
> and is kept for history; trust the actual workflow files + the a2c plan for
> the current auth/label behavior.

**Files:**
- Create: `.github/workflows/release-prep.yml`

**Step 1: Create the workflow**

`.github/workflows/release-prep.yml`:
```yaml
name: Release Prep

on:
  workflow_dispatch:
    inputs:
      bump:
        description: "Semver bump level"
        required: true
        type: choice
        options: [patch, minor, major]

permissions:
  contents: write
  pull-requests: write

jobs:
  prep:
    # Only cut releases from main. workflow_dispatch lets the operator pick any
    # branch; without this guard, dispatching from a feature branch would open
    # a Release PR containing that branch's divergence.
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"

      - name: Compute next version
        id: ver
        run: |
          cur=$(ruby -r ./lib/redact_ner/version -e 'print RedactNer::VERSION')
          next=$(ruby script/next_version.rb "$cur" "${{ inputs.bump }}")
          echo "cur=$cur"   >> "$GITHUB_OUTPUT"
          echo "next=$next" >> "$GITHUB_OUTPUT"
          echo "tag=v$next"  >> "$GITHUB_OUTPUT"
          echo "date=$(date -u +%F)" >> "$GITHUB_OUTPUT"

      - name: Guard against duplicate cut
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          tag="${{ steps.ver.outputs.tag }}"
          if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then echo "tag $tag exists"; exit 1; fi
          if git ls-remote --exit-code --heads origin "release/$tag" >/dev/null 2>&1; then echo "branch release/$tag exists"; exit 1; fi
          if gh release view "$tag" >/dev/null 2>&1; then echo "release $tag exists"; exit 1; fi

      - name: Generate release notes
        id: notes
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          prev=$(git tag -l 'v*' --sort=-v:refname | head -1)
          args=(-f tag_name="${{ steps.ver.outputs.tag }}" -f target_commitish=main)
          [ -n "$prev" ] && args+=(-f previous_tag_name="$prev")
          body=$(gh api repos/${{ github.repository }}/releases/generate-notes "${args[@]}" --jq .body)
          [ -z "$body" ] && body="No notable changes."
          # Random delimiter: generated notes ingest arbitrary commit/PR text;
          # a fixed delimiter could collide with a notes line and silently
          # truncate the value.
          delim="RELNOTES_$(openssl rand -hex 16)"
          {
            echo "body<<$delim"
            echo "$body"
            echo "$delim"
          } >> "$GITHUB_OUTPUT"

      - name: Bump version.rb
        run: |
          sed -i 's/VERSION = ".*"/VERSION = "${{ steps.ver.outputs.next }}"/' lib/redact_ner/version.rb
          ruby -r ./lib/redact_ner/version -e 'abort "bump failed" unless RedactNer::VERSION == "${{ steps.ver.outputs.next }}"'

      - name: Roll CHANGELOG
        env:
          NOTES: ${{ steps.notes.outputs.body }}
          NEXT: ${{ steps.ver.outputs.next }}
          DATE: ${{ steps.ver.outputs.date }}
          REPO: ${{ github.repository }}
        run: |
          ruby - <<'RUBY'
          path = "CHANGELOG.md"
          c = File.read(path)
          notes = ENV["NOTES"]; ver = ENV["NEXT"]; date = ENV["DATE"]; repo = ENV["REPO"]
          section = "## [#{ver}] - #{date}\n\n#{notes}\n"
          # Insert the new section after "## [Unreleased]" (keep Unreleased empty).
          # Block form: replacement string must NOT interpret \1/\& from notes.
          c = c.sub(/## \[Unreleased\]\n/) { |m| "#{m}\n#{section}\n" }
          # Bottom link refs.
          before = c.dup
          c = c.sub(%r{^\[Unreleased\]:.*$}, "[Unreleased]: https://github.com/#{repo}/compare/v#{ver}...HEAD")
          abort "CHANGELOG missing [Unreleased]: link ref" if c == before
          unless c.include?("\n[#{ver}]: ")
            c = c.rstrip + "\n[#{ver}]: https://github.com/#{repo}/releases/tag/v#{ver}\n"
          end
          File.write(path, c)
          RUBY
          grep -q "## \[${{ steps.ver.outputs.next }}\] - ${{ steps.ver.outputs.date }}" CHANGELOG.md
          grep -q "^\[${{ steps.ver.outputs.next }}\]: " CHANGELOG.md
          grep -q "^\[Unreleased\]: .*/compare/v${{ steps.ver.outputs.next }}\.\.\.HEAD" CHANGELOG.md

      - name: Create branch, commit, open Release PR
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          tag="${{ steps.ver.outputs.tag }}"
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git switch -c "release/$tag"
          git add lib/redact_ner/version.rb CHANGELOG.md
          git commit -m "Release $tag"
          git push -u origin "release/$tag"
          gh pr create --base main --head "release/$tag" \
            --title "Release $tag" \
            --body "Automated release prep for **$tag**. Review the version bump, CHANGELOG, and the draft GitHub Release notes. Merging this PR auto-tags \`$tag\` and triggers publish."

      - name: Create draft GitHub Release (no tag yet)
        env:
          GH_TOKEN: ${{ github.token }}
          NOTES: ${{ steps.notes.outputs.body }}
          TAG: ${{ steps.ver.outputs.tag }}
        run: |
          # NOTES is passed via env, not interpolated into the script —
          # generated notes can contain quotes/backticks/$ that would
          # break shell interpolation. (Do not write a GitHub Actions
          # expression literal in this run block: it is parsed even in
          # shell comments and an empty one fails the workflow at startup.)
          printf '%s\n' "$NOTES" > /tmp/notes.md
          gh release create "$TAG" --draft --target main --title "$TAG" --notes-file /tmp/notes.md
          tag="$TAG"
          # A draft release must NOT create the git tag.
          if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
            echo "ERROR: draft release created the tag prematurely"; exit 1
          fi
```

**Step 2: Lint YAML**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/release-prep.yml"); puts "yaml ok"'`
Expected: `yaml ok`.

**Step 3: Commit**

```bash
git add .github/workflows/release-prep.yml
git commit -m "Add release-prep workflow (bump + CHANGELOG + Release PR + draft release)"
```

---

## Task 3: `release-tag-on-merge.yml` — auto-tag when the Release PR merges

**Files:**
- Create: `.github/workflows/release-tag-on-merge.yml`

**Step 1: Create the workflow**

`.github/workflows/release-tag-on-merge.yml`:
```yaml
name: Release Tag on Merge

on:
  pull_request:
    types: [closed]

permissions:
  contents: write

jobs:
  tag:
    if: >-
      github.event.pull_request.merged == true &&
      github.event.pull_request.base.ref == 'main' &&
      (contains(github.event.pull_request.labels.*.name, 'release') ||
       startsWith(github.event.pull_request.head.ref, 'release/v'))
    runs-on: ubuntu-latest
    steps:
      # Mint a short-lived installation token from the dedicated GitHub App.
      # Without this, checkout falls back to GITHUB_TOKEN; the tag still
      # pushes (permissions: contents: write) but release.yml never fires — a
      # silent, months-latent release stall. See Task 7.
      - uses: actions/create-github-app-token@v1
        id: app-token
        with:
          app-id: ${{ secrets.RELEASE_APP_ID }}
          private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}

      # IMPORTANT: a tag pushed with the default GITHUB_TOKEN does NOT trigger
      # release.yml (GitHub blocks workflow runs from GITHUB_TOKEN-created
      # events). The tag MUST be pushed with the dedicated GitHub App
      # installation token so `push: tags: ["v*"]` fires in release.yml.
      - uses: actions/checkout@v4
        with:
          ref: main
          fetch-depth: 0
          token: ${{ steps.app-token.outputs.token }}
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"
      - name: Configure git identity as the App bot
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          APP_SLUG: ${{ steps.app-token.outputs.app-slug }}
        run: |
          bot_id=$(gh api "/users/${APP_SLUG}[bot]" --jq .id)
          git config user.name  "${APP_SLUG}[bot]"
          git config user.email "${bot_id}+${APP_SLUG}[bot]@users.noreply.github.com"
      - name: Create and push tag
        run: |
          ver=$(ruby -r ./lib/redact_ner/version -e 'print RedactNer::VERSION')
          tag="v$ver"
          if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
            echo "tag $tag already exists; nothing to do"; exit 0
          fi
          git tag -a "$tag" -m "redact_ner $ver"
          git push origin "$tag"
```

**Step 2: Lint YAML**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/release-tag-on-merge.yml"); puts "yaml ok"'`
Expected: `yaml ok`.

**Step 3: Commit**

```bash
git add .github/workflows/release-tag-on-merge.yml
git commit -m "Add auto-tag workflow on Release PR merge"
```

---

## Task 4: `release.yml` publish job — un-draft existing release + attach assets

**Files:**
- Modify: `.github/workflows/release.yml` (the final "Create GitHub Release" step in the `publish` job)

**Step 1: Read the current step**

Run: `grep -n -A6 'Create GitHub Release' .github/workflows/release.yml`
Expected: a `softprops/action-gh-release@v2` step with `files: dist/*.gem` and `generate_release_notes: true`.

**Step 2: Replace that step**

Replace the entire `- name: Create GitHub Release` step (the `softprops/action-gh-release@v2` `uses:` block) with this run-based step (keep indentation consistent with the other steps in the job):
```yaml
      - name: Publish GitHub Release (un-draft existing draft + attach gems)
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          tag="${GITHUB_REF_NAME}"
          if gh release view "$tag" >/dev/null 2>&1; then
            gh release upload "$tag" dist/*.gem --clobber
            gh release edit "$tag" --draft=false --latest
          else
            # Fallback: tag pushed without release-prep (manual release).
            gh release create "$tag" dist/*.gem --title "$tag" --generate-notes --latest
          fi
```

**Step 3: Lint YAML**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); puts "yaml ok"'`
Expected: `yaml ok`.

**Step 4: Verify invariants unchanged**

Run: `grep -nE "if: startsWith\(github.ref, 'refs/tags/v'\)|environment: rubygems|Repushing of gem versions is not allowed|configure-rubygems-credentials@v2.0.0" .github/workflows/release.yml`
Expected: all four still present (publish gating, env gate, idempotent push guard, pinned credentials action). `grep -c 'softprops/action-gh-release' .github/workflows/release.yml` → `0` (removed).

**Step 5: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Publish step: un-draft pre-created draft release and attach gems"
```

---

## Task 5: README "Releasing" section → new flow

**Files:**
- Modify: `README.md` (the `Releasing`/version-bump instructions; current text near "Update `lib/redact_ner/version.rb` and `CHANGELOG.md`. Commit.")

**Step 1: Locate the section**

Run: `grep -n -B1 -A6 -i 'releasing\|Update .lib/redact_ner/version' README.md`

**Step 2: Replace the manual steps** with a description of the automated flow (match README heading style):
```markdown
## Releasing

Releases are automated. To cut a release:

1. Run the **Release Prep** workflow (Actions → Release Prep → Run workflow),
   choosing the `bump` level (`patch`/`minor`/`major`). It bumps
   `lib/redact_ner/version.rb`, rolls `CHANGELOG.md` from GitHub-generated
   notes, opens a **Release PR**, and creates a **draft GitHub Release**.
2. Review/edit the Release PR (and the draft Release notes) and **merge** it.
   Merging auto-creates and pushes the `vX.Y.Z` tag.
3. The tag triggers the **Release** workflow: it builds the 5 precompiled
   gems + source gem, then the `publish` job waits for approval on the
   `rubygems` GitHub Environment. Approve it to publish to RubyGems and
   un-draft the GitHub Release with the gem assets attached.

To abort before publishing, close the Release PR without merging and delete
the `release/vX.Y.Z` branch and the draft Release.
```
Change nothing else in README.

**Step 3: Commit**

```bash
git add README.md
git commit -m "Document automated release flow in README"
```

---

## Task 7: User prerequisite — dedicated GitHub App (do before Task 6's real-release leg)

**Manual user action; cannot be done in code.** A tag pushed by the default
`GITHUB_TOKEN` does NOT trigger `release.yml`. The release workflows mint a
short-lived token from a dedicated GitHub App instead.

1. GitHub → Settings → Developer settings → **GitHub Apps → New GitHub App**.
   Name e.g. `redact-ner-ruby-release-bot`; Homepage URL anything; **uncheck
   Webhook → Active**. Repository permissions: **Contents: Read and write**,
   **Pull requests: Read and write** (everything else: No access). Create.
2. Note the **App ID**. Under "Private keys" → **Generate a private key**
   (downloads a `.pem`).
3. **Install App** → only `mitsuru/redact-ner-ruby`.
4. After install, confirm the App's bot user resolves:
   `gh api "/users/<app-slug>[bot]" --jq .id` returns a numeric id
   (`<app-slug>` = the App's lowercased URL slug). If it 404s, wait a minute
   and retry.
5. Repo → Settings → Secrets and variables → Actions → add:
   - `RELEASE_APP_ID` = the App ID
   - `RELEASE_APP_PRIVATE_KEY` = the full `.pem` contents

Confirm both secrets exist (and the bot-user check passes) before merging any
Release PR.

---

## Task 6: End-to-end dry-run verification (NO publish)

**Files:** none (verification only).

**Step 1: Push the branch and merge to main first**

These workflows must be on `main` to be dispatchable / to fire on PR merge. Open a PR for `feature/release-automation` → review → merge to `main` (or fast-forward if the team allows). Then:

Run: `gh workflow list | grep -i 'Release Prep'`
Expected: `Release Prep` listed (workflow registered on default branch).

**Step 2: Dispatch release-prep with `bump=patch`**

Run: `gh workflow run release-prep.yml -f bump=patch`
Then watch: `gh run watch "$(gh run list --workflow=release-prep.yml --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status`
Expected: success.

**Step 3: Inspect artifacts — confirm NOTHING is published**

Run:
```bash
gh pr list --search "head:release/v" --json number,headRefName,title
gh release list | grep -i 'v0\.1\.2'        # draft present
git ls-remote --tags origin | grep v0.1.2 || echo "NO TAG (correct)"
curl -s https://rubygems.org/api/v1/versions/redact_ner.json | ruby -rjson -e 'puts JSON.parse(STDIN.read).map{|v| v["number"]}.uniq.inspect'
```
Expected: a PR from the `release/v0.1.2` head branch; a **draft** release `v0.1.2`; **no `v0.1.2` git tag**; rubygems still shows only `0.1.1` (nothing published).

**Step 4: Inspect the Release PR diff**

Run: `gh pr diff "$(gh pr list --search "head:release/v" --json number -q '.[0].number')"`
Expected: only `lib/redact_ner/version.rb` (→ 0.1.2) and `CHANGELOG.md` (new `## [0.1.2] - <date>` section from generated notes + updated link refs) changed.

**Step 5: Decide — real release or abort the dry-run**

- To complete a real 0.1.2 release: **first ensure Task 7 (the dedicated GitHub App + `RELEASE_APP_ID`/`RELEASE_APP_PRIVATE_KEY` secrets) is done**, then merge the PR. Verify the chain: `release-tag-on-merge` runs → a `v0.1.2` tag appears on origin → a NEW `release.yml` run starts from that tag (if NO release.yml run appears, the GitHub App token is missing/misconfigured — the GITHUB_TOKEN suppression bit). Then approve the `rubygems` env and verify per the existing release runbook.
- To abort the dry-run: `gh pr close <n> --delete-branch`; `gh release delete v0.1.2 --yes`. Confirm `gh release list` no longer shows `v0.1.2`.

No commit (verification only).

---

## Notes for the executor

- Do NOT push a `v*` tag manually during development — it triggers the real publish (`release.yml`).
- **GITHUB_TOKEN tag gotcha:** the auto-tag in `release-tag-on-merge.yml` MUST push with the dedicated GitHub App installation token, minted via `actions/create-github-app-token@v1` from `secrets.RELEASE_APP_ID`/`secrets.RELEASE_APP_PRIVATE_KEY` (Task 3 + Task 7). A tag pushed by the default `GITHUB_TOKEN` will NOT start `release.yml` — the whole chain silently stalls with a tag but no publish. Verify in Task 6 Step 5 that merging produces a new `release.yml` run.
- Workflows triggered by `pull_request` (release-tag-on-merge) read the workflow file from the PR **base** (`main`) — so it must be merged to `main` (Task 6 Step 1) before it can fire.
- `release-prep` creating the **draft** release must NOT create the git tag; Step 6.3 explicitly asserts this. If a tag appears, stop and fix (likely a `gh release create` flag).
- The generate-notes API works for a not-yet-existing tag (`tag_name` + `target_commitish=main`). `previous_tag_name` omitted when no prior `v*` tag.
- Keep YAGNI: no explicit-version input, no prerelease/build metadata, no Conventional Commits, no CHANGELOG auto-categorization (all out of scope per the issue design).
- Acceptance criteria are in beads issue `redact-ner-ruby-rvk` — verify against them before closing.
- Workflows only take effect once on `main` (Task 6 Step 1). Tasks 1–5 are committed on `feature/release-automation`; Task 6 needs them merged.
