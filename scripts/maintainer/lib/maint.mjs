// SPDX-License-Identifier: MIT
//
// Node side of the maintainer wrappers (scripts/maintainer/*.ps1). It holds only the parsing that is easier and
// safer to keep in JavaScript: the machine-readable review footer, the head marker, the per-section counts of a
// bot summary, the agent marker and the "previous round / disposition" lookup. Privacy rules live in
// scripts/check-privacy.mjs and the infrastructure path list in scripts/lib/infra-paths.mjs; this file calls
// them and never copies their tables.
//   node scripts/maintainer/lib/maint.mjs review-state --file <issue comments JSON> --writers <login,...> [--bot claude]
//        newest bot summary (head, run link, footer and count check) and the disposition after it (author must be in
//        --writers); also every bot summary (footer, run id, per-item findings, created_at / updated_at, body sha256)
//        and the run ids referenced by every disposition
//   node scripts/maintainer/lib/maint.mjs infra --file <path JSON array> [--module <infra-paths.mjs>]
//        the paths that touch the infrastructure list; --module is for the self-test only
//   node scripts/maintainer/lib/maint.mjs --self-test

import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";

/** The merge criteria parse exactly this line. */
export const FOOTER = /^<!-- harness-review v1 red=(\d+) important=(\d+) suggest=(\d+) -->$/;
const HEAD_MARK = /^<!-- harness-review-head sha=([0-9a-f]{40}) bot=([a-z]+) -->$/;
/** Run page link on the second line of a bot summary. */
const RUN_LINK = /\/actions\/runs\/(\d+)/;
/** Agent marker, first line of every comment we write: see CONTRIBUTING.md (review process). */
const AGENT_MARK =
    /^<!-- harness-agent v1 role=([a-z]+) kind=([a-z-]+) round=(\d+) head=([0-9a-f]{7,40})((?: [a-z-]+=[^\s>]+)*) -->$/;
const DISPOSITION = /^<!-- harness-agent v1 role=[a-z-]+ kind=disposition /m;
const SECTIONS = { red: "红旗", important: "重要", suggest: "建议" };

/**
 * First-line head marker { sha, bot } of a bot summary, or null. Only the first line counts: other bots also post
 * as github-actions[bot] and a model can write the same line in the middle of a body. A BOM before the first line is
 * not body text (comments can round-trip with one); a trailing \r is half of a CRLF.
 */
export function headMark(body) {
    const first = (body || "").replace(/^﻿/, "").split(/\r?\n/, 1)[0];
    const m = HEAD_MARK.exec(first);
    return m ? { sha: m[1], bot: m[2] } : null;
}

/**
 * Per-section item counts of "## 【红旗】", "## 【重要】", "## 【建议】": only top-level list items inside a section,
 * fenced code skipped, "- 无" does not count. A section ends at the next level 1-2 heading (deeper headings do not
 * end it) except under 【建议】, where a deeper heading stops the count (later rounds append an "incremental check"
 * part there). 【红旗】 and 【重要】 get no such exception, otherwise an important item hidden under a subheading
 * would let the footer say 0.
 */
