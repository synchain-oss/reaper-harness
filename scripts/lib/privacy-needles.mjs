// SPDX-License-Identifier: MIT
//
// Privacy and hygiene rules for public text: the only rule table in the repository. check-privacy
// (worktree, commit ranges, PR text), check-commits (commit messages, PR text, branch names) and the
// two git hooks all take their rules from here; the self-test fixtures live here as well.
//
// The table holds generic rules only. Personal needles (personal email addresses, local user names and
// path fragments, other account names, host names) never enter the public repository:
// loadPersonalNeedles() reads them from a source the caller names explicitly, see there.
//
// Rules and fixtures are assembled from fragments with j(): this file is scanned too, and a complete
// forbidden form in the source would need an exemption for this file, and exemptions are where things
// hide. Rules and fixtures are assembled separately and share no fragments, so breaking a rule does not
// silently break its fixture with it (otherwise the self-test would always pass).

import fs from "node:fs";
import { UsageError, decodeText, j, localSetting } from "./check-kit.mjs";

const BS = "\\\\"; // one backslash in regex source
// Path separators: 1-4 backslashes (hand-written, JSON-escaped, JSON in JSON), a slash, URL-encoded forms
const SEP = `(?:${BS}{1,4}|/|%5[Cc]|%2[Ff])`;
// A drive letter (also with a URL-encoded colon), MSYS and WSL mount prefixes, UNC admin shares (\\host\c$\)
const DRIVE = `(?:[A-Za-z](?::|%3[Aa])${SEP}|/(?:mnt/)?[A-Za-z]/|${BS}{2,4}[^\\\\/\\s]+${SEP}[A-Za-z]\\$${SEP})`;
const NAME = "([^\\\\/\\s\"'`|;*?%]+)"; // the user-name segment of a path
const MAIL_HOSTS = [
    "gmail|googlemail|outlook|hotmail|live|msn|yahoo|icloud|me|mac|proton|protonmail|pm|gmx|yandex|mail",
    "qq|foxmail|163|126|yeah|sina|sohu|aliyun",
].join("|");
const MAIL_TLDS = "com|net|org|cn|me|ch|de|fr|ru|jp|co\\.uk|co\\.jp|com\\.cn";
// Boundaries for numbers: an underscore separates too (card numbers end up in snake_case file names), so no \b
const L = "(?<![A-Za-z0-9])";
const R = "(?![A-Za-z0-9])";

const placeholder = (u) => /^[<$]/.test(u) || u === "...";
// Section numbers are allowed after a standard or RFC name, or when the same file has a heading starting with that number
const SECTION_OK = /RFC|ISO|IEC|IEEE|ITU|AES|EBU|section/i;
const sectionAllowed = (m, line, ctx) =>
    SECTION_OK.test(line.slice(Math.max(0, m.index - 12), m.index)) ||
    !!ctx.headings?.has(m[0].replace(/\D*(\d+).*/, "$1"));

// Flags: binary = scanned in binary files too (only format-independent rules with very few false positives);
// group "ai" = only a warning for outside contributors.
const rule = (id, src, flags, extra = {}) => ({ id, re: new RegExp(src, `g${flags}`), ...extra });
const B = { binary: true };
const AI = { group: "ai", binary: true };

