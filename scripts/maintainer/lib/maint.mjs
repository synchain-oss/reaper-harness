// SPDX-License-Identifier: MIT
//
// Node side of the maintainer wrappers (scripts/maintainer/*.ps1). The criteria live in the repository's own scripts and
// are imported, never copied: the review summary formats come from scripts/review-bot.mjs, the commit message and PR text
// rules from scripts/check-commits.mjs, the personal needles from scripts/lib/privacy-needles.mjs and the infrastructure
// path list from scripts/lib/infra-paths.mjs. What is left here is what only the wrappers need: the facts of a posted
// summary (footer on the last line exactly once, run id, per-item findings), the agent marker and the disposition lookup
// built on findPrevious, and thin command-line bridges so that the PowerShell side asks Node instead of re-implementing a rule.
//   node scripts/maintainer/lib/maint.mjs review-state --file <issue comments JSON> --writers <login,...> [--bot claude]
//        newest bot summary (head, run link, footer and count check) and the disposition after it (author must be in
//        --writers); also every bot summary (footer, run id, per-item findings, created_at / updated_at, body sha256)
//        and the run ids referenced by every disposition
//   node scripts/maintainer/lib/maint.mjs infra --file <path JSON array> [--module <infra-paths.mjs>]
//        the paths that touch the infrastructure list; --module names another list module and is for the self-test only
//   node scripts/maintainer/lib/maint.mjs message --file <message> [--merge] [--exactly-one] [--needles <mode>] [--needles-file <path>]
//        checkMessage of check-commits.mjs, same-repository tier: { errors, warns }
//   node scripts/maintainer/lib/maint.mjs pr-text --file <JSON { title, body }> [--needles <mode>] [--needles-file <path>]
//        checkPrText of check-commits.mjs: { errors, warns }
//   node scripts/maintainer/lib/maint.mjs text --file <text>
//        { aiTrailerLines } : the lines hasAiTrailer of check-commits.mjs takes for an AI attribution trailer, any author
//   node scripts/maintainer/lib/maint.mjs same-authors --file <ignored>
//        { authors } : the author emails check-commits.mjs allows for the same repository
//   node scripts/maintainer/lib/maint.mjs --self-test
// Output is one JSON line; a failure prints { error } and exits 2 (the PowerShell side treats that as an error, never as a pass).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { SAME_AUTHORS, SIGNOFF, checkMessage, checkPrText, hasAiTrailer } from "../../check-commits.mjs";
import { FOOTER, findPrevious, headMark, postedRecord, sectionCounts, validateSummary } from "../../review-bot.mjs";
import { assertNodeVersion, isMain, j } from "../../lib/check-kit.mjs";
import { FAKE_NEEDLE, loadPersonalNeedles, needlesArgs, plainText } from "../../lib/privacy-needles.mjs";

/** Run page link on the second line of a bot summary. */
const RUN_LINK = /\/actions\/runs\/(\d+)/;
/** Agent marker, first line of every comment we write: see CONTRIBUTING.md (review process). */
const AGENT_MARK =
    /^<!-- harness-agent v1 role=(impl|review|orchestrator) kind=([a-z-]+) round=(\d+) head=([0-9a-f]{7,40})((?: [a-z-]+=[^\s>]+)*) -->$/;

/** Body sha256 the way the bot records it (postedRecord of review-bot.mjs): CRLF folded to LF, then UTF-8 bytes. */
export function bodySha256(body) {
    return postedRecord("0", (body || "").replace(/\r\n/g, "\n")).sha256;
}

/**
 * Facts of a posted bot summary: footer exactly one line and the last line, counts consistent (validateSummary of the review
 * bot), plus the head marker and the run id from the link in the first three lines. The reason of an unusable summary is
 * validateSummary's own text.
 */
