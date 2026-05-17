# GitHub App Token (replace RELEASE_PAT) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the user-managed `RELEASE_PAT` with a dedicated GitHub App installation token (`actions/create-github-app-token@v1`) in `release-prep.yml` and `release-tag-on-merge.yml`, so the auto-pushed tag still triggers `release.yml`, the Release PR can trigger CI, and there is no personal-PAT expiry/coupling.

**Architecture:** Each job mints a short-lived installation token from repo secrets `RELEASE_APP_ID` + `RELEASE_APP_PRIVATE_KEY`. `actions/checkout` uses that token (so subsequent `git push` authenticates as the App → triggers downstream workflows; `GITHUB_TOKEN`-pushed refs do not). All `gh`/`git` operations and the committer identity use the App bot. `RELEASE_PAT` and its manual fail-fast guard are removed (token minting is inherently fail-fast). `release.yml` is unchanged.

**Tech Stack:** GitHub Actions, `actions/create-github-app-token@v1`, `gh` CLI, GitHub App (Contents RW + Pull requests RW). Verification: **actionlint** (authoritative GHA schema/expression validator — Ruby `YAML.load_file` is NOT sufficient; this is a hard lesson from a prior startup_failure) + dry-run.

**Issue:** `redact-ner-ruby-a2c` (design + acceptance in the beads issue). Supersedes the RELEASE_PAT mechanism from `redact-ner-ruby-rvk` (PR #1, merged to `main`).

**Repo facts:**
- Branch from `main` (HEAD has merged release automation + the startup-failure fix).
- `actionlint` binary is present in the worktree root (`./actionlint`); use `./actionlint -shellcheck= .github/workflows/*.yml`.
- Workflows on `main`: `ci.yml`, `release.yml` (unchanged by this work), `release-prep.yml`, `release-tag-on-merge.yml`.
- `release-tag-on-merge.yml` currently: a `Verify RELEASE_PAT is configured` step, then `actions/checkout@v4` with `token: ${{ secrets.RELEASE_PAT }}`, then a "Create and push tag" step that does `git config user.name "github-actions[bot]"` + `git tag -a` + `git push origin "$tag"`.
- `release-prep.yml` currently: job `prep` (`if: github.ref == 'refs/heads/main'`), `actions/checkout@v4` (no custom token), `gh` steps using `GH_TOKEN: ${{ github.token }}`, a "Create branch, commit, open Release PR" step using `git config user.name "github-actions[bot]"`.
- Build artifacts (`pkg/`, `tmp/`, `*.gem`) gitignored. A beads git hook writes `.beads/issues.jsonl` on commit — never stage it; commit with explicit pathspecs.
- **Verification gate for every workflow edit:** `./actionlint -shellcheck= .github/workflows/*.yml` must be clean. Do NOT rely on `ruby -ryaml`.

**Shared snippet (App token + bot identity)** — used by both workflows:
```yaml
      - uses: actions/create-github-app-token@v1
        id: app-token
        with:
          app-id: ${{ secrets.RELEASE_APP_ID }}
          private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```
Bot committer identity — place this step **immediately after `actions/checkout` (before `Compute next version` / any `git commit`/`git tag`)**, using the App token:
```yaml
      - name: Configure git identity as the App bot
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          APP_SLUG: ${{ steps.app-token.outputs.app-slug }}
        run: |
          bot_id=$(gh api "/users/${APP_SLUG}[bot]" --jq .id)
          git config user.name  "${APP_SLUG}[bot]"
          git config user.email "${bot_id}+${APP_SLUG}[bot]@users.noreply.github.com"
```

---

## Task 1: `release-tag-on-merge.yml` → App token

**Files:**
- Modify: `.github/workflows/release-tag-on-merge.yml`

**Step 1: Apply the changes**

In the `tag` job:
1. **Remove** the entire `- name: Verify RELEASE_PAT is configured` step (and its `env: PAT:` block and the comment block immediately above it explaining the fail-fast).
2. **Insert**, as the FIRST step of the job, the `actions/create-github-app-token@v1` step (id `app-token`) from the shared snippet.
3. On the existing `- uses: actions/checkout@v4` step, change `token: ${{ secrets.RELEASE_PAT }}` → `token: ${{ steps.app-token.outputs.token }}`. Keep `ref: main`, `fetch-depth: 0`.
4. After `ruby/setup-ruby@v1`, add the "Configure git identity as the App bot" step (shared snippet).
5. In the "Create and push tag" step, **remove** the two inline `git config user.name "github-actions[bot]"` / `git config user.email ...` lines (identity is now set by the dedicated step). Keep the version read, the idempotent `git rev-parse` early-exit, `git tag -a "$tag" -m "redact_ner $ver"`, and `git push origin "$tag"`.
6. Update the IMPORTANT comment so it explains the App token (not RELEASE_PAT) is why the tag triggers `release.yml`. **Do not write a literal `${{` `}}` inside any `run:` comment** (GHA parses expressions even in shell comments — prior startup_failure).

**Step 2: actionlint**

Run: `./actionlint -shellcheck= .github/workflows/release-tag-on-merge.yml`
Expected: no output (clean). Then `./actionlint -shellcheck= .github/workflows/*.yml` → clean (no regression to other workflows).

**Step 3: Static checks**

Run:
```bash
grep -n 'RELEASE_PAT' .github/workflows/release-tag-on-merge.yml || echo "NO RELEASE_PAT (correct)"
grep -n 'create-github-app-token@v1' .github/workflows/release-tag-on-merge.yml
grep -n 'steps.app-token.outputs.token' .github/workflows/release-tag-on-merge.yml
grep -n 'github-actions\[bot\]' .github/workflows/release-tag-on-merge.yml || echo "no hardcoded github-actions bot (correct)"
ruby -ryaml -e 'YAML.load_file(".github/workflows/release-tag-on-merge.yml"); puts "yaml ok"'
```
Expected: NO `RELEASE_PAT`; create-github-app-token present; checkout uses `steps.app-token.outputs.token`; no hardcoded `github-actions[bot]`; `yaml ok`.

**Step 4: Confirm the `if:` gate + idempotency unchanged**

Run: `grep -nE "merged == true|base.ref == 'main'|refs/tags/\\\$tag|git push origin" .github/workflows/release-tag-on-merge.yml`
Expected: job `if` (merged + base main + release label/branch) and the idempotent tag check + `git push origin "$tag"` all still present.

**Step 5: Commit**

```bash
git add .github/workflows/release-tag-on-merge.yml
git commit -m "release-tag-on-merge: use GitHub App token instead of RELEASE_PAT"
```
`git status --porcelain` clean after (do not stage `.beads/issues.jsonl`); `git show --stat HEAD` lists only that file.

---

## Task 2: `release-prep.yml` → App token

**Files:**
- Modify: `.github/workflows/release-prep.yml`

**Step 1: Apply the changes** (job `prep`, keep `if: github.ref == 'refs/heads/main'`)

1. Insert the `actions/create-github-app-token@v1` step (id `app-token`, shared snippet) as the FIRST step of `prep` (before `actions/checkout@v4`).
2. On `actions/checkout@v4`, add `token: ${{ steps.app-token.outputs.token }}` (keep `fetch-depth: 0`).
3. After `ruby/setup-ruby@v1`, add the "Configure git identity as the App bot" step (shared snippet).
4. Change every `GH_TOKEN: ${{ github.token }}` in this job to `GH_TOKEN: ${{ steps.app-token.outputs.token }}` (steps: Guard against duplicate cut, Generate release notes, Create branch/commit/open Release PR, Create draft GitHub Release).
5. In "Create branch, commit, open Release PR": **remove** the inline `git config user.name "github-actions[bot]"` / `git config user.email ...` lines (identity now set by the dedicated step). **Also remove the `release` label entirely** — the dedicated App has only Contents RW + Pull requests RW, and label creation needs Issues:write (which the App lacks); `gh label create` would 403 (swallowed by `|| true`) and then `gh pr create --label release` would fail with a nonexistent label, aborting the job and stranding the `release/v*` branch. So: **delete the `gh label create release ... || true` line**, and call `gh pr create` **without** `--label release`. `release-tag-on-merge.yml` already triggers on `startsWith(github.event.pull_request.head.ref, 'release/v')` (verified), so the label was only a redundant OR-fallback. Keep `git switch -c "release/$tag"`, `git add lib/redact_ner/version.rb CHANGELOG.md`, `git commit -m "Release $tag"`, `git push -u origin "release/$tag"`, and `gh pr create --base main --head "release/$tag" --title ... --body ...` (no `--label`).
6. Do NOT alter: the `bump` input, `permissions` block, version compute, the random-delimiter notes step, the Roll CHANGELOG Ruby (block-form sub + abort + greps), the draft-release step's NOTES-via-env + no-tag assertion, the `if: github.ref == 'refs/heads/main'` guard. **No literal `${{` `}}` inside any `run:` comment.**

**Step 2: actionlint**

Run: `./actionlint -shellcheck= .github/workflows/release-prep.yml` then `./actionlint -shellcheck= .github/workflows/*.yml`
Expected: both clean.

**Step 3: Static checks**

```bash
grep -n 'RELEASE_PAT' .github/workflows/release-prep.yml || echo "NO RELEASE_PAT (correct)"
grep -c 'github.token' .github/workflows/release-prep.yml   # expect 0 (all replaced)
grep -c 'steps.app-token.outputs.token' .github/workflows/release-prep.yml  # >=5 (checkout + identity + 4 gh steps env)
grep -n "if: github.ref == 'refs/heads/main'" .github/workflows/release-prep.yml  # guard intact
grep -n 'github-actions\[bot\]' .github/workflows/release-prep.yml || echo "no hardcoded bot (correct)"
ruby -ryaml -e 'YAML.load_file(".github/workflows/release-prep.yml"); puts "yaml ok"'
```
Expected: no RELEASE_PAT; `github.token` count 0; app-token output referenced ≥5×; main guard present; no hardcoded `github-actions[bot]`; `yaml ok`.

**Step 4: Confirm core logic preserved**

Run: `grep -nE 'openssl rand -hex 16|sub\(/## \\\[Unreleased\\\]|--draft --target main|abort "CHANGELOG missing' .github/workflows/release-prep.yml`
Expected: random delimiter, block-form Unreleased sub, draft-release flags, and the CHANGELOG abort guard all still present (unchanged).

**Step 5: Commit**

```bash
git add .github/workflows/release-prep.yml
git commit -m "release-prep: use GitHub App token instead of github.token/PAT"
```
Clean status after; only that file in `git show --stat HEAD`.

---

## Task 3: Docs — Task 7 (App prerequisite) + scrub RELEASE_PAT

**Files:**
- Modify: `docs/plans/2026-05-17-release-automation.md` (the rvk plan, present on this branch from `main`)
- Modify: `README.md` only if it references `RELEASE_PAT`

**Step 1: Find RELEASE_PAT references**

Run: `grep -rn 'RELEASE_PAT' docs/plans/2026-05-17-release-automation.md README.md`

**Step 2: Rewrite the rvk plan's Task 7** (the "User prerequisite — RELEASE_PAT" section) to the GitHub App prerequisite. Replace its body with:
```markdown
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
4. Repo → Settings → Secrets and variables → Actions → add:
   - `RELEASE_APP_ID` = the App ID
   - `RELEASE_APP_PRIVATE_KEY` = the full `.pem` contents

5. After install, confirm the App's bot user resolves (the workflows derive
   the committer email from it): `gh api "/users/<app-slug>[bot]" --jq .id`
   should return a numeric id. The `<app-slug>` is the App's URL slug
   (lowercased name). If it 404s, wait a minute post-install and retry.

Confirm both secrets exist (and the bot-user check passes) before merging any
Release PR.
```
Also remove/replace any other `RELEASE_PAT` mentions in that plan (e.g. Task 3 notes, the executor notes, Task 6 Step 5) so they refer to the App token / the new secrets. Keep the GITHUB_TOKEN-tag-trigger rationale (still true), just attribute the fix to the App token.

**Step 3: README** — if `grep` found `RELEASE_PAT` in README.md, update that sentence to reference the GitHub App prerequisite instead; otherwise no change.

**Step 4: Verify**

Run: `grep -rn 'RELEASE_PAT' docs/plans/2026-05-17-release-automation.md README.md && echo "STILL HAS RELEASE_PAT (bad)" || echo "RELEASE_PAT fully removed (correct)"`
Expected: `RELEASE_PAT fully removed (correct)`. Also `grep -n 'RELEASE_APP_ID\|GitHub App' docs/plans/2026-05-17-release-automation.md` shows the new prerequisite.

**Step 5: Commit**

```bash
git add docs/plans/2026-05-17-release-automation.md README.md
git commit -m "Docs: replace RELEASE_PAT prerequisite with dedicated GitHub App"
```
(If README unchanged, add only the plan doc.)

---

## Task 4: Whole-branch verification

**Files:** none (verification only).

**Step 1: actionlint, all workflows**

Run: `./actionlint -shellcheck= .github/workflows/*.yml && echo "ALL WORKFLOWS CLEAN"`
Expected: `ALL WORKFLOWS CLEAN`.

**Step 2: Test suite unaffected**

Run: `bundle exec rake test 2>&1 | tail -3`
Expected: `12 runs, ... 0 failures` (no Ruby code changed; if the native ext isn't built in a fresh checkout run `bundle exec rake compile` first — environment setup, not a regression).

**Step 3: No RELEASE_PAT anywhere**

Run: `grep -rn 'RELEASE_PAT' .github docs README.md || echo "RELEASE_PAT fully gone"`
Expected: `RELEASE_PAT fully gone`.

**Step 4: release.yml untouched**

Run: `git diff main...HEAD --stat -- .github/workflows/release.yml`
Expected: empty (release.yml not modified by this branch).

**Step 5: Branch diff scope**

Run: `git diff main...HEAD --stat`
Expected: only `.github/workflows/release-prep.yml`, `.github/workflows/release-tag-on-merge.yml`, `docs/plans/2026-05-17-release-automation.md`, possibly `README.md`, and this plan doc. No code/test/`.beads` files.

No commit (verification only).

---

## Notes for the executor

- **actionlint is the gate, not Ruby YAML.** A prior `${{ }}`-in-a-run-comment shipped a workflow startup_failure that `ruby -ryaml` accepted. Run `./actionlint -shellcheck= .github/workflows/*.yml` after every workflow edit and never write a literal `${{` `}}` inside a `run:` comment.
- The App-token mechanism only works once the user creates the App + secrets (Task 7, manual). `create-github-app-token` fails the job loudly if `RELEASE_APP_ID`/`RELEASE_APP_PRIVATE_KEY` are missing/invalid — this is the intended inherent fail-fast (no manual guard needed).
- **Fork-PR / secrets note (audit clarity):** `release-tag-on-merge.yml` triggers on `pull_request: [closed]`. Fork-originated `pull_request` events receive empty secrets, which would make `create-github-app-token` fail. This is NOT a real path here: Release PRs are always internal (`release/v*` head, base `main`; the `release` label was removed — the `release/v*` head is the trigger), and the job-level `if:` gates the ENTIRE job — including the `create-github-app-token` step — so a fork PR lacking the label/branch is skipped before any secret is read. No extra guard needed; documented so a future auditor doesn't mistake this for an unhandled case.
- `actions/create-github-app-token@v1` outputs `token` and `app-slug`. The bot user id for the noreply email comes from `gh api "/users/${APP_SLUG}[bot]" --jq .id` (public endpoint; the App token can read it).
- Post-merge dry-run / end-to-end (dispatch Release Prep `bump=patch` → Release PR + draft Release, no publish/tag; then merge → App-token tag push → `release.yml` fires) is operational verification done after this branch merges and the App exists — track on issue `redact-ner-ruby-a2c`, do not attempt before the App secrets are set.
- Commit with explicit pathspecs; the beads hook touches `.beads/issues.jsonl` — keep it out of commits.
- `release.yml` must remain byte-unchanged on this branch.