export const RULES = [
    // Task card numbers of the private plans: R, then N or H, then two digits, optionally joined by - _ or a space
    rule("card-id", j(L, "R", "[NH][-_ ]?\\d{2}[a-z]?", R), "i", B),
    // Internal numbers inherited from the sister repositories and their plans: serials, task, milestone,
    // decision-record and workstream numbers, errata. A bare "letter + one digit" is only flagged inside
    // brackets (bracket-id): too many ordinary identifiers look like that.
    rule("serial", j(L, "(?:(?:KD|LB)-\\d{1,4}|S", "L-?\\d{2,4}|R", "E-\\d{2})", R), ""),
    rule("upstream-j", j(L, "J", "\\d{1,3}[a-z]?", R), ""),
    // Task and milestone numbers; not when another number follows (coordinates such as M12 2)
    rule("upstream-tm", j(L, "[TM]", "\\d{2}", R, "(?![\\s,.]*-?\\d)"), ""),
    rule("upstream-adr", j(L, "AD", "R-?\\d{3}", R), ""),
    rule("upstream-w", j(L, "W", "\\d{1,2}", R), ""),
    rule("erratum", j(L, "E", "-\\d{2}", R), ""),
    rule("bracket-id", j("[\\[(（][^\\])）\\n]{0,10}?", L, "[JDURWTM]\\d{1,3}", "[a-z]?(?=[\\s、,，/–\\-\\])）])"), ""),
    rule("section", j("§", "\\s?\\d+(?:\\.\\d+)*"), "", { allow: sectionAllowed }),
    rule("plan-section", j("\\b\\d{2}\\s?", "§\\s?\\d"), ""),
    rule("decision", j("(?:决", "策|裁", "决)\\s*[A-Z]?\\d"), ""),
    // Files of the private plans: numbered documents (not after a path or a date, so docs/01-usage.md and
    // 2026-11-05-x.md pass), anything below plan/, state and hand-over files
    rule(
        "plan-file",
        j(
            "(?<![\\w/\\\\-])0\\d-[a-z][a-z-]*\\.md|",
            L,
            "(?:pl",
            "an[\\\\/](?:[\\w.-]+[\\\\/])*[\\w.-]+\\.(?:md|json|js|mjs)|CHECK",
            "POINT\\.md|CLAUDE-DESIGN-HAND",
            "OFF\\.md|car",
            "ds\\.json)",
        ),
        "",
    ),
    rule("gap", j("(?<![\\w.-])ga", "p-\\d{2}(?![\\w-])"), "i"),
    // Private directories, private file names and private repository names
    rule("private-name/scratch", j(L, "_scr", "atch", R), "i"),
    rule("private-name/ref", j(L, "_re", "f[\\\\/]"), "i"),
    rule("private-name/workspace-dir", j(L, "_(?:lo", "gs|de", "ps)[\\\\/]"), "i"),
    rule("private-name/plan-repo", j(L, "master", "[-_]?plan", R), "i"),
    rule("private-name/site-repo", j("DLsnows[\\\\/]Syn", "chain", R), "i"),
    rule("private-name/workspace", j(L, "loop", "back", SEP, "(?:docs|plan|wt|_\\w+)"), "i"),
    rule(
        "private-name/file",
        j(L, "(?:privacy-lo", "cal\\.txt|orchestrator-rul", "ings|needs-orches", "trator|harness-waiv", "ers)"),
        "i",
    ),
    // Local paths and host names: binary files are scanned too
    rule("win-user-path", j(DRIVE, "Us", "ers", SEP, NAME), "i", {
        ...B,
        allow: (m) => placeholder(m[1]) || /^(?:Public|Default|All)$/i.test(m[1]),
    }),
    rule("home-path", j("(?<![\\w:])/(?:Us", "ers|ho", "me)/", NAME), "", {
        ...B,
        allow: (m) => placeholder(m[1]) || m[1] === "runner" || m[1] === "Shared",
    }),
    rule(
        "personal-email",
        j("[A-Za-z0-9._%+-]+", "@(?:[A-Za-z0-9-]+\\.)*(?:", MAIL_HOSTS, ")\\.(?:", MAIL_TLDS, ")\\b"),
        "i",
        B,
    ),
    rule("hostname", j("\\b(?:DESK", "TOP|LAP", "TOP)-(?=[A-Z0-9]*\\d)[A-Z0-9]{5,}\\b"), "i", B),
    rule("mac-host", j("\\b[\\w-]*(?:Mac", "Book|iMac|Mac-?mini|Mac-?Studio)[\\w-]*\\.loc", "al\\b"), "i", B),
    // AI attribution (written the way git reads trailers: blanks before the key and before the colon)
    rule("ai-coauthor", j("^\\s*co-authored", "-by\\s*:.*(?:cla", "ude|anthr", "opic)"), "i", AI),
    rule("ai-session", j("^\\s*cla", "ude-session\\s*:"), "i", AI),
    rule("ai-generated", j("generated (?:with|by) \\[?cla", "ude"), "i", AI),
    rule("ai-email", j("noreply@anthr", "opic\\.com"), "i", AI),
    rule("ai-url", j("cla", "ude\\.ai/code|cla", "ude\\.com/cla", "ude-code"), "i", AI),
    rule("ai-robot", "\\u{1F916}", "u", AI),
];

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const personalRule = (needles) => ({
    id: "personal",
    re: new RegExp(needles.map(escapeRe).join("|"), "gi"),
    binary: true,
    needles,
});

