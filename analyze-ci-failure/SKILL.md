---
name: analyze-ci-failure
description: >
  Diagnose why a GitHub CI run failed and explain the real root cause. Use this skill whenever
  the user provides a GitHub Actions run URL, a PR number/URL, or asks anything like "why did
  CI fail", "why was my PR kicked out of the merge queue", "what's blocking this PR from
  merging", "explain this failed run", "which tests failed", or pastes a link to a failed
  workflow run or pull request. Also use it when the user mentions a red X on a PR, a dequeued
  merge queue entry, or failing checks — even if they don't say "CI" explicitly. The skill
  finds the actual blocking failure (filtering out optional/non-required workflows), extracts
  failed tests and error messages from logs, and handles merge queue runs.
compatibility: Requires the `gh` CLI, authenticated (`gh auth status`).
---

# CI Failure Diagnosis

Given a GitHub Actions run URL or a PR number, find and explain the **real** reason CI failed.
The goal is a diagnosis a developer can act on immediately: which check actually blocked them,
which job/step broke, which tests failed, and the exact error message — not a wall of logs and
not a list of every red X.

## Core principles

1. **Real blockers only.** A failed workflow that is not a *required* status check did not
   block anything. Report it at most as a footnote, never as the cause. Conversely, a
   cancelled-but-required check can be the true blocker (e.g., cancelled because a sibling
   required check failed first — then the sibling is the root cause).
2. **Root cause, not symptom.** "Job failed" is a symptom. The diagnosis is the underlying
   error: the failing assertion, the compile error, the timeout, the infra flake, the missing
   secret. Always quote the actual error message from the logs.
3. **Be economical with logs.** CI logs can be hundreds of MB. Never dump raw logs into
   context. Use the bundled `scripts/get_failed_logs.sh` script, which extracts only
   failed-step logs and trims them around error markers.
4. **Ruthless concision in the answer.** The user already knows the run failed — that's why
   they asked. Do not restate that it failed, when it ran, who authored the PR, what the PR
   title is, what files the PR touches, or how merge queues work. Every sentence must carry
   information the user can act on. The investigation can be thorough; the answer must be
   short.

## Step 0: Parse the input

- **Run URL** (`https://github.com/OWNER/REPO/actions/runs/RUN_ID[/job/JOB_ID]`):
  extract OWNER/REPO and RUN_ID (and JOB_ID if present — focus there). Go to Step 2.
- **PR number or PR URL**: extract OWNER/REPO and PR number. If only a bare number is given
  and the current directory is a git repo, infer the repo with
  `gh repo view --json nameWithOwner -q .nameWithOwner`; otherwise ask the user for the repo.
  Go to Step 1.

## Step 1 (PR given): Find the run that actually matters

The user wants to know what's blocking *merging*. Two distinct failure surfaces exist:

**a) Check the merge queue first.** If the PR was recently added to and removed from the
merge queue, the dequeue reason is the answer — even if branch CI is green.

```bash
gh api graphql -f query='
query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      state mergeStateStatus headRefName headRefOid baseRefName
      timelineItems(last:30, itemTypes:[ADDED_TO_MERGE_QUEUE_EVENT, REMOVED_FROM_MERGE_QUEUE_EVENT]){
        nodes{
          __typename
          ... on RemovedFromMergeQueueEvent{ createdAt reason beforeCommit{ oid } }
          ... on AddedToMergeQueueEvent{ createdAt }
        }
      }
    }
  }
}' -F owner=OWNER -F repo=REPO -F pr=PR_NUMBER
```

If the latest event is `RemovedFromMergeQueueEvent` with a CI-related `reason`
(e.g. "CI failed" / "failed status checks"), find the merge-queue run: merge queue runs have
`event == "merge_group"` and run on a synthetic branch like
`gh-readonly-queue/<base>/pr-<N>-<sha>`.

```bash
gh run list -R OWNER/REPO --event merge_group --limit 50 \
  --json databaseId,headBranch,conclusion,createdAt,workflowName,url \
  -q '[.[] | select(.headBranch | contains("pr-PR_NUMBER-"))]'
```

Pick the latest **failed** one(s) around the dequeue timestamp. Diagnose those (Step 2).
Tell the user explicitly that the PR was dequeued and this merge-queue run is why.

**b) Otherwise, diagnose branch CI.** Find the latest failed run on the PR's head:

```bash
gh pr checks PR_NUMBER -R OWNER/REPO --json name,state,link,bucket,workflow
gh run list -R OWNER/REPO --branch HEAD_REF --limit 20 \
  --json databaseId,conclusion,workflowName,event,headSha,url,createdAt
```

Only consider runs for the PR's current `headRefOid` unless none exist. If several workflows
failed, apply the required-check filter (Step 3) before deciding which to dig into.

If *nothing* failed (no failed merge-queue run, all checks green/pending), say so — the
blocker may be reviews, `mergeStateStatus` (e.g. `BEHIND`, `BLOCKED`), or pending checks.

## Step 2 (run in hand): Find failed jobs and steps

```bash
gh run view RUN_ID -R OWNER/REPO --json status,conclusion,event,headBranch,headSha,workflowName,url,jobs
```

If `event == "merge_group"`, this is a merge-queue run: the PR number is encoded in
`headBranch` (`gh-readonly-queue/<base>/pr-<N>-<sha>`) — mention which PR it gated and frame
the diagnosis as "what got the PR dequeued".

From `jobs`, collect every job with `conclusion == "failure"` and within each, the steps with
`conclusion == "failure"`. Note jobs that were `cancelled` — distinguish "cancelled because
something else failed (fail-fast)" from genuine failures; the genuinely failed job is the root
cause. If ALL failures are in a matrix, identify which matrix variants failed.

