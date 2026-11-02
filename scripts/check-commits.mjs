// SPDX-License-Identifier: MIT
//
// Commit and pull request hygiene. The subcommands share one set of criteria; the commit-msg and
// pre-push hooks call into this file as well:
//   commits     --range <A..B> | --json <PR commit list> [--expect <n>]  [--tier same|fork|push]
//               [--pr-author <login>]
//               DCO, Signed-off-by as the only trailer, AI attribution, subject format, author and
//               committer email; dependabot's commits skip the subject, sign-off and identity rules only in
//               a pull request dependabot opened (--pr-author) or in the push tier
//   pr-text     title and body from --title / --body-file, else the PR_TITLE / PR_BODY environment
//               variables; [--fork --author "Name <email>" | --commits-json <PR commit list>];
//               privacy rules, AI attribution, the body's last line is the sign-off
//   branch      --head <name> [--base <name>] [--fork]; naming rules per base; no private numbers or
//               personal needles in the name
//   dependabot  --json <PR commit list>; exit 0 when every commit is dependabot's (author and committer
//               both match), otherwise 1
//   --needles local|ci|ci-optional [--needles-file <path>]  (personal needles, see privacy-needles.mjs)
//   --self-test
// Commits come in three tiers: same (same repository: maintainer identity, sign-off verbatim); fork
// (outside contribution: DCO in its original sense, a sign-off matching the author; AI attribution only
// warns); push (after-the-fact check on long-lived branches: the committer may be a GitHub web merge,
// authors outside the allow list are judged as fork).
// Exit codes: 0 pass, 1 findings, 64 usage error.

import fs from "node:fs";
import { UsageError, assertNodeVersion, caseResult, git, j, reportSelfTest, runCli } from "./lib/check-kit.mjs";
import * as needles from "./lib/privacy-needles.mjs";

const { FAKE_NEEDLE, INVISIBLES, READABLE, plainText, redact, scan } = needles;

export const MAINTAINER = "DLsnows <noreply@synchain.ca>";
export const SIGNOFF = `Signed-off-by: ${MAINTAINER}`;
export const SAME_AUTHORS = ["noreply@synchain.ca", "140901583+dlsnows@users.noreply.github.com"];
const WEB_FLOW = "noreply@github.com";
const COMMITTERS = ["noreply@synchain.ca", WEB_FLOW];
const DEPENDABOT = "49699333+dependabot[bot]@users.noreply.github.com";
const DEPENDABOT_LOGIN = "dependabot[bot]";
export const SUBJECT =
    /^(?:feat|fix|docs|test|refactor|perf|ci|build|chore|style|revert|harden|release|merge)\([a-z0-9][a-z0-9/-]*\): \S/;
const GIT_SUBJECT = /^(?:Merge (?:remote-tracking )?branch '[^']+'(?: of \S+)?(?: into \S+)?|Revert ".+")$/;
// Trailers the way git reads them: blanks before the key and before the colon still make a trailer
const SIGNOFF_LINE = /^\s*signed-off-by\s*:/i;
const TRAILER = /^\s*[A-Za-z0-9][A-Za-z0-9-]*\s*:(?!\/\/)\s*\S/;
const AI_TRAILER = new RegExp(j("^\\s*(?:co-authored", "-by|cla", "ude-session)\\s*:"), "i");

/**
 * Privacy and AI attribution: in the fork tier AI attribution only warns (aiWarns), and an outside author's own
 * email in a sign-off is no leak.
 */
function textFindings(text, { fork = false, aiWarns = fork, personal = [], label = "" } = {}) {
    const errors = [];
    const warns = [];
    const lines = text.split(/\r?\n/);
    for (const f of scan(text, {}, { personal })) {
        if (fork && f.rule.id === "personal-email" && SIGNOFF_LINE.test(lines[f.line - 1])) continue;
        (aiWarns && f.rule.group === "ai" ? warns : errors).push(`${label}line ${f.line} [${f.rule.id}] ${redact(f)}`);
    }
    return { errors, warns };
}