/** Numbers of Markdown headings that start with a section sign: references to them in the same file are fine. */
export const headingsOf = (text) =>
    new Set([...text.matchAll(new RegExp(j("^#{1,6}\\s*", "§\\s?(\\d+)"), "gm"))].map((m) => m[1]));

/** Scans text. Returns [{ rule, line, col, match }]. ctx.headings feeds the section rule. */
export function scan(text, ctx = {}, { rules = RULES, personal = [] } = {}) {
    const all = personal.length ? [...rules, personalRule(personal)] : rules;
    const out = [];
    text.split(/\r?\n/).forEach((line, i) => {
        for (const r of all) {
            for (const m of line.matchAll(r.re)) {
                if (r.allow?.(m, line, ctx)) continue;
                out.push({ rule: r, line: i + 1, col: m.index + 1, match: m[0] });
            }
        }
    });
    return out;
}

const TEXT_RUN = /[^\x00-\x08\x0e-\x1f\x7f\ufffd]{4,}/g;
const ASCII_RUN = /[\x20-\x7e]{4,}/g;

/**
 * Scans the raw bytes of a file. Bytes that decode as text (by BOM or as UTF-8) are scanned as text;
 * binary files (PNG text chunks, WAV BWF headers and RIFF INFO lists may carry local information) get
 * the binary rules only, over the printable runs in UTF-8 and both alignments of UTF-16LE.
 * Findings in binary files have line 0.
 */
export function scanBlob(buf, ctx = {}, opts = {}) {
    const text = decodeText(buf);
    if (text !== null) return scan(text, { headings: headingsOf(text), ...ctx }, opts);
    const rules = (opts.rules || RULES).filter((r) => r.binary);
    const views = [
        buf.toString("utf8").match(TEXT_RUN),
        buf.toString("utf16le").match(ASCII_RUN),
        buf.subarray(1).toString("utf16le").match(ASCII_RUN),
    ];
    const seen = new Set();
    const out = [];
    for (const view of views) {
        for (const f of scan((view || []).join("\n"), ctx, { ...opts, rules })) {
            const key = `${f.rule.id}\0${f.match.toLowerCase()}`;
            if (seen.has(key)) continue;
            seen.add(key);
            out.push({ ...f, line: 0, col: 0 });
        }
    }
    return out;
}

/** Redaction: personal needles only by number; anything else keeps its first two characters. CI logs are public. */
export function redact(f) {
    if (f.rule.needles) {
        const n = f.rule.needles.findIndex((x) => x.toLowerCase() === f.match.toLowerCase());
        return `personal needle #${n + 1}`;
    }
    return f.match.slice(0, 2) + "*".repeat(Math.max(0, f.match.length - 2));
}

/** Masks every finding in a one-line text (a path, a ref name) with *, for places that must echo the name. */
export function mask(text, personal = []) {
    const hide = new Set();
    for (const f of scan(text, {}, { personal })) {
        if (f.line === 1) for (let k = 0; k < f.match.length; k++) hide.add(f.col - 1 + k);
    }
    return [...text].map((c, k) => (hide.has(k) ? "*" : c)).join("");
}

