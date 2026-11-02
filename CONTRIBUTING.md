# Contributing to reaper-harness

reaper-harness runs unattended REAPER host tests for VST3 plugins on Windows. It runs on the user's own desktop,
next to their everyday REAPER setup and installed plugins, so its safety rules matter more than any feature. Issues
and pull requests in English or Chinese are welcome; the maintainer answers in the language you use. The rules below
are authoritative in English.

## 1. Code of conduct

The project follows the code of conduct of the synchain-oss organisation
([synchain-oss/.github](https://github.com/synchain-oss/.github)). Report problems to **contact@synchain.ca**.

## 2. Developer Certificate of Origin

Every commit needs a `Signed-off-by:` line in **your own name and email**, which certifies the
[Developer Certificate of Origin](https://developercertificate.org/):

```sh
git commit -s
```

The last line of your pull request description is the same `Signed-off-by:` line. There is no CLA. Contributions
are accepted under the project licence, MIT.

## 3. How to contribute

- Fork the repository, create a branch with any name except a long-lived one (`dev`, `prod`, `feature/...`), and open
  the pull request against **`dev`**.
- Fork pull requests run only the checks that need no secrets: the personal-data scan runs its generic rules only,
  and there is no AI review of fork pull requests yet (see section 7). Workflows from first-time contributors wait
  for a maintainer's approval.
- For anything bigger than a fix, open an issue first so the design can be agreed before you write the code.
- Commit subjects and pull request titles use `type(scope): description`, with type one of feat, fix, docs, test,
  refactor, perf, ci, build, chore, style, revert, harden, release or merge; for example
  `fix(compare): count NaN samples separately`.
- No AI attribution of any kind in commits or pull request text: `Signed-off-by:` is the only trailer.
- Security problems: do not open a public issue; see [SECURITY.md](SECURITY.md).

## 4. Checks

All repository checks run on Node 22 (the exact version is in `.node-version`) with built-in modules only:

```sh
node --test "scripts/**/*.test.mjs"        # every self-test, plus the mutation check of the privacy rules
node scripts/check-spdx.mjs                # SPDX header on every source file
node scripts/check-workflows.mjs           # workflow hardening; runs actionlint when HARNESS_ACTIONLINT points at it
node scripts/check-privacy.mjs --needles-file <your needle file>     # or --needles ci-optional
node scripts/check-commits.mjs commits --range origin/dev..HEAD --tier fork --needles ci-optional
```

- Every check prints only positions and redacted fragments, and exits with 0 (pass), 1 (findings) or 64 (usage
  error). Each one has a `--self-test` with bad and good cases; removing any criterion must turn a case red.
- Every new code, script, workflow and hook file carries the line `SPDX-License-Identifier: MIT` in a comment within
  its first five lines (`scripts/check-spdx.mjs` has the exact list of file types). Markdown and JSON files need no
  header: `LICENSE` covers the whole repository.
- The personal-data scan (`check-privacy.mjs`) has generic rules for local paths, personal email addresses, host
  names, internal planning numbers and AI attribution. A needle file of your own (one string per line, never
  committed) adds the personal strings that must not appear. Without one, pass `--needles ci-optional`: the scan runs
  the generic rules only and says so; the maintainer's CI adds the rest.

## 5. Changes that will be rejected

- **Touching REAPER's default resource directory.** The harness only ever starts REAPER with `-cfgfile` pointing at
  its private configuration directory, asserts that before every launch, refuses a directory that resolves into the
  default one, and compares an inventory of the default directory before and after every round.
- **Ending or driving processes and windows the harness did not start.** It ends only the PID it launched and only
  handles that PID's windows.
- **Weakening the verdicts.** INCOMPLETE is never PASS; built-in and configured negative cases must turn red for the
  expected reason.
- **Personal data in results or logs.** No local paths, user names, host names or lists of installed plugins.
- **Unhardened workflows.** No `pull_request_target` or `workflow_run`; remote actions pinned to a 40-character SHA;
  untrusted text only through `env:`.

## 6. Review process

### 6.1 Who reviews

- `claude-pr-review` (`.github/workflows/claude-review.yml` with `scripts/review-bot.mjs`) reviews every pull request
  from this repository that is not a draft and not from dependabot, on every push. It is not a required check, but
  the merge criteria require it to succeed on the current head.
- Two pr-agent reviews (`pr-agent.yml` on pull requests into `dev`, `pr-agent-claude.yml` on every base) and the
  manual fallback `deepseek-review.yml` only comment. Their conclusions are not part of the merge criteria, but every
  comment gets an answer.
- The reviewer reads its material from `.harness-review/` (written by `review-bot.mjs prepare`: `round.json`,
  `pr.diff`, `pr.json`, and from round 2 on `incremental.diff`, `previous-review.md` and `disposition.md`). From
  round 2 on it only reviews what changed since the head of the latest usable summary (one whose last line is the
  footer), after reading the disposition summary posted after it; with no usable summary yet it reviews everything.
- Grades: 【红旗】 (red flag, blocks the merge), 【重要】 (important), 【建议】 (suggestion). Red flags and important
  findings are only given for problems the pull request introduces.

### 6.2 Machine-readable markers

These formats are parsed by the review bot and the maintainer scripts. They are part of the public process and do
not change; a new format would get a new version number.

| Marker | Where | Format |
| --- | --- | --- |
| Head mark | first line of every review summary | `<!-- harness-review-head sha=<40 hex> bot=<lower-case name> -->` |
| Footer | last line of every usable review summary, exactly once | `<!-- harness-review v1 red=N important=N suggest=N -->` |
| Posted record | job log and step summary of the review run | `harness-review-posted id=<comment id> sha256=<64 hex>` |
| Agent mark | first line of every maintainer-side agent comment | `<!-- harness-agent v1 role=<role> kind=<kind> round=N head=<7 hex> [bot-run=<run id>] [in-reply-to=<id>[,<id>...]] -->` |

- **Head mark.** `sha` is the pull request head the summary reviewed, `bot` is `claude` for `claude-pr-review`. Only
  the first line counts, and only on a comment by `github-actions[bot]`: a mark anywhere else is not a summary.
- **Footer.** `red`, `important` and `suggest` are decimal counts of the top-level `- ` items in the 【红旗】,
  【重要】 and 【建议】 sections. The workflow counts the sections itself; if the counts disagree, the footer is
  missing or there are contradicting footers, the summary is posted without any footer, marked unusable, and the
  check fails. The merge criteria read nothing but this line.
- **Posted record.** `id` is the summary's comment id and `sha256` the hash of its UTF-8 body as posted, so a later
  reader can tell whether the summary was edited afterwards.
- **Agent mark.** `role` is one of `impl`, `review`, `orchestrator`. `kind` is one of `disposition` (the disposition
  summary of a review round), `reply` (an answer to one comment or thread), `note` (anything else) and `pr-body` (the
  pull request description). `round` is the review round the comment belongs to (0 before the first review), `head`
  the first seven hex digits of the head it refers to, `bot-run` the run id of the review it answers, `in-reply-to`
  the comment ids it answers. Optional keys come in this order, separated by single spaces. The review bot only
  takes a `kind=disposition` comment as the disposition summary when it comes after the latest review summary, is
  not written by a bot account and its author has write access to the repository.
- **Disposition summary.** A `kind=disposition` comment contains a Markdown table with the columns
  `级别 | 位置 | 摘要 | 处置` (in Chinese, like the comments). The `处置` cell starts with one of `已修`, `修复`,
  `采纳`, `不改`, `不采纳`, `挂账`, `暂不`, `维持`. A 【红旗】 or 【重要】 row whose `处置` starts with `不改`,
  `不采纳`, `挂账`, `暂不` or `维持` needs a waiver recorded by the maintainer before the pull request is merged.
  The table has one row for every 【红旗】 and 【重要】 finding; rows with the same `位置` and `摘要` count once. The table is read
  the way Markdown renders it: a row in a code fence or an HTML comment, or indented by four columns, does not count, and a
  header row needs the delimiter row right below it. Such a row whose `处置` does not start with `已修`, `修复` or `采纳`, that goes on to say the
  fix is not done (`修复中`, `采纳但不修`, `采纳，后续再做`), or that has no commit hash in that cell or to its right, also
  needs a maintainer waiver. A commit hash stands on its own, not as part of a longer word, of a file name or of a link other than
  `/commit/`, and has both a letter and a digit: write a short hash that happens to be only digits or only letters longer.
  For one finding, the row of the highest round and the row posted last must both show it as handled.
- Text written by a model never carries these markers: before posting, the bot breaks up any `<!--` in the summary.

### 6.3 Merge criteria

A pull request into `feature/**` is merged (squash) when all of these hold on its current head:

- the required checks `branch-gate` and `harness-gate` passed;
- `claude-pr-review` succeeded, and the latest review summary's head mark names the current head and its footer
  reads `red=0 important=0` (a red flag or important finding is either fixed or explicitly waived by the maintainer);
- every comment, review, review thread and bot finding has been answered.

The rulesets of `feature/**`, `dev` and `prod` enforce `branch-gate` and `harness-gate` on GitHub (recorded in
`.github/required-checks.json` and `.github/rulesets/`); the maintainer checks the other criteria on every merge.

Pull requests that change the review and merge machinery itself (the paths in `scripts/lib/infra-paths.mjs`) are
merged by the maintainer only. `dev` and `prod` are only merged by the maintainer; tags are only created by the
maintainer.

## 7. Not done yet

These parts of the process are planned but do not exist yet:

- an AI review of fork pull requests triggered by a maintainer comment (until then fork pull requests are reviewed by
  the maintainer);
- a release workflow, a build workflow and a formatting check (there is nothing to build: the harness is PowerShell,
  Lua and C# compiled at run time);
- the Windows self-test job of the harness itself in `ci.yml` (it joins the needs of `harness-gate`).

## 8. Maintenance

reaper-harness has a single maintainer and is maintained on a best-effort basis. Expect a first response within
about a week (security issues: see [SECURITY.md](SECURITY.md)). Every comment on a pull request gets an answer,
including those from review bots.