/**
 * An AI attribution trailer on any line. git keeps lines starting with # when the message comes from -m, so a
 * trailer written as a comment line counts too.
 */
export const hasAiTrailer = (lines) => lines.some((l) => AI_TRAILER.test(l.replace(/^\s*#+/, "")));

/** Trailer lines of the last paragraph. As git does: all lines are trailers, or at least a quarter are and one is a sign-off. */
function trailers(text) {
    const paras = text.split(/\n\s*\n/);
    if (paras.length < 2) return [];
    const lines = paras.at(-1).split("\n");
    const found = lines.filter((l) => TRAILER.test(l));
    const block =
        found.length === lines.length || (found.length * 4 >= lines.length && found.some((l) => SIGNOFF_LINE.test(l)));
    return block ? found : [];
}

/** A message the way the rules read it: { text } with LF line ends, or { refused } when the gate for public text says no. */
function readMessage(message) {
    try {
        return { text: plainText(message, "the commit message").replace(/\r\n/g, "\n") };
    } catch (e) {
        return { refused: e.message };
    }
}

/**
 * One commit message. author = { name, email }; merge commits skip the subject and sign-off rules (no new content). The rules read it
 * through plainText, so an invisible character cannot hide a path or a trailer from them; a control character is an error of that message.
 */
export function checkMessage(message, opts = {}) {
    const { tier = "same", author, merge = false, exactlyOne = false, personal = [] } = opts;
    // In the push tier, authors outside the allow list are outside contributors and judged as fork
    const fork = tier === "fork" || (tier === "push" && !!author && !SAME_AUTHORS.includes(author.email.toLowerCase()));
    const read = readMessage(message);
    if (read.refused) return { errors: [read.refused], warns: [] };
    const text = read.text.trimEnd();
    const { errors, warns } = textFindings(text, { fork, personal, label: "message " });
    const lines = text.split("\n");
    const subjectOk = merge || SUBJECT.test(lines[0]) || GIT_SUBJECT.test(lines[0]);
    if (!subjectOk) errors.push("the subject must be type(scope): description");
    if (hasAiTrailer(lines)) (fork ? warns : errors).push("AI attribution trailers are not allowed");
    if (trailers(text).some((l) => !SIGNOFF_LINE.test(l))) (fork ? warns : errors).push("Signed-off-by is the only allowed trailer");
    if (merge) return { errors, warns };
    const signoffs = lines.filter((l) => SIGNOFF_LINE.test(l)).map((l) => l.trim());
    if (fork) {
        const own = author && `signed-off-by: ${author.name} <${author.email}>`.toLowerCase();
        if (!signoffs.some((s) => s.toLowerCase() === own)) errors.push("no Signed-off-by matching the author (DCO)");
    } else if (!signoffs.length) {
        errors.push("missing Signed-off-by (use git commit -s)");
    } else if (signoffs.some((s) => s !== SIGNOFF)) {
        errors.push(`every Signed-off-by line must be "${SIGNOFF}"`);
    } else if (exactlyOne && signoffs.length !== 1) {
        errors.push("exactly one Signed-off-by line is allowed");
    }
    return { errors, warns };
}

/** A dependabot commit: the author email can be forged, so the committer must be GitHub as well. */
export const isDependabot = (c) =>
    c.author.email.toLowerCase() === DEPENDABOT && c.committer.email.toLowerCase() === WEB_FLOW;

/**
 * Whether a dependabot commit skips the subject, sign-off and identity rules. Author and committer emails can be
 * set by anyone with push access, the login of a pull request's author cannot: in a pull request (tier same)
 * only one dependabot opened counts. The push tier knows no pull request author and keeps the email pair; fork
 * pull requests never qualify.
 */
export function dependabotExempt(c, { tier, prAuthor }) {
    if (!isDependabot(c)) return false;
    return tier === "push" || (tier === "same" && prAuthor === DEPENDABOT_LOGIN);
}

/** One commit: c = { sha, parents, author: {name, email}, committer: {name, email}, message }; prAuthor: the PR author's login. */
export function checkCommit(c, { tier = "same", prAuthor, personal = [] } = {}) {
    const ae = c.author.email.toLowerCase();
    const ce = c.committer.email.toLowerCase();
    if (dependabotExempt(c, { tier, prAuthor })) {
        // Only the subject, sign-off and identity rules are waived: privacy rules and AI attribution stay errors
        const read = readMessage(c.message);
        if (read.refused) return { errors: [read.refused], warns: [] };
        const { errors } = textFindings(read.text, { fork: true, aiWarns: false, personal });
        if (hasAiTrailer(read.text.split("\n"))) errors.push("AI attribution trailers are not allowed");
        return { errors, warns: [] };
    }
    const errors = [];
    if (tier === "same" && !SAME_AUTHORS.includes(ae)) errors.push("the author email is not on the same-repository allow list");
    if (tier !== "fork" && !COMMITTERS.includes(ce)) errors.push("the committer email is not on the allow list");
    const r = checkMessage(c.message, { tier, author: c.author, merge: c.parents > 1, personal });
    return { errors: [...errors, ...r.errors], warns: r.warns };
}

/** authors: acceptable signers for a fork PR ("Name <email>"); the body's last line must match one of them. */
export function checkPrText({ title, body, fork = false, authors = [], personal = [] }) {
    const t = textFindings(title, { fork, personal, label: "title " });
    const b = textFindings(body, { fork, personal, label: "body " });
    const errors = [...t.errors, ...b.errors];
    if (!SUBJECT.test(title)) errors.push("the PR title must be type(scope): description");
    const last = body.trimEnd().split(/\r?\n/).at(-1).trim();
    if (fork) {
        const ok = authors.some((a) => last.toLowerCase() === `signed-off-by: ${a}`.toLowerCase());
        if (!ok) errors.push("the body's last line must be a Signed-off-by matching a commit author");
    } else if (last !== SIGNOFF) {
        errors.push(`the body's last line must be "${SIGNOFF}"`);
    }
    return { errors, warns: [...t.warns, ...b.warns] };
}

const LONG_LIVED = /^(?:dev|prod|staging|main|master|feature\/.*)$/;
/**
 * Source branch rules per base: feature/** takes only this repository's feat/<slug>; dev takes feature/*
 * and dependabot/*; prod takes only dev. Fork PRs go to dev only, under any name that is not a
 * long-lived branch name. No base (the pre-push hook) means the feat/<slug> rule.
 */
export function checkBranch({ head, base, fork = false, personal = [] }) {
    const errors = [];
    if (fork) {
        if (base !== "dev") errors.push("fork PRs can only target dev");
        if (LONG_LIVED.test(head)) errors.push("a fork branch must not use a long-lived branch name");
    } else {
        const want =
            !base || base.startsWith("feature/")
                ? /^feat\/[a-z0-9][a-z0-9-]*$/
                : base === "dev"
                  ? /^(?:feature\/[a-z0-9][a-z0-9.-]*|dependabot\/\S+)$/
                  : base === "prod"
                    ? /^dev$/
                    : null;
        if (!want) errors.push("the base can only be feature/*, dev or prod");
        else if (!want.test(head)) errors.push(`the branch name does not follow the naming rule for base=${base || "feature/*"}`);
    }
    for (const f of scan(head, {}, { personal })) errors.push(`the branch name contains [${f.rule.id}] ${redact(f)}`);
    return errors;
}

/**
 * A PR commit list: one array; several arrays back to back (gh api --paginate); a nested array (--slurp);
 * or one object per line (--jq '.[]'). All flattened into a list of commit objects.
 */
export function parseCommitList(text) {
    const values = [];
    let depth = 0;
    let start = 0;
    let str = false;
    let esc = false;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (str) {
            if (esc) esc = false;
            else if (c === "\\") esc = true;
            else if (c === '"') str = false;
        } else if (c === '"' && depth > 0) {
            str = true;
        } else if (c === "[" || c === "{") {
            if (depth++ === 0) start = i;
        } else if ((c === "]" || c === "}") && depth > 0) {
            if (--depth === 0) values.push(JSON.parse(text.slice(start, i + 1)));
        } else if (depth === 0 && !/\s/.test(c)) {
            throw new Error("the commit list contains something that is not JSON");
        }
    }
    if (depth || str) throw new Error("the commit list is truncated");
    const flat = (v) => (Array.isArray(v) ? v.flatMap(flat) : [v]);
    const list = values.flatMap(flat);
    if (list.some((c) => !c?.sha || !c.commit?.author || !c.commit?.committer)) {
        throw new Error("an entry of the commit list lacks fields");
    }
    return list;
}

/** A PR commit list as commits. expect: the commit count the PR reports (undefined: not compared). */
export function commitsFromJson(text, expect) {
    const list = parseCommitList(text);
    // The list endpoint returns at most 250 commits, and fewer if only one page was fetched: compare with the PR
    if (expect !== undefined && list.length !== Number(expect)) {
        throw new Error(`the commit list has ${list.length} commits, the PR reports ${expect}`);
    }
    if (list.length < 1 || list.length >= 250) throw new Error(`${list.length} commits is outside 1-249`);
    return list.map((c) => ({
        sha: c.sha,
        parents: c.parents.length,
        author: c.commit.author,
        committer: c.commit.committer,
        message: c.commit.message,
    }));
}

function readCommits({ range, json, expect }, cwd) {
    if (json) return commitsFromJson(fs.readFileSync(json, "utf8"), expect);
    const out = git(["log", "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%B%x1e", range], { cwd });
    return out
        .split("\x1e")
        .map((s) => s.replace(/^\n/, ""))
        .filter(Boolean)
        .map((s) => {
            const [sha, parents, an, ae, cn, ce, message] = s.split("\x1f");
            return {
                sha,
                parents: parents.split(" ").filter(Boolean).length,
                author: { name: an, email: ae },
                committer: { name: cn, email: ce },
                message,
            };
        });
}

// ---- self-test -------------------------------------------------------------------------------
const ME = { name: "DLsnows", email: "noreply@synchain.ca" };
const OUTSIDER = { name: "Ada Lee", email: j("ada", "@", "gmail", ".com") };
const WEB = { name: "GitHub", email: WEB_FLOW };
const BOT = { name: "dependabot[bot]", email: DEPENDABOT };
const msg = (...body) => ["ci(checks): add checks", "", "One line of explanation.", "", ...body].join("\n");
const commit = (message, extra = {}) => ({ parents: 1, author: ME, committer: ME, message, ...extra });
const apiCommit = (sha) => ({ sha, parents: [{}], commit: { author: ME, committer: ME, message: msg(SIGNOFF) } });

export function selfTest() {
    const cases = [];
    const t = (label, bad, errors) => cases.push({ label, bad, passed: bad ? errors.length > 0 : errors.length === 0 });
    const c = (label, bad, x, tier, prAuthor) => t(label, bad, checkCommit(x, { tier, prAuthor }).errors);
    const throws = (label, fn) => {
        let threw = false;
        try {
            fn();
        } catch {
            threw = true;
        }
        cases.push({ label, bad: true, passed: threw });
    };
    c("same: maintainer identity and sign-off", false, commit(msg(SIGNOFF)));
    c("same: identical sign-offs repeated (squash merge)", false, commit(msg(SIGNOFF, SIGNOFF)));
    c("same: another sign-off mixed in", true, commit(msg(SIGNOFF, "Signed-off-by: Other <other@example.com>")));
    c("same: no sign-off", true, commit(msg()));
    c("same: co-author trailer", true, commit(msg(j("Co-Authored", "-By: Someone <s@example.com>"), SIGNOFF)));
    c("same: co-author trailer with a blank before the colon", true, commit(msg(j("Co-authored", "-by : Someone <s@example.com>"), SIGNOFF)));
    c("same: co-author trailer indented", true, commit(msg(j(" Co-authored", "-by: Someone <s@example.com>"), SIGNOFF)));
    c("same: co-author line outside the trailer block", true, commit(msg(j("Co-authored", "-by: Someone <s@example.com>"), "", SIGNOFF)));
    // git commit -m keeps lines starting with #
    c("same: co-author trailer written as a # line", true, commit(msg(j("# Co-authored", "-by: Someone <s@example.com>"), "", SIGNOFF)));
    c("same: co-author trailer after ## and blanks", true, commit(msg(j("  ##  Co-authored", "-by: Someone <s@example.com>"), "", SIGNOFF)));
    c("same: an ordinary # line", false, commit(msg("# 1 of 2: see the issue", "", SIGNOFF)));
    c("same: session trailer", true, commit(msg(j("Cla", "ude-Session: abc"), SIGNOFF)));
    c("same: generated-with line", true, commit(msg(j("Generated with Cla", "ude Code"), "", SIGNOFF)));
    c("same: AI email", true, commit(msg(j("see noreply@anthr", "opic.com"), "", SIGNOFF)));
    // Invisible characters are removed before the rules read the message: each of these splits a local path
    const splitPath = (ch) => j("see C:", "\\", "Us", ch, "ers", "\\", "someone");
    for (const [name, ch] of Object.entries(INVISIBLES)) {
        c(`same: a local path split by ${name}`, true, commit(msg(splitPath(ch), "", SIGNOFF)));
    }
    c("same: the path without a split is found as well", true, commit(msg(splitPath(""), "", SIGNOFF)));
    c("same: a co-author trailer split by a zero-width space", true, commit(msg(j("Co-\u200bauthored", "-by: Someone <s@example.com>"), "", SIGNOFF)));
    c("same: a sign-off with a zero-width space reads as the sign-off", false, commit(msg(`${SIGNOFF}\u200b`)));
    c("same: an emoji with a joiner, a warning sign and Persian text", false, commit(msg(READABLE, "", SIGNOFF)));
    t("same: a control character is an error of that message, no crash", true, checkMessage(msg("colour \u001b[31m", "", SIGNOFF)).errors.filter((e) => /control character U\+001B/.test(e)));
    t("same: a CR without its LF is an error of that message", true, checkMessage(msg("one\rtwo", "", SIGNOFF)).errors.filter((e) => /control character U\+000D/.test(e)));
    c("same: CRLF line ends are no control character", false, commit(msg(SIGNOFF).replace(/\n/g, "\r\n")));
    c("same: another trailer", true, commit(msg("Reviewed-by: Someone <s@example.com>", SIGNOFF)));
    c("same: prose line inside the trailer block", true, commit(msg("note", "Reviewed-by: Someone <s@example.com>", SIGNOFF)));
    c("same: sign-off variant", true, commit(msg("Signed-off-by : DLsnows <noreply@synchain.ca>")));
    c("same: bad subject", true, commit(`update stuff\n\n${SIGNOFF}`));
    c("same: subject without scope", true, commit(`ci: add checks\n\n${SIGNOFF}`));
    c("same: card number in the subject", true, commit(`ci(checks): finish ${j("R", "H-01")}\n\n${SIGNOFF}`));
    c("same: author not on the allow list", true, commit(msg(SIGNOFF), { author: OUTSIDER }));
    c("same: committer not on the allow list", true, commit(msg(SIGNOFF), { committer: OUTSIDER }));
    const merge = "Merge remote-tracking branch 'origin/feature/v1' into feat/x";
    c("same: git's default merge subject", false, commit(`${merge}\n\n${SIGNOFF}`));
    c("same: merge commit needs no sign-off", false, commit("Merge pull request #3 from synchain-oss/feat/x", { parents: 2 }));
    // dependabot: the exemption needs a pull request dependabot opened (or the push tier); AI attribution stays an error
    const bump = (...body) => commit(["Bump x from 1.0 to 1.1", "", ...body, "", "Signed-off-by: dependabot[bot] <support@github.com>"].join("\n"), { author: BOT, committer: WEB });
    c("dependabot: its own pull request", false, bump("Bumps x."), "same", "dependabot[bot]");
    c("dependabot: push tier", false, bump("Bumps x."), "push");
    c("dependabot: a dependabot-looking commit in a PR someone else opened", true, bump("Bumps x."), "same", "DLsnows");
    c("dependabot: no PR author given", true, bump("Bumps x."), "same");
    c("dependabot: forged author (committer is not GitHub)", true, { ...bump("Bumps x."), committer: ME }, "same", "dependabot[bot]");
    c("dependabot: messages are still scanned", true, bump(OUTSIDER.email), "same", "dependabot[bot]");
    c("dependabot: an AI trailer is an error", true, bump(j("Co-authored", "-by: Someone <s@example.com>")), "same", "dependabot[bot]");
    c("dependabot: an AI trailer as a # line is an error", true, bump(j("# Co-authored", "-by: Someone <s@example.com>")), "same", "dependabot[bot]");
    c("dependabot: an AI attribution line is an error", true, bump(j("Generated with Cla", "ude Code")), "same", "dependabot[bot]");
    c("dependabot: a local path split by a zero-width space is found", true, bump(splitPath("\u200b")), "same", "dependabot[bot]");
    c("dependabot: an AI trailer split by a zero-width space is found", true, bump(j("Co-\u200bauthored", "-by: Someone <s@example.com>")), "same", "dependabot[bot]");
    t("dependabot: a control character is an error of that message", true, checkCommit(bump("colour \u001b[31m"), { tier: "same", prAuthor: "dependabot[bot]" }).errors.filter((e) => /control character U\+001B/.test(e)));
    c("dependabot: push tier with an AI trailer", true, bump(j("Co-authored", "-by: Someone <s@example.com>")), "push");
    c("fork: a dependabot-looking commit gets no exemption", true, bump("Bumps x."), "fork", "dependabot[bot]");
    const own = `Signed-off-by: ${OUTSIDER.name} <${OUTSIDER.email}>`;
    c("fork: real author email with own sign-off", false, commit(msg(own), { author: OUTSIDER, committer: OUTSIDER }), "fork");
    c("fork: sign-off does not match the author", true, commit(msg(SIGNOFF), { author: OUTSIDER, committer: OUTSIDER }), "fork");
    c("fork: an emoji with a joiner, a warning sign and Persian text", false, commit(msg(READABLE, "", own), { author: OUTSIDER, committer: OUTSIDER }), "fork");
    c("fork: a local path split by a zero-width space is found", true, commit(msg(splitPath("\u200b"), "", own), { author: OUTSIDER, committer: OUTSIDER }), "fork");
    const forkAi = checkCommit(commit(msg(j("Co-Authored", "-By: Bot <b@example.com>"), own), { author: OUTSIDER }), { tier: "fork" });
    t("fork: AI trailer only warns", false, forkAi.warns.length ? forkAi.errors : ["no warning"]);
    c("push: web merge of an outside contribution", false, commit(msg(own), { author: OUTSIDER, committer: WEB }), "push");
    c("push: maintainer author without sign-off", true, commit(msg(), { committer: WEB }), "push");
    t("commit-msg: exactly one sign-off", true, checkMessage(msg(SIGNOFF, SIGNOFF), { exactlyOne: true }).errors);

    const b = (label, bad, args) => t(label, bad, checkBranch({ personal: [FAKE_NEEDLE], ...args }));
    b("branch: feat/<slug>", false, { head: "feat/check-scripts", base: "feature/v1" });
    b("branch: not feat/", true, { head: "fix/check-scripts", base: "feature/v1" });
    b("branch: card number", true, { head: j("feat/r", "h-01-checks") });
    b("branch: personal needle", true, { head: `feat/${FAKE_NEEDLE}` });
    b("branch: dev to prod", false, { head: "dev", base: "prod" });
    b("branch: feature line straight to prod", true, { head: "feature/v1", base: "prod" });
    b("branch: feature line to dev", false, { head: "feature/v1", base: "dev" });
    b("branch: dependabot to dev", false, { head: "dependabot/github_actions/x-1.2", base: "dev" });
    b("branch: feat/ straight to dev", true, { head: "feat/x", base: "dev" });
    b("branch: unknown base", true, { head: "feat/x", base: "main" });
    b("branch: fork with a long-lived name", true, { head: "dev", base: "dev", fork: true });
    b("branch: fork with an ordinary name", false, { head: "patch-1", base: "dev", fork: true });
    b("branch: fork to prod", true, { head: "patch-1", base: "prod", fork: true });
    b("branch: fork to the feature line", true, { head: "patch-1", base: "feature/v1", fork: true });
    b("branch: fork branch with a personal needle", true, { head: `patch-${FAKE_NEEDLE}`, base: "dev", fork: true });

    const body = (...l) => ["## 做了什么", "加入检查脚本。【重要】项已清零。", "", ...l].join("\n");
    const pr = (label, bad, args) => t(label, bad, checkPrText({ title: "ci(checks): add checks", ...args }).errors);
    const outsider = `${OUTSIDER.name} <${OUTSIDER.email}>`;
    pr("PR: body ends with the sign-off", false, { body: body(SIGNOFF) });
    pr("PR: no sign-off", true, { body: body("thanks") });
    pr("PR: sign-off not on the last line", true, { body: body(SIGNOFF, "thanks") });
    pr("PR: card number in the title", true, { title: `ci(checks): ${j("R", "N05")} wrap-up`, body: body(SIGNOFF) });
    pr("PR: bad title", true, { title: "add checks", body: body(SIGNOFF) });
    pr("PR: generated-with line", true, { body: body(j("Generated with [Cla", "ude Code]"), SIGNOFF) });
    pr("PR: attribution link", true, { body: body(j("https://cla", "ude.com/cla", "ude-code"), SIGNOFF) });
    pr("PR: private section number", true, { body: body(j("see 0", "6 §", "2"), SIGNOFF) });
    pr("PR: fork author's sign-off", false, { fork: true, authors: [outsider], body: body(own) });
    pr("PR: fork sign-off is not a commit author", true, { fork: true, authors: ["Bob <bob@example.com>"], body: body(own) });

    const page = (...shas) => JSON.stringify(shas.map(apiCommit));
    t("commit list: pages back to back", false, parseCommitList(`${page("a", "b")}${page("c")}`).length === 3 ? [] : ["x"]);
    t("commit list: --slurp nesting", false, parseCommitList(`[${page("a")},${page("b")}]`).length === 2 ? [] : ["x"]);
    const ndjson = ["a", "b"].map((s) => JSON.stringify(apiCommit(s))).join("\n");
    t("commit list: one object per line", false, parseCommitList(ndjson).length === 2 ? [] : ["x"]);
    throws("commit list: truncated JSON", () => parseCommitList(page("a").slice(0, -2)));
    throws("commit list: entry lacks fields", () => parseCommitList('[{"sha":"a"}]'));
    throws("commit list: trailing garbage", () => parseCommitList(`${page("a")} x`));
    t("commit list: count equals the PR's", false, commitsFromJson(page("a", "b"), "2").length === 2 ? [] : ["x"]);
    throws("commit list: count differs from the PR's", () => commitsFromJson(page("a", "b"), "3"));
    throws("commit list: empty", () => commitsFromJson("[]"));
    throws("commit list: 250 commits (the list endpoint's limit)", () => commitsFromJson(page(...Array.from({ length: 250 }, (_, i) => `s${i}`))));
    const botCommit = { author: BOT, committer: WEB };
    t("dependabot: author and committer both match", false, isDependabot(botCommit) ? [] : ["not recognized"]);
    t("dependabot: committer is not GitHub", true, isDependabot({ ...botCommit, committer: ME }) ? [] : ["x"]);
    return caseResult(cases);
}

const USAGE = "usage: see the header of scripts/check-commits.mjs (commits | pr-text | branch | dependabot | --self-test)";

function main(argv) {
    assertNodeVersion();
    const [cmd, ...rest] = argv;
    const opt = (k) => (rest.includes(k) ? rest[rest.indexOf(k) + 1] : undefined);
    const has = (k) => rest.includes(k);
    if (cmd === "--self-test") return reportSelfTest("check-commits", selfTest());
    const cwd = process.cwd();
    const personal = () => {
        const p = needles.loadPersonalNeedles({ cwd, ...needles.needlesArgs(rest) });
        p.notes.forEach((n) => console.log(n));
        return p.needles;
    };
    const body = () =>
        opt("--body-file")
            ? plainText(fs.readFileSync(opt("--body-file")), "the PR body")
            : plainText(process.env.PR_BODY ?? "", "PR_BODY");
    let errors = [];
    let warns = [];
    if (cmd === "commits") {
        const tier = opt("--tier") || "same";
        if (!["same", "fork", "push"].includes(tier)) throw new UsageError(`unknown tier ${tier}`);
        if (!opt("--range") === !opt("--json")) throw new UsageError("commits needs exactly one of --range and --json");
        const needleList = personal();
        const list = readCommits({ range: opt("--range"), json: opt("--json"), expect: opt("--expect") }, cwd);
        for (const c of list) {
            const r = checkCommit(c, { tier, prAuthor: opt("--pr-author"), personal: needleList });
            errors.push(...r.errors.map((e) => `${c.sha.slice(0, 7)} ${e}`));
            warns.push(...r.warns.map((w) => `${c.sha.slice(0, 7)} ${w}`));
        }
        console.log(`checked ${list.length} commit(s) (${tier})`);
    } else if (cmd === "pr-text") {
        const title = plainText(opt("--title") ?? process.env.PR_TITLE ?? "", "the PR title");
        const authors = [
            ...(opt("--author") ? [opt("--author")] : []),
            ...(opt("--commits-json")
                ? parseCommitList(fs.readFileSync(opt("--commits-json"), "utf8")).map(
                      (c) => `${c.commit.author.name} <${c.commit.author.email}>`,
                  )
                : []),
        ];
        ({ errors, warns } = checkPrText({ title, body: body(), fork: has("--fork"), authors, personal: personal() }));
    } else if (cmd === "dependabot") {
        // Only answers "is this a pure dependabot PR": the workflow uses it to decide whether to skip the body check
        if (!opt("--json")) throw new UsageError("dependabot needs --json");
        const list = parseCommitList(fs.readFileSync(opt("--json"), "utf8"));
        const all = list.length > 0 && list.every((c) => isDependabot(c.commit));
        console.log(`check-commits dependabot: ${all ? "every commit is dependabot's" : "not a pure dependabot PR"}`);
        return all ? 0 : 1;
    } else if (cmd === "branch") {
        if (!opt("--head")) throw new UsageError("branch needs --head");
        errors = checkBranch({ head: opt("--head"), base: opt("--base"), fork: has("--fork"), personal: personal() });
    } else {
        throw new UsageError(USAGE);
    }
    for (const w of warns) console.log(`::warning::${w}`);
    for (const e of errors) console.error(`  ${e}`);
    console.log(`check-commits ${cmd}: ${errors.length ? `FAILED (${errors.length})` : "passed"}`);
    return errors.length ? 1 : 0;
}

runCli("check-commits", import.meta.url, main);