/**
 * Gate for public text and needle lists: rejects UTF-16 (every needle would become a NUL-interleaved
 * string that never matches), NUL, control characters, a CR without its LF and invisible format characters
 * (a zero-width space in the middle of a path hides it from every rule, and nobody sees it in the rendered
 * text); drops a UTF-8 BOM. buf is a Buffer or string.
 */
export function plainText(buf, label) {
    const b = Buffer.isBuffer(buf) ? buf : Buffer.from(String(buf), "utf8");
    if ((b[0] === 0xff && b[1] === 0xfe) || (b[0] === 0xfe && b[1] === 0xff)) {
        throw new Error(`${label} is UTF-16; convert it to UTF-8 first`);
    }
    const bom = b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf ? 3 : 0;
    const text = b.subarray(bom).toString("utf8");
    const bad = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]|\r(?!\n)|\p{Cf}/u.exec(text);
    if (bad) {
        // Only the position and the code are reported, never the content (pasted ANSI colour codes are the usual source)
        const before = text.slice(0, bad.index);
        const code = bad[0].codePointAt(0).toString(16).toUpperCase().padStart(4, "0");
        const where = `line ${before.split("\n").length}, byte offset ${bom + Buffer.byteLength(before)}`;
        throw new Error(`${label} contains a control or invisible character U+${code} (${where})`);
    }
    return text;
}

const parseNeedles = (s) =>
    s
        .split(/\r?\n/)
        .map((l) => l.trim())
        .filter((l) => l && !l.startsWith("#"));

/**
 * Where the personal needles come from is named by the caller (--needles); the scripts never guess
 * from the environment whether they run in CI:
 *   local        (default; hooks and manual runs) the file given with --needles-file, else
 *                HARNESS_PRIVACY_LOCAL, else git config harness.privacyLocal. The file lives outside
 *                the repository; not configured, unreadable or empty all fail.
 *   ci           CI, same-repository PRs, pushes and dispatches: environment variable PRIVACY_NEEDLES
 *                (one needle per line); missing or empty fails.
 *   ci-optional  only for fork and dependabot PRs (no secrets): used when present, otherwise a notice is
 *                printed and only the generic rules run.
 */
export const NEEDLE_MODES = ["local", "ci", "ci-optional"];

/** { mode, file } from the command line: --needles <mode> and --needles-file <path>. */
export function needlesArgs(argv) {
    const i = argv.indexOf("--needles");
    const mode = i < 0 ? "local" : argv[i + 1];
    if (!NEEDLE_MODES.includes(mode)) throw new UsageError(`--needles must be one of ${NEEDLE_MODES.join(" / ")}`);
    const f = argv.indexOf("--needles-file");
    const file = f < 0 ? undefined : argv[f + 1];
    if (f >= 0 && (!file || file.startsWith("--"))) throw new UsageError("--needles-file needs a path");
    if (file && mode !== "local") throw new UsageError("--needles-file only goes with --needles local");
    return { mode, file };
}

/** The flags needlesArgs consumes, with their arity, for scripts that parse the rest themselves. */
export const NEEDLE_FLAGS = { "--needles": 1, "--needles-file": 1 };