export function sectionCounts(text) {
    const counts = {};
    const seen = {};
    let current = null;
    let fence = false;
    let counting = true;
    for (const l of text.replace(/\r\n/g, "\n").split("\n")) {
        if (/^\s*(?:```|~~~)/.test(l)) {
            fence = !fence;
            continue;
        }
        if (fence) continue;
        const level = /^(#{1,6})\s/.exec(l);
        if (level && level[1].length > 2 && current === "建议") counting = false;
        if (level && level[1].length <= 2) {
            const m = /^##\s+【(红旗|重要|建议)】/.exec(l);
            current = m ? m[1] : null;
            counting = true;
            if (current) {
                seen[current] = (seen[current] || 0) + 1;
                counts[current] ??= 0;
            }
            continue;
        }
        const item = /^(?:[-*+]|\d+[.)])\s+(\S.*)$/.exec(l);
        if (current && counting && item && !/^无[。.]?\s*$/.test(item[1])) counts[current]++;
    }
    return { counts, seen };
}

/** Is the summary usable: exactly one kind of footer, and its three numbers equal the section counts. */
export function validateSummary(text) {
    const lines = text.replace(/\r\n/g, "\n").split("\n");
    const footers = lines.map((l) => l.trim()).filter((l) => FOOTER.test(l));
    if (!footers.length) return { ok: false, reason: "machine-readable footer missing" };
    if (new Set(footers).size > 1) return { ok: false, reason: "more than one footer line and they differ" };
    const main = lines
        .filter((l) => !FOOTER.test(l.trim()))
        .join("\n")
        .trimEnd();
    const [, ...nums] = FOOTER.exec(footers[0]);
    const want = { red: +nums[0], important: +nums[1], suggest: +nums[2] };
    const { counts, seen } = sectionCounts(main);
    for (const name of Object.values(SECTIONS)) {
        if (!seen[name]) return { ok: false, reason: `section "## 【${name}】" missing` };
        if (seen[name] > 1) return { ok: false, reason: `section "## 【${name}】" appears more than once` };
    }
    const got = Object.fromEntries(Object.entries(SECTIONS).map(([k, name]) => [k, counts[name]]));
    if (Object.keys(SECTIONS).some((k) => got[k] !== want[k])) {
        const fmt = (o) => `red=${o.red} important=${o.important} suggest=${o.suggest}`;
        return { ok: false, reason: `footer counts do not match the body (body ${fmt(got)}, footer ${fmt(want)})` };
    }
    return { ok: true, main, footer: footers[0] };
}

/** Body sha256 the way the bot records it: CRLF folded to LF, then UTF-8 bytes. */
export function bodySha256(body) {
    return createHash("sha256")
        .update(Buffer.from((body || "").replace(/\r\n/g, "\n"), "utf8"))
        .digest("hex");
}

/**
 * Facts of a posted bot summary: footer exactly one line and the last line, counts consistent (validateSummary),
 * plus the head marker and the run id from the link in the first three lines.
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
    const [, red, important, suggest] = FOOTER.exec(lines.at(-1).trim());
    return { ...base, ok: true, reason: null, red: +red, important: +important, suggest: +suggest };
}

/** Findings listed in a bot summary (top-level list items under the three sections; same rules as sectionCounts). */
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

/**
 * Previous round: the newest bot summary (github-actions[bot] with the same bot in the head marker) and the newest
 * disposition after it. A disposition must come after that summary, must not be written by a bot and its author must
 * pass `trusted` (anybody can type a marker).
 */
export function findPrevious(comments, bot, trusted) {
    const isReview = (c) => c.user?.login === "github-actions[bot]" && headMark(c.body)?.bot === bot;
    const at = comments.findLastIndex(isReview);
    const last = at >= 0 ? comments[at] : null;
    const disposition = last
        ? comments
              .slice(at + 1)
              .filter((c) => DISPOSITION.test(c.body || "") && !/\[bot\]$/.test(c.user?.login || "") && trusted(c))
              .at(-1)
        : null;
    return {
        rounds: comments.filter(isReview).length,
        previousHead: last ? headMark(last.body).sha : null,
        disposition: disposition ? disposition.body : null,
    };
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
    const found = (text) => headMark(text)?.sha === sha;
    t("head mark: recognised on the first line", false, !found(clean));
    t("head mark: CRLF", false, !found(clean.replace(/\n/g, "\r\n")));
    t("head mark: BOM before the first line", false, !found(`﻿${clean}`));
    t("head mark: quoted in the body is not a summary", false, found(`## quote\n${mark}\n`));
    t("head mark: only on the second line is not a summary", false, found(`\n${mark}\n`));
    t("head mark: wrong sha length", false, headMark(`<!-- harness-review-head sha=abc bot=claude -->`) !== null);
    const facts = summaryFacts(clean);
    t(
        "summary: clean footer parsed with run id and head",
        false,
        !(facts.ok && facts.red === 0 && facts.important === 0 && facts.suggest === 1 && facts.runId === "123" && facts.head === sha),
    );
    t("summary: no footer is unusable", true, !summaryFacts(clean.replace(foot(0, 0, 1), "")).ok);
    t("summary: two different footers are unusable", true, !summaryFacts(`${clean}\n${foot(0, 1, 1)}`).ok);
    t("summary: footer not on the last line is unusable", true, !summaryFacts(`${clean}\ntrailing text`).ok);
    t("summary: duplicated identical footer is unusable (exactly one line)", true, !summaryFacts(`${clean}\n${foot(0, 0, 1)}`).ok);
    t("summary: footer undercounts an important item", true, !summaryFacts(body([], ["- real"], ["- a"], foot(0, 0, 1))).ok);
    t("summary: footer overcounts", true, !summaryFacts(body([], [], ["- a"], foot(0, 0, 3))).ok);
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
    // validateSummary is exported and judges on its own: the reason, not just the verdict, is what a caller shows
    const why = (text) => validateSummary(text).reason ?? "";
    t("validate: two different footers are unusable, and say so", true, /differ/.test(why(`${clean}\n${foot(0, 1, 1)}`)));
    t("validate: a missing section is reported as missing", true, /missing/.test(why(clean.replace("## 【重要】\n- 无\n", ""))));
    t("validate: a duplicated section is reported as such", true, /more than once/.test(why(clean.replace("## 【建议】", "## 【重要】\n## 【建议】"))));
    t("validate: no footer is reported as such", true, /footer missing/.test(why(clean.replace(foot(0, 0, 1), ""))));
    t("validate: a clean summary has no reason", false, why(clean) !== "");
    const linkBelow = body([], [], ["- see https://github.com/o/r/actions/runs/999"], foot(0, 0, 1)).replace(/_审查对象[^\n]*\n/, "");
    t("summary: a run link below the first three lines is not the run of the summary", false, summaryFacts(linkBelow).runId !== null);
    const lv = (text) => summaryItems(text).map((i) => i.level).join(",");
    t("items: levels listed in order", false, lv(body(["- r"], ["- i"], ["- s"], foot(1, 1, 1))) !== "红旗,重要,建议");
    t("items: nothing listed for a clean summary except the suggestion", false, lv(clean) !== "建议");
    t("items: items inside a fenced block are not listed", false, lv(body([], [], ["```", "- fake", "```", "- a"], foot(0, 0, 1))) !== "建议");
    t("items: an item under a subheading of the suggestion section is not listed", false, lv(body([], [], ["- a", "### incremental", "- c"], foot(0, 0, 1))) !== "建议");
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
    t("sha256: computed over UTF-8 bytes", false, bodySha256(clean) !== createHash("sha256").update(Buffer.from(clean, "utf8")).digest("hex"));
    const am = (extra = "") => `<!-- harness-agent v1 role=impl kind=disposition round=2 head=aaaaaaa${extra} -->\nbody`;
    t("agent marker: parsed with bot-run and in-reply-to", false, (() => {
        const m = agentMarker(am(" bot-run=123 in-reply-to=1,2"));
        return !(m && m.kind === "disposition" && m.round === 2 && m.extra["bot-run"] === "123" && m.extra["in-reply-to"] === "1,2");
    })());
    t("agent marker: not on the first line is no marker", true, agentMarker(`text\n${am()}`) === null);
    t("agent marker: malformed head", true, agentMarker("<!-- harness-agent v1 role=impl kind=note round=1 head=zz -->") === null);
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
    t("previous round: a head marker typed by a person is not a summary", true, findPrevious([cm(1, "writer", clean, "2026-01-01T00:00:00Z")], "claude", () => true).rounds === 0);
    t("previous round: the bot's summary is counted and the writer's disposition follows it", false, (() => {
        const p = findPrevious(thread, "claude", (c) => c.user.login === "writer");
        return !(p.rounds === 1 && p.previousHead === sha && p.disposition?.includes("bot-run=123"));
    })());
    t("state: another bot's summary is not ours", true, reviewState([cm(1, "github-actions[bot]", clean.replace("bot=claude", "bot=other"), "2026-01-01T00:00:00Z")], []).summaries.length === 0);
    return { cases, ok: cases.every((c) => c.passed), bad: cases.filter((c) => c.bad).length, good: cases.filter((c) => !c.bad).length };
}

async function selfTestInfra(cases) {
    const t = (label, bad, flagged) => cases.push({ label, bad, passed: bad ? flagged : !flagged });
    const tmp = fs.mkdtempSync(path.join(fs.realpathSync(process.env.TEMP || process.env.TMPDIR || "/tmp"), "maint-"));
    try {
        const good = path.join(tmp, "infra.mjs");
        fs.writeFileSync(good, 'export const isInfraPath = (p) => p.startsWith(".github/");\n');
        t("infra: a path on the list is returned", false, (await infraHits([".github/x.yml", "src/a.ps1"], good)).join() !== ".github/x.yml");
        t("infra: a path off the list is not returned", false, (await infraHits(["src/a.ps1"], good)).length !== 0);
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

async function main(argv) {
    const [cmd, ...rest] = argv;
    const opt = (k) => (rest.includes(k) ? rest[rest.indexOf(k) + 1] : undefined);
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
    const file = opt("--file");
    if (!file) throw new Error("--file is required");
    if (cmd === "review-state") {
        const comments = JSON.parse(fs.readFileSync(file, "utf8"));
        const writers = (opt("--writers") || "").split(",").filter(Boolean);
        print(reviewState(comments, writers, opt("--bot") || "claude"));
    } else if (cmd === "infra") {
        const paths = JSON.parse(fs.readFileSync(file, "utf8"));
        print({ hits: await infraHits(paths, opt("--module") ? path.resolve(opt("--module")) : DEFAULT_INFRA) });
    } else {
        throw new Error("usage: review-state | infra | --self-test (see the header comment)");
    }
    return 0;
}

const isMain = (() => {
    try {
        return !!process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url));
    } catch {
        return false;
    }
})();
if (isMain) {
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