export function summaryFacts(body) {
    const lines = body.replace(/\r\n/g, "\n").trimEnd().split("\n");
    const footers = lines.filter((l) => FOOTER.test(l.trim()));
    const base = {
        head: headMark(body)?.sha || null,
        runId: RUN_LINK.exec(lines.slice(0, 3).join("\n"))?.[1] || null,
    };
    if (footers.length !== 1)
        return { ...base, ok: false, reason: footers.length ? "more than one footer line" : "machine-readable footer missing" };
    if (!FOOTER.test(lines.at(-1).trim())) return { ...base, ok: false, reason: "footer is not the last line" };
    const v = validateSummary(body);
    if (!v.ok) return { ...base, ok: false, reason: v.reason };
    const [, red, important, suggest] = FOOTER.exec(footers[0].trim());
    return { ...base, ok: true, reason: null, red: +red, important: +important, suggest: +suggest };
}

/**
 * Findings listed in a bot summary (top-level list items under the three sections). The same rules as sectionCounts of the
 * review bot, which cannot list the items; the self-test compares the two on every sample so that they cannot drift apart.
 */
export function summaryItems(body) {
    const items = [];
    let level = null;
    let fence = false;
    let counting = true;
    for (const l of body.replace(/\r\n/g, "\n").split("\n")) {
        if (/^\s*(?:```|~~~)/.test(l)) {
            fence = !fence;
            continue;
        }
        if (fence) continue;
        const h = /^(#{1,6})\s/.exec(l);
        if (h && h[1].length > 2 && level === "建议") counting = false;
        if (h && h[1].length <= 2) {
            level = /^##\s+【(红旗|重要|建议)】/.exec(l)?.[1] || null;
            counting = true;
            continue;
        }
        const item = /^(?:[-*+]|\d+[.)])\s+(\S.*)$/.exec(l);
        if (level && counting && item && !/^无[。.]?\s*$/.test(item[1])) items.push({ level, text: item[1] });
    }
    return items;
}

/** First-line agent marker as { role, kind, round, head, extra }, or null. */
export function agentMarker(body) {
    const m = AGENT_MARK.exec((body || "").split(/\r?\n/, 1)[0]);
    if (!m) return null;
    const extra = Object.fromEntries(
        m[5]
            .trim()
            .split(/\s+/)
            .filter(Boolean)
            .map((kv) => kv.split("=")),
    );
    return { role: m[1], kind: m[2], round: +m[3], head: m[4], extra };
}

/** comments: issue comments array as the API returns it (ascending). writers: logins with write access to the repo. */
export function reviewState(comments, writers, bot = "claude") {
    const trusted = (c) => writers.includes(c.user?.login);
    const prev = findPrevious(comments, bot, trusted);
    const isSummary = (c) => c.user?.login === "github-actions[bot]" && headMark(c.body)?.bot === bot;
    const summaries = comments.filter(isSummary).map((c) => ({
        id: c.id,
        createdAt: c.created_at,
        // the bot only creates, never edits: a different updated_at means the summary was edited after posting
        updatedAt: c.updated_at ?? c.created_at,
        sha256: bodySha256(c.body || ""),
        ...summaryFacts(c.body || ""),
        items: summaryItems(c.body || ""),
    }));
    const dispositions = comments
        .filter((c) => trusted(c) && !/\[bot\]$/.test(c.user?.login || ""))
        .map((c) => agentMarker(c.body))
        .filter((m) => m && m.kind === "disposition");
    const dm = prev.disposition ? agentMarker(prev.disposition) : null;
    return {
        rounds: prev.rounds,
        summary: summaries.at(-1) || null,
        summaries,
        disposition: dm ? { round: dm.round, head: dm.head, botRun: dm.extra["bot-run"] || null, role: dm.role } : null,
        dispositionRuns: dispositions.map((m) => m.extra["bot-run"] || null).filter(Boolean),
    };
}

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_INFRA = path.resolve(HERE, "..", "..", "lib", "infra-paths.mjs");

/** Paths that match the infrastructure list. The module is the single source; a missing module is an error. */
export async function infraHits(paths, modulePath = DEFAULT_INFRA) {
    let m;
    try {
        m = await import(pathToFileURL(modulePath).href);
    } catch (e) {
        const missing = e.code === "ERR_MODULE_NOT_FOUND" || e.code === "ENOENT";
        throw new Error(
            missing
                ? "scripts/lib/infra-paths.mjs (the single list of infrastructure paths) is missing: cannot decide whether maintainer approval is needed"
                : `loading infra-paths.mjs failed: ${e.message}`,
        );
    }
    if (typeof m.isInfraPath !== "function") throw new Error("infra-paths.mjs does not export isInfraPath");
    return paths.filter((p) => m.isInfraPath(p));
}

/** A commit or squash message under the same-repository rules of check-commits.mjs. */
export function messageErrors(text, { merge = false, exactlyOne = false, personal = [] } = {}) {
    const r = checkMessage(text, { tier: "same", merge, exactlyOne, personal });
    return { errors: r.errors, warns: r.warns };
}

/** A PR title and body under checkPrText of check-commits.mjs (the same text-only reading as its command line). */
export function prTextErrors(title, body, personal = []) {
    const r = checkPrText({ title: plainText(title, "the PR title"), body: plainText(body, "the PR body"), personal });
    return { errors: r.errors, warns: r.warns };
}

/** Numbers of the lines that hasAiTrailer takes for an AI attribution trailer (also as a # line, which git keeps with -m). */
export function aiTrailerLines(text) {
    return text.split(/\r?\n/).flatMap((l, i) => (hasAiTrailer([l]) ? [i + 1] : []));
}

export function selfTest() {
    const cases = [];
    const t = (label, bad, flagged) => cases.push({ label, bad, passed: bad ? flagged : !flagged });
    const sha = "a".repeat(40);
    const mark = `<!-- harness-review-head sha=${sha} bot=claude -->`;
    const foot = (r, i, s) => `<!-- harness-review v1 red=${r} important=${i} suggest=${s} -->`;
    const body = (reds, imps, sugs, footer) =>
        [
            mark,
            "_审查对象：`aaaaaaa` · [运行记录](https://github.com/o/r/actions/runs/123)_",
            "",
            "## 结论",
            "ok",
            "## 【红旗】",
            ...(reds.length ? reds : ["- 无"]),
            "## 【重要】",
            ...(imps.length ? imps : ["- 无"]),
            "## 【建议】",
            ...(sugs.length ? sugs : ["- 无"]),
            footer,
        ].join("\n");
    const clean = body([], [], ["- a"], foot(0, 0, 1));
    const facts = summaryFacts(clean);
    t(
        "summary: clean footer parsed with run id and head",
        false,
        !(facts.ok && facts.red === 0 && facts.important === 0 && facts.suggest === 1 && facts.runId === "123" && facts.head === sha),
    );
    t("summary: a head mark typed in the middle of a body gives no head", true, summaryFacts(`## quote\n${mark}\n${foot(0, 0, 0)}`).head === null);
    t("summary: no footer is unusable", true, !summaryFacts(clean.replace(foot(0, 0, 1), "")).ok);
    t("summary: no footer says so", true, summaryFacts(clean.replace(foot(0, 0, 1), "")).reason === "machine-readable footer missing");
    t("summary: two different footers are unusable", true, !summaryFacts(`${clean}\n${foot(0, 1, 1)}`).ok);
    t("summary: footer not on the last line is unusable", true, !summaryFacts(`${clean}\ntrailing text`).ok);
    t("summary: footer not on the last line says so", true, summaryFacts(`${clean}\ntrailing text`).reason === "footer is not the last line");
    t("summary: duplicated identical footer is unusable (exactly one line)", true, !summaryFacts(`${clean}\n${foot(0, 0, 1)}`).ok);
    t("summary: footer undercounts an important item", true, !summaryFacts(body([], ["- real"], ["- a"], foot(0, 0, 1))).ok);
    t("summary: footer overcounts", true, !summaryFacts(body([], [], ["- a"], foot(0, 0, 3))).ok);
    t("summary: the reason of a count mismatch is the review bot's own", true, /^机读尾注的条数与正文不符/.test(summaryFacts(body([], [], ["- a"], foot(0, 0, 3))).reason));
    t("summary: important item hidden under a subheading is still counted", true, !summaryFacts(body([], ["### x", "- hidden"], ["- a"], foot(0, 0, 1))).ok);
    t(
        "summary: bullet under a subheading of the suggestion section is not a suggestion",
        false,
        !summaryFacts(body([], [], ["- k1", "### incremental", "- c1", "- c2"], foot(0, 0, 1))).ok,
    );
    t("summary: items inside a fenced block are not counted", false, !summaryFacts(body([], [], ["```", "- fake", "```", "- a"], foot(0, 0, 1))).ok);
    t("summary: a missing section is unusable", true, !summaryFacts(clean.replace("## 【重要】\n- 无\n", "")).ok);
    t("summary: a duplicated section is unusable", true, !summaryFacts(clean.replace("## 【建议】", "## 【重要】\n## 【建议】")).ok);
    t("summary: CRLF round trip is usable", false, !summaryFacts(clean.replace(/\n/g, "\r\n")).ok);
    const linkBelow = body([], [], ["- see https://github.com/o/r/actions/runs/999"], foot(0, 0, 1)).replace(/_审查对象[^\n]*\n/, "");
    t("summary: a run link below the first three lines is not the run of the summary", false, summaryFacts(linkBelow).runId !== null);
    const lv = (text) => summaryItems(text).map((i) => i.level).join(",");
    t("items: levels listed in order", false, lv(body(["- r"], ["- i"], ["- s"], foot(1, 1, 1))) !== "红旗,重要,建议");
    t("items: nothing listed for a clean summary except the suggestion", false, lv(clean) !== "建议");
    t("items: items inside a fenced block are not listed", false, lv(body([], [], ["```", "- fake", "```", "- a"], foot(0, 0, 1))) !== "建议");
    t("items: an item under a subheading of the suggestion section is not listed", false, lv(body([], [], ["- a", "### incremental", "- c"], foot(0, 0, 1))) !== "建议");
    // the listing and the review bot's counter must agree on every sample, otherwise a footer could pass on one and not the other
    const samples = [
        clean,
        body(["- r"], ["- i1", "- i2"], ["- s"], foot(1, 2, 1)),
        body([], ["### x", "- hidden"], ["- a"], foot(0, 1, 1)),
        body([], [], ["- k1", "### incremental", "- c1"], foot(0, 0, 1)),
        body([], [], ["```", "- fake", "```", "- a", "1. b", "* c"], foot(0, 0, 3)),
        body(["- 无。"], [], ["- 无"], foot(0, 0, 0)),
    ];
    const agree = samples.every((s) => {
        const listed = summaryItems(s);
        const { counts } = sectionCounts(s.split("\n").filter((l) => !/^<!-- harness-review v1 /.test(l)).join("\n"));
        return ["红旗", "重要", "建议"].every((n) => listed.filter((i) => i.level === n).length === (counts[n] ?? 0));
    });
    t("items: the listing agrees with sectionCounts of the review bot on every sample", false, !agree);
    const sums = (text, updated = "2026-01-01T00:00:00Z") =>
        reviewState([{ id: 1, user: { login: "github-actions[bot]" }, created_at: "2026-01-01T00:00:00Z", updated_at: updated, body: text }], []);
    t("state: summary recognised", false, sums(clean).summaries.length !== 1);
    t("state: quoted marker is not a summary", false, sums(`## quote\n${mark}\n`).summaries.length !== 0);
    t("state: updated_at and body sha256 carried", false, (() => {
        const s = sums(clean, "2026-01-01T01:00:00Z").summary;
        return !(s.updatedAt === "2026-01-01T01:00:00Z" && s.sha256 === bodySha256(clean));
    })());
    t("sha256: CRLF and LF agree", false, bodySha256(clean) !== bodySha256(clean.replace(/\n/g, "\r\n")));
    t("sha256: a changed body changes the hash", true, bodySha256(clean) !== bodySha256(`${clean}x`));
    t("sha256: the hash is the review bot's posted record of the LF body", false, bodySha256(clean) !== postedRecord("1", clean).sha256);
    const am = (extra = "") => `<!-- harness-agent v1 role=impl kind=disposition round=2 head=aaaaaaa${extra} -->\nbody`;
    t("agent marker: parsed with bot-run and in-reply-to", false, (() => {
        const m = agentMarker(am(" bot-run=123 in-reply-to=1,2"));
        return !(m && m.kind === "disposition" && m.round === 2 && m.extra["bot-run"] === "123" && m.extra["in-reply-to"] === "1,2");
    })());
    t("agent marker: not on the first line is no marker", true, agentMarker(`text\n${am()}`) === null);
    t("agent marker: malformed head", true, agentMarker("<!-- harness-agent v1 role=impl kind=note round=1 head=zz -->") === null);
    t("agent marker: a role outside impl, review and orchestrator is no marker", true, agentMarker("<!-- harness-agent v1 role=admin kind=note round=1 head=aaaaaaa -->") === null);
    t("agent marker: the three roles are markers", false, ["impl", "review", "orchestrator"].some((role) => agentMarker(`<!-- harness-agent v1 role=${role} kind=note round=1 head=aaaaaaa -->`)?.role !== role));
    const cm = (id, login, text, at) => ({ id, user: { login }, created_at: at, updated_at: at, body: text });
    const thread = [
        cm(1, "github-actions[bot]", clean, "2026-01-01T00:00:00Z"),
        cm(2, "writer", am(" bot-run=123"), "2026-01-01T00:10:00Z"),
    ];
    t("state: disposition by a writer after the summary is found", false, reviewState(thread, ["writer"]).disposition?.botRun !== "123");
    t("state: disposition by a non-writer is ignored", true, reviewState(thread, []).disposition === null);
    t("state: disposition before the summary is ignored", true, reviewState([thread[1], thread[0]], ["writer"]).disposition === null);
    t("state: disposition written by a bot is ignored", true, reviewState([thread[0], cm(3, "x[bot]", am(" bot-run=123"), "2026-01-01T00:10:00Z")], ["x[bot]"]).disposition === null);
    t("state: disposition runs listed", false, reviewState(thread, ["writer"]).dispositionRuns.join() !== "123");
    t("state: no run ids from the dispositions of a non-writer", true, reviewState(thread, []).dispositionRuns.length === 0);
    const note = cm(4, "writer", "<!-- harness-agent v1 role=impl kind=note round=2 head=aaaaaaa bot-run=777 -->\nx", "2026-01-01T00:20:00Z");
    t("state: only dispositions give run ids (a note naming a run does not)", false, reviewState([...thread, note], ["writer"]).dispositionRuns.join() !== "123");
    t("state: a summary-shaped comment typed by a person is not a summary", true, reviewState([cm(1, "writer", clean, "2026-01-01T00:00:00Z")], ["writer"]).summaries.length === 0);
    t("state: a summary-shaped comment typed by a person is not a round", true, reviewState([cm(1, "writer", clean, "2026-01-01T00:00:00Z")], ["writer"]).rounds === 0);
    t("state: the bot's summary is a round", false, reviewState(thread, ["writer"]).rounds !== 1);
    t("state: another bot's summary is not ours", true, reviewState([cm(1, "github-actions[bot]", clean.replace("bot=claude", "bot=other"), "2026-01-01T00:00:00Z")], []).summaries.length === 0);

    // the bridges to check-commits.mjs: a thin pass-through, so these only prove that the verdict arrives and the options are handed on
    const msg = `ci(example): add the example\n\nBody text.\n\n${SIGNOFF}`;
    const errs = (r) => r.errors.join(" | ");
    t("message: a clean message has no error", false, messageErrors(msg).errors.length > 0);
    t("message: a bad subject is an error", true, /type\(scope\)/.test(errs(messageErrors(`update stuff\n\n${SIGNOFF}`))));
    t("message: a missing sign-off is an error", true, /missing Signed-off-by/.test(errs(messageErrors("ci(example): add the example\n\nBody."))));
    t("message: two identical sign-offs pass by default", false, messageErrors(`${msg}\n${SIGNOFF}`).errors.length > 0);
    t("message: two identical sign-offs are an error with exactlyOne", true, /exactly one Signed-off-by/.test(errs(messageErrors(`${msg}\n${SIGNOFF}`, { exactlyOne: true }))));
    t("message: a merge commit needs no subject and no sign-off", false, messageErrors("Update things\n", { merge: true }).errors.length > 0);
    t("message: the same text is an error when it is not a merge", true, messageErrors("Update things\n").errors.length > 0);
    t("message: an AI attribution trailer is an error", true, /AI attribution/.test(errs(messageErrors(`${msg.replace(`\n\n${SIGNOFF}`, "")}\n\n${j("Co-Authored", "-By: A <a@b.c>")}\n${SIGNOFF}`))));
    const needleMsg = `ci(example): note ${FAKE_NEEDLE}\n\n${SIGNOFF}`;
    t("message: a personal needle handed on is an error", true, messageErrors(needleMsg, { personal: [FAKE_NEEDLE] }).errors.length > 0);
    t("message: no needles handed on, no needle found", false, messageErrors(needleMsg).errors.length > 0);
    const title = "ci(example): add the example";
    const prBody = `## 做了什么\n加入。\n\n${SIGNOFF}`;
    t("pr-text: a clean title and body have no error", false, prTextErrors(title, prBody).errors.length > 0);
    t("pr-text: a bad title is an error", true, /title must be/.test(errs(prTextErrors("add the example", prBody))));
    t("pr-text: a body without the sign-off on the last line is an error", true, /last line must be/.test(errs(prTextErrors(title, `${prBody}\nthanks`))));
    t("pr-text: a personal needle in the body is an error", true, prTextErrors(title, `## x\n${FAKE_NEEDLE}\n\n${SIGNOFF}`, [FAKE_NEEDLE]).errors.length > 0);
    t("pr-text: a control character in the title is refused", true, (() => { try { prTextErrors("ci(example): a\u001b[31mb", prBody); return false; } catch { return true; } })());
    t("pr-text: a control character in the body is refused", true, (() => { try { prTextErrors(title, `x\u001b[31my\n\n${SIGNOFF}`); return false; } catch { return true; } })());
    const co = j("Co-Authored", "-By: A <a@b.c>");
    t("text: a generic co-author trailer is found with its line number", false, aiTrailerLines(`a\nb\n${co}\n`).join() !== "3");
    t("text: a trailer written as a # line is found", false, aiTrailerLines(`# ${co}`).join() !== "1");
    t("text: an indented trailer is found", false, aiTrailerLines(` ${co}`).join() !== "1");
    t("text: a clean text has none", false, aiTrailerLines("fine\nCo-authors are welcome\n").length !== 0);
    return { cases, ok: cases.every((c) => c.passed), bad: cases.filter((c) => c.bad).length, good: cases.filter((c) => !c.bad).length };
}

async function selfTestInfra(cases) {
    const t = (label, bad, flagged) => cases.push({ label, bad, passed: bad ? flagged : !flagged });
    // the real list of this checkout
    t("infra: a workflow is on the real list", false, (await infraHits([".github/workflows/ci.yml"])).length !== 1);
    t("infra: the maintainer scripts are on the real list", false, (await infraHits(["scripts/maintainer/pr-merge.ps1"])).length !== 1);
    t("infra: a source file is not on the real list", false, (await infraHits(["src/tool/a.ps1", "docs/a.md"])).length !== 0);
    const tmp = fs.mkdtempSync(path.join(fs.realpathSync(process.env.TEMP || process.env.TMPDIR || "/tmp"), "maint-"));
    try {
        const good = path.join(tmp, "infra.mjs");
        fs.writeFileSync(good, 'export const isInfraPath = (p) => p.startsWith(".github/");\n');
        t("infra: a path on another list is returned", false, (await infraHits([".github/x.yml", "src/a.ps1"], good)).join() !== ".github/x.yml");
        t("infra: a path off another list is not returned", false, (await infraHits(["src/a.ps1"], good)).length !== 0);
        let missing = false;
        await infraHits(["a"], path.join(tmp, "nope.mjs")).catch(() => (missing = true));
        t("infra: a missing list module is an error, never an empty answer", true, missing);
        const noFn = path.join(tmp, "nofn.mjs");
        fs.writeFileSync(noFn, "export const x = 1;\n");
        let bad = false;
        await infraHits(["a"], noFn).catch((e) => (bad = /does not export isInfraPath/.test(e.message)));
        t("infra: a module without isInfraPath is an error", true, bad);
    } finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }
}

/** Personal needles for a bridge command: --needles <mode> and --needles-file <path>, the way check-commits.mjs reads them. */
function personalNeedles(rest) {
    return loadPersonalNeedles({ cwd: process.cwd(), ...needlesArgs(rest) }).needles;
}

async function main(argv) {
    const [cmd, ...rest] = argv;
    const opt = (k) => (rest.includes(k) ? rest[rest.indexOf(k) + 1] : undefined);
    const has = (k) => rest.includes(k);
    const print = (v) => process.stdout.write(`${JSON.stringify(v)}\n`);
    if (cmd === "--self-test") {
        const r = selfTest();
        await selfTestInfra(r.cases);
        const failed = r.cases.filter((c) => !c.passed);
        for (const c of failed) console.error(`self-test failed: ${c.label}`);
        const bad = r.cases.filter((c) => c.bad).length;
        console.log(`maint --self-test: ${failed.length ? "FAIL" : "PASS"} (bad ${bad}, good ${r.cases.length - bad})`);
        return failed.length ? 1 : 0;
    }
    assertNodeVersion();
    const file = opt("--file");
    if (!file) throw new Error("--file is required");
    if (cmd === "review-state") {
        const comments = JSON.parse(fs.readFileSync(file, "utf8"));
        const writers = (opt("--writers") || "").split(",").filter(Boolean);
        print(reviewState(comments, writers, opt("--bot") || "claude"));
    } else if (cmd === "infra") {
        const paths = JSON.parse(fs.readFileSync(file, "utf8"));
        print({ hits: await infraHits(paths, opt("--module") ? path.resolve(opt("--module")) : DEFAULT_INFRA) });
    } else if (cmd === "message") {
        // control characters are refused, not scanned: an ESC in the middle of a path or a needle would hide it from every rule
        const text = plainText(fs.readFileSync(file), "the commit message");
        print(messageErrors(text, { merge: has("--merge"), exactlyOne: has("--exactly-one"), personal: personalNeedles(rest) }));
    } else if (cmd === "same-authors") {
        print({ authors: SAME_AUTHORS });
    } else if (cmd === "pr-text") {
        const { title, body } = JSON.parse(fs.readFileSync(file, "utf8"));
        if (typeof title !== "string" || typeof body !== "string") throw new Error("pr-text needs a JSON object with string title and body");
        print(prTextErrors(title, body, personalNeedles(rest)));
    } else if (cmd === "text") {
        print({ aiTrailerLines: aiTrailerLines(fs.readFileSync(file, "utf8")) });
    } else {
        throw new Error("usage: review-state | infra | message | pr-text | text | same-authors | --self-test (see the header comment)");
    }
    return 0;
}

if (isMain(import.meta.url)) {
    main(process.argv.slice(2)).then(
        (code) => {
            process.exitCode = code;
        },
        (e) => {
            process.stdout.write(`${JSON.stringify({ error: e.message })}\n`);
            process.exitCode = 2;
        },
    );
}