export function loadPersonalNeedles({ env = process.env, cwd = process.cwd(), mode = "local", file } = {}) {
    if (!NEEDLE_MODES.includes(mode)) throw new UsageError(`unknown personal needle source ${mode}`);
    if (mode === "local") {
        const src = file || localSetting("HARNESS_PRIVACY_LOCAL", "harness.privacyLocal", { env, cwd });
        if (!src) {
            throw new Error(
                "personal needles are not configured: pass --needles-file, set HARNESS_PRIVACY_LOCAL or git config harness.privacyLocal",
            );
        }
        if (!fs.existsSync(src)) throw new Error("the personal needle file does not exist");
        const needles = parseNeedles(plainText(fs.readFileSync(src), "the personal needle file"));
        if (!needles.length) throw new Error("the personal needle file holds no needles");
        return { needles, notes: [] };
    }
    const needles = parseNeedles(plainText(env.PRIVACY_NEEDLES || "", "PRIVACY_NEEDLES"));
    if (needles.length) return { needles, notes: [] };
    if (mode === "ci") throw new Error("--needles ci: PRIVACY_NEEDLES is missing or empty");
    return { needles, notes: ["::notice::PRIVACY_NEEDLES is not available (fork or bot PR); generic rules only"] };
}

// ---- self-test fixtures ----------------------------------------------------------------------

/** A fake needle for self-tests only. Real personal needles never enter the repository. */
export const FAKE_NEEDLE = "harness-selftest-fake-needle-5d2a";
const ROBOT = String.fromCodePoint(0x1f916);

/** One standard bad sample per rule (PR or commit text). The binary fixture below is built from these. */
const SAMPLES = {
    "card-id": j("fixes R", "H-12 regression"),
    serial: j("S", "L-446 is fixed"),
    "upstream-j": j("as agreed in J", "12"),
    "upstream-tm": j("the T", "19 card"),
    "upstream-adr": j("decided in AD", "R-011"),
    "upstream-w": j("W", "15 sets the secret"),
    erratum: j("errata E", "-07"),
    "bracket-id": j("see (D", "4)"),
    section: j("see §", "4.2"),
    "plan-section": j("see 0", "6 §", "3"),
    decision: j("按决", "策 R5"),
    "plan-file": j("see 0", "4-execution.md"),
    gap: j("see ga", "p-07"),
    "private-name/scratch": j("_scr", "atch/notes"),
    "private-name/ref": j("_re", "f/upstream"),
    "private-name/workspace-dir": j("_lo", "gs/run.json"),
    "private-name/plan-repo": j("scvb-master", "plan"),
    "private-name/site-repo": j("DLsnows/Syn", "chain"),
    "private-name/workspace": j("loop", "back/plan/x"),
    "private-name/file": j("privacy-lo", "cal.txt"),
    "win-user-path": j("D:", "\\", "Us", "ers", "\\", "someone", "\\", "proj"),
    "home-path": j("/Us", "ers/someone/Music"),
    "personal-email": j("someone", "@", "gmail", ".com"),
    hostname: j("DESK", "TOP-AB12CD3"),
    "mac-host": j("someones-Mac", "Book-Pro.loc", "al"),
    "ai-coauthor": j("Co-Authored", "-By: Cla", "ude <x@example.com>"),
    "ai-session": j("Cla", "ude-Session: abc"),
    "ai-generated": j("Generated with [Cla", "ude Code]"),
    "ai-email": j("noreply@anthr", "opic.com"),
    "ai-url": j("https://cla", "ude.ai/code"),
    "ai-robot": `${ROBOT} done`,
    personal: `the log shows ${FAKE_NEEDLE}`,
};