**Watch for rollup/aggregator jobs.** Many repos gate merges on a job like `tests-passed` or
`ui-tests-passed` whose only purpose is to check `needs.*.result` of upstream jobs. Its log
contains nothing but lines like `::error::ui-tests: failure`. Never report a rollup job as the
cause — follow it upstream to the job(s) that actually failed and diagnose those. A tell:
the failed step is named something like "Verify job results" / "Verify test results".

Conversely, rollup jobs sometimes run an aggregated **failed-test summary step** (e.g. one
that parses all test-result files and prints every failed test with its error). If present,
read that step's log first — it can replace digging through each matrix job individually.

Check annotations first — they're cheap and often contain the exact error:

```bash
gh api repos/OWNER/REPO/check-runs/CHECK_RUN_ID/annotations   # check-run id == job databaseId
```

## Step 3: Separate real blockers from optional noise

A failed workflow only blocks a PR if it's a **required status check**. Determine required
checks, in order of reliability:

1. `gh pr checks PR_NUMBER -R OWNER/REPO --required --json name,state,link,workflow` —
   directly lists required checks for the PR (best when a PR is involved).
2. Repo rulesets: `gh api repos/OWNER/REPO/rules/branches/BASE_BRANCH` — look for
   `required_status_checks` entries (works without admin).
3. Classic branch protection:
   `gh api repos/OWNER/REPO/branches/BASE_BRANCH/protection/required_status_checks` —
   may 403/404 without admin; treat that as "unknown", not "none".

Classify every failed check as **BLOCKER** (required, failed) or **non-blocking** (optional,
failed). If required-check info is unavailable, say you couldn't verify and use judgment
(merge_group runs are effectively always blocking — the queue ran them *because* they're
required). Do not present an optional lint/nightly/canary failure as the reason a PR can't merge.

## Step 4: Extract the actual errors

Run the bundled script — it downloads only failed-job logs and trims them intelligently:

```bash
bash scripts/get_failed_logs.sh OWNER/REPO RUN_ID [OUTPUT_DIR]
```

It writes one trimmed log per failed job to OUTPUT_DIR (default `/tmp/ci-diagnosis-RUN_ID/`)
and prints a summary. Read those files, not raw logs.

When reading, hunt for the *first* real error, since later errors usually cascade:

- Test failures: framework output (`FAIL`, `✕`, `AssertionError`, `Expected ... Received`,
  `XCTAssert`, JUnit summaries). Collect **each failed test's name + its assertion/error
  message**. For UI tests, also capture which step the tests ran in and any screenshot or
  artifact mention.
- Build/compile errors: first `error:` / `error TS` / `cannot find symbol` etc.
- Infra/flake signals: `ETIMEDOUT`, `ECONNRESET`, runner lost, 429/5xx from registries,
  "No space left on device", Docker pull failures. Label these as likely infra/flakiness and
  suggest a retry — but only after confirming no real test/build error precedes them.
- Setup failures: missing secret/env (`is not set`, `unauthorized`), action version errors —
  these usually mean a config problem, not a code problem.

**Prefer structured test results over log scraping.** If the run uploads test-result
artifacts (`.trx`, JUnit XML — check `gh api repos/OWNER/REPO/actions/runs/RUN_ID/artifacts`
for names like `*-trx` / `*test-results*`), download just those
(`gh run download RUN_ID -R OWNER/REPO -p '<pattern>' -D <dir>`) and parse them: failed tests
are `<UnitTestResult outcome="Failed">` (TRX) or `<testcase><failure>` (JUnit), each with the
full error message and stack trace. This is exact where log scraping is fuzzy.

**Account for retries.** Many CI setups rerun failed tests (retry steps, flaky-rerun counts,
multiple TRX files per job). A test that failed once but passed on retry did NOT fail the job
— exclude it from "failed tests" (mention at most as "N flaky tests passed on retry"). When
multiple result files exist per job, the last one reflects the final outcome.

If logs are expired (runs older than the retention window), fall back to annotations and the
check-run summary, and say logs were unavailable.

## Step 5: Report — short, cause-first

Lead with the root cause. No preamble, no context paragraph, no narration of the
investigation. Target: the whole answer fits on one screen.

```markdown
**Root cause:** <one sentence: the actual error and where — e.g. "6 UI tests assert the live
lite.duckduckgo.com page title, which changed server-side; unrelated to the PR." If it was a
merge-queue run, a parenthetical "(merge-queue run <link>, PR dequeued)" is enough.>

**Failed:** `<job>` › `<step>` — <link>
```
<exact error message, trimmed to the essential lines>
```

**Failed tests:**           <!-- only when tests failed; one line per test -->
- `<test name>` — <one-line error>

**Fix:** <one line: what to change, or "infra/flake — re-run">
```

Rules for the report:

- Never restate facts the user already knows: that the run failed, that they asked about it,
  the PR title/author, timestamps, or generic explanations of CI/merge-queue mechanics.
- One root cause = one sentence. Multiple independent causes = one sentence each.
- Quote real error text — never paraphrase an error into vagueness — but trim each quote to
  the lines that carry the error (a few lines, not a screenful).
- Failed but **optional** workflows: omit entirely unless there were *no* required failures;
  then one line ("Only optional check X failed — nothing blocks the merge").
- Whether failures relate to the PR's changes: at most a clause inside the root-cause
  sentence, not a paragraph of file-path analysis.
- Link the failing job(s) so the user can verify; skip links to everything else.