// [rule id or ids that must be found (null = must be clean), text or Buffer, path (omitted = PR or commit text)]
export const CASES = [
    // Card numbers in their various spellings
    ["card-id", j("see R", "N05")],
    ["card-id", j("see R", "H01")],
    ["card-id", j("feat/r", "h-01-governance")],
    ["card-id", j("R", "N_01a notes")],
    ["card-id", j("report_R", "H-12.md")],
    ["card-id", j("gates-R", "N-01a_log.json")],
    [null, "RHEL 9, a rh-shaped word, HRN12x and arn:aws are fine"],
    ["serial", j("S", "L446")],
    ["serial", j("R", "E-1", "2 decided it")],
    ["upstream-j", j("J", "145 says")],
    ["upstream-tm", j("after milestone M", "04")],
    [null, "coordinates M12 2 and 1E-12; IEEE-754; W3C; ADR-0007 is a public record"],
    ["upstream-w", j("bracket (W", "4)")],
    ["upstream-w", j("see plan/W", "4")],
    ["decision", j("决", "策 K1")],
    ["decision", j("用户裁", "决 D", "4")],
    ["bracket-id", j("note (J", "45)")],
    ["bracket-id", j("（用户 D", "4）")],
    ["bracket-id", j("[track M", "10]")],
    [null, "format (VST3), arch (x64), issue (#12), scenario (S01, S02), pitch (A4 = 440 Hz), key (F5)"],
    ["bracket-id", j("# keep (D", "4)"), "src/Guard.psm1"],
    ["bracket-id", j("<#\n  per (D", "4)\n#>"), "src/Guard.psm1"],
    // Section numbers and file names
    [null, "RFC 2119 §3; ISO 8601 §5.2; IEC 61672 §5"],
    [null, j("## §", "3 Branches\nsee §", "3"), "CLAUDE.md"],
    [null, "docs/validation/2026-11-05-scvb.md and docs/01-usage.md"],
    ["private-name/plan-repo", j("scvb_master", "plan")],
    ["plan-file", j("see CHECK", "POINT.md")],
    ["plan-file", j("CLAUDE-DESIGN-HAND", "OFF.md")],
    ["plan-file", j("see car", "ds.json")],
    ["plan-file", j("see 0", "7-roadmap.md")],
    ["plan-file", j("pl", "an/04-execution.md")],
    ["plan-file", j("pl", "an/state/x-waivers.json")],
    ["private-name/workspace", j("loop", "back", "\\", "plan", "\\", "x")],
    ["private-name/workspace-dir", j("see _de", "ps\\gitleaks")],
    ["private-name/file", j("see needs-orches", "trator.md")],
    ["private-name/file", j("orchestrator-rul", "ings.md")],
    [null, "audio loopback device; node_deps/x; the orchestrator rules; privacy-local needles"],
    // Local paths
    ["win-user-path", j("c:/", "us", "ers/", "someone")],
    ["win-user-path", j("C:", "\\\\", "Us", "ers", "\\\\", "someone")],
    ["win-user-path", j("C:", "\\\\\\\\", "Us", "ers", "\\\\\\\\", "someone")],
    ["win-user-path", j("/c/", "Us", "ers/", "someone")],
    ["win-user-path", j("/mnt/c/", "Us", "ers/", "someone")],
    ["win-user-path", j("\\\\", "localhost", "\\", "c$", "\\", "Us", "ers", "\\", "someone")],
    ["win-user-path", j("C%3A%5C", "Us", "ers%5C", "someone%5Cx")],
    [null, j("C:", "\\", "Us", "ers", "\\", "<user>", "\\", "x and C:/", "Us", "ers/$env:USERNAME/x")],
    [null, j("C:", "\\", "Us", "ers", "\\", "Public", "\\", "Documents and C:/", "Us", "ers/Default")],
    [null, "C:\\Program Files\\REAPER (x64)\\reaper.exe and %APPDATA%\\REAPER"],
    ["home-path", j("/ho", "me/someone/.config")],
    [null, j("/Us", "ers/runner/work, /Us", "ers/Shared/x, /ho", "me/runner/work")],
    // Email addresses
    ["personal-email", j("someone", "@", "vip.", "qq", ".com")],
    ["personal-email", j("someone", "@", "outlook", ".co.uk")],
    ["personal-email", j("someone", "@", "proton", ".me")],
    [null, "contact@synchain.ca; noreply@github.com; 49699333+dependabot[bot]@users.noreply.github.com"],
    // Host names and AI attribution variants
    ["hostname", j("lap", "top-z9y8x7w")],
    [null, "desktop-friendly layout; settings.local.json"],
    ["ai-coauthor", j("Co-authored", "-by : Cla", "ude <x@example.com>")],
    ["ai-coauthor", j("  Co-authored", "-by: Cla", "ude <x@example.com>")],
    ["ai-generated", j("Generated by Cla", "ude Code")],
    ["ai-url", j("https://cla", "ude.com/cla", "ude-code")],
    [null, "Co-authored-by is not allowed here; model claude-opus-5-5 reviews; 【重要】清零"],
    ["personal", `the log shows ${FAKE_NEEDLE.toUpperCase()}`],
    // Encodings: UTF-16 text is decoded by BOM and scanned with every rule
    ["card-id", Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(SAMPLES["card-id"], "utf16le")]), "docs/log.txt"],
];

/** Fixtures generated from the standard samples: one per rule, plus every binary rule inside a binary blob. */
function sampleCases() {
    const ids = [...RULES.map((r) => r.id), "personal"];
    const missing = ids.filter((id) => !(id in SAMPLES));
    const binary = ids.filter((id) => (id === "personal" ? true : RULES.find((r) => r.id === id).binary));
    const textOnly = ids.filter((id) => !binary.includes(id));
    // The samples sit between NUL and high bytes, like a field in a PNG text chunk or a WAV header
    const blob = (list) => Buffer.concat(list.flatMap((id) => [Buffer.from([0, 0x89, 0]), Buffer.from(SAMPLES[id])]));
    return [
        ...missing.map((id) => [`missing standard sample: ${id}`, "", undefined]),
        ...ids.map((id) => [id, SAMPLES[id]]),
        [binary, blob(binary), "tests/fixtures/shot.png"],
        // Text-only rules stay silent in binary files
        [null, blob(textOnly), "tests/fixtures/text-only.bin"],
    ];
}

/** Runs the fixtures; opts may replace the rules or drop the needles (mutation check). */
export function runCases(opts = {}) {
    return [...sampleCases(), ...CASES].map(([want, input, path]) => {
        const o = { personal: [FAKE_NEEDLE], ...opts };
        const found = Buffer.isBuffer(input)
            ? scanBlob(input, { path }, o)
            : scan(input, path ? { path, headings: headingsOf(input) } : {}, o);
        const ids = new Set(found.map((f) => f.rule.id));
        const wants = want === null ? [] : [].concat(want);
        const passed = want === null ? ids.size === 0 : wants.length > 0 && wants.every((w) => ids.has(w));
        const shown = Buffer.isBuffer(input) ? `<${input.length} bytes>` : JSON.stringify(input).slice(0, 48);
        return { label: `${want === null ? "clean" : wants.join(",")}: ${shown}`, bad: want !== null, passed };
    });
}

/**
 * Mutation check: every criterion is disabled in turn and each mutant must turn at least one fixture red,
 * otherwise that criterion is not guarded by a fixture. Per rule: the pattern never matches; binary scanning
 * dropped (binary rules) or added (text-only rules); the exemption allows everything or nothing. Plus:
 * personal needles not merged.
 */
export function mutationCheck() {
    const never = /(?!)/g;
    const swap = (id, patch) => RULES.map((r) => (r.id === id ? { ...r, ...patch } : r));
    const mutants = RULES.flatMap((r) => [
        [`${r.id}: pattern disabled`, { rules: swap(r.id, { re: never }) }],
        [`${r.id}: binary flag flipped`, { rules: swap(r.id, { binary: !r.binary }) }],
        ...(r.allow
            ? [
                  [`${r.id}: exemption allows everything`, { rules: swap(r.id, { allow: () => true }) }],
                  [`${r.id}: exemption allows nothing`, { rules: swap(r.id, { allow: () => false }) }],
              ]
            : []),
    ]);
    mutants.push(["personal needles not merged", { personal: [] }]);
    const survived = mutants.filter(([, opts]) => runCases(opts).every((c) => c.passed)).map(([name]) => name);
    return { total: mutants.length, survived };
}
