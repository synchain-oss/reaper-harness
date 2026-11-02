// SPDX-License-Identifier: MIT
//
// Privacy gate for the public repository: the generic rules of lib/privacy-needles.mjs plus the
// personal needles, over three kinds of input.
//   node scripts/check-privacy.mjs [--root <dir>]       the git-tracked worktree (contents and paths;
//                                                        UTF-16 and binary files too)
//   node scripts/check-privacy.mjs --commits <rev-list args...> [--no-messages]
//        every commit in the range: message, added lines and new paths. Pushed commits stay public
//        through refs/pull, so a clean worktree does not mean a clean history. --no-messages skips the
//        messages (check-commits judges those by tier).
//   node scripts/check-privacy.mjs --text <file|->      one piece of public text (PR title and body, a
//                                                        comment draft); UTF-8 only
//   --needles local|ci|ci-optional [--needles-file <path>]  personal needle source, see privacy-needles.mjs
//   --self-test (rule fixtures and end to end)  --mutation-check  --list-rules
// Only positions and redacted fragments are printed; personal needles only by number, and findings in
// paths are masked. Exit codes: 0 clean, 1 findings or missing configuration, 64 usage error.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import * as kit from "./lib/check-kit.mjs";
import * as needles from "./lib/privacy-needles.mjs";
import { cleanupTempDir, makeTempDir } from "./lib/safe-rm.mjs";

const { ROOT, UsageError, caseResult, git, tempRepo, trackedFiles } = kit;
const { mask, redact, scan, scanBlob } = needles;
const SELF = fileURLToPath(import.meta.url);
// External diff drivers and textconv on the machine rewrite patches; they are always off for scanning
const DIFF = ["--no-renames", "--no-ext-diff", "--no-textconv"];

export const formatFinding = (f) =>
    `  ${f.where}${f.line ? `:${f.line}:${f.col}` : " (binary)"} [${f.rule.id}] ${redact(f)}`;
const tag = (where, list) => list.map((f) => ({ ...f, where }));

/**
 * The path on a patch's +++ line: with spaces git appends a TAB; with quotes, backslashes or control
 * characters it writes a C-style quoted string (octal escapes are UTF-8 bytes). Returns the path
 * without the b/ prefix.
 */
export function patchPath(s) {
    let p = s.replace(/\t$/, "");
    if (p.startsWith('"') && p.endsWith('"')) {
        const bytes = [];
        const esc = { a: 7, b: 8, t: 9, n: 10, v: 11, f: 12, r: 13 };
        for (let i = 1; i < p.length - 1; i++) {
            if (p[i] !== "\\") {
                bytes.push(...Buffer.from(p[i]));
            } else if (/[0-7]/.test(p[i + 1])) {
                bytes.push(parseInt(p.slice(i + 1, i + 4), 8));
                i += 3;
            } else {
                bytes.push(esc[p[i + 1]] ?? p.charCodeAt(i + 1));
                i++;
            }
        }
        p = Buffer.from(bytes).toString("utf8");
    }
    return p.replace(/^b\//, "");
}

export function scanTree(root, personal) {
    const out = [];
    for (const rel of trackedFiles(root)) {
        const shown = mask(rel, personal);
        out.push(...tag(`${shown} (path)`, scan(rel, {}, { personal })));
        let buf;
        try {
            buf = fs.readFileSync(path.join(root, rel));
        } catch {
            continue; // deleted, submodule and the like
        }
        out.push(...tag(shown, scanBlob(buf, { path: rel }, { personal })));
    }
    return out;
}

/**
 * Per commit: the message (optional), new paths and new content. Content is scanned from the whole file
 * after the commit (so same-file headings are in context) and only findings on added lines are kept;
 * binary and UTF-16 files have no line-level patch and are reported whole. A merge commit is judged by
 * everything it brings in relative to its first parent.
 */
export function scanCommits(revArgs, cwd, personal, { messages = true } = {}) {
    const out = [];
    for (const sha of git(["rev-list", ...revArgs], { cwd })
        .split("\n")
        .filter(Boolean)) {
        const s7 = sha.slice(0, 7);
        const [parents, msg] = git(["log", "-1", "--format=%P%x00%B", sha], { cwd }).split("\0");
        if (messages) out.push(...tag(`${s7} commit message`, scan(msg, {}, { personal })));
        const diff = (...opts) =>
            parents.trim().includes(" ")
                ? git(["diff", ...DIFF, ...opts, `${sha}^1`, sha], { cwd })
                : git(["show", ...DIFF, "--format=", ...opts, sha], { cwd });
        const added = new Map(); // path -> added line numbers
        let file = null;
        let header = false;
        for (const line of diff("--no-color", "-U0", "--src-prefix=a/", "--dst-prefix=b/").split("\n")) {
            if (line.startsWith("diff --git ")) {
                header = true;
                file = null;
            } else if (header && line.startsWith("+++ ")) {
                file = line === "+++ /dev/null" ? null : patchPath(line.slice(4));
                if (file) added.set(file, new Set());
            } else if (line.startsWith("@@")) {
                header = false;
                const [, start, count = "1"] = /\+(\d+)(?:,(\d+))?/.exec(line) || [];
                for (let k = 0; file && k < Number(count); k++) added.get(file).add(Number(start) + k);
            }
        }
        // Paths and the binary flag come from --numstat -z (no quoting); paths missing from the patch are reported whole
        for (const entry of diff("--numstat", "-z", "--diff-filter=AMT").split("\0")) {
            const [plus, , ...rest] = entry.replace(/^\n+/, "").split("\t");
            const rel = rest.join("\t");
            if (!rel) continue;
            const shown = mask(rel, personal);
            out.push(...tag(`${s7} ${shown} (path)`, scan(rel, {}, { personal })));
            const buf = git(["cat-file", "blob", `${sha}:${rel}`], { cwd, raw: true, allowFail: true });
            if (!buf) continue; // not a blob (submodule and the like)
            const lines = plus === "-" ? null : added.get(rel);
            const hits = scanBlob(buf, { path: rel }, { personal });
            // Findings from the binary view (line 0) have no line number to match: always kept
            const kept = lines ? hits.filter((f) => f.line === 0 || lines.has(f.line)) : hits;
            out.push(...tag(`${s7} ${shown}`, kept));
        }
    }
    return out;
}

function report(findings, notes) {
    for (const n of notes) console.log(n);
    if (!findings.length) {
        console.log("check-privacy passed: no findings");
        return 0;
    }
    console.error(`check-privacy FAILED: ${findings.length} finding(s)`);
    for (const f of findings) console.error(formatFinding(f));
    console.error("Rules: --list-rules. A false positive means rewording the text; personal needles have no exemption.");
    return 1;
}

/** Rule fixtures, plus end to end: the fake needle hidden in a temp repository must be caught and never echoed. */
export function selfTest() {
    const cases = needles.runCases();
    const N = needles.FAKE_NEEDLE;
    const repo = tempRepo();
    const aux = makeTempDir("harness-selftest-aux-");
    const file = (name, data) => {
        const p = path.join(aux, name);
        fs.writeFileSync(p, data);
        return p;
    };
    const utf16 = (s) => Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(s, "utf16le")]);
    const base = kit.isolatedEnv();
    for (const k of ["HARNESS_PRIVACY_LOCAL", "PRIVACY_NEEDLES", "GITHUB_ACTIONS", "CI"]) delete base[k];
    const run = (args, env = {}, self = SELF) => {
        const r = spawnSync(process.execPath, [self, ...args], {
            cwd: repo.dir,
            env: { ...base, ...env },
            encoding: "utf8",
        });
        return { code: r.status, out: `${r.stdout}${r.stderr}` };
    };
    const check = (label, bad, ok) => cases.push({ label: `end to end: ${label}`, bad, passed: !!ok });
    const commit = (msg) => {
        repo.git(["add", "-A"]);
        repo.git(["commit", "-q", "-m", msg]);
    };
    try {
        const nf = file("needles.txt", `# self-test\n${N}\n`);
        const local = { HARNESS_PRIVACY_LOCAL: nf };
        const tree = (env, ...extra) => run(["--root", repo.dir, ...extra], env);
        repo.write("docs/clean.md", "clean text\n");
        commit("ci(test): clean");
        check("a clean tree passes", false, tree(local).code === 0);
        check("--needles-file names the needle file", false, tree({}, "--needles-file", nf).code === 0);
        // The needle source must be named explicitly; the environment is never used to guess CI
        check("no local needles configured fails", true, tree({}).code === 1);
        check("local mode is not relaxed by CI=true", true, tree({ CI: "true", GITHUB_ACTIONS: "true" }).code === 1);
        check("a missing needle file fails", true, tree({ HARNESS_PRIVACY_LOCAL: `${nf}.missing` }).code === 1);
        check("ci mode without the secret fails", true, tree({}, "--needles", "ci").code === 1);
        const fork = tree({}, "--needles", "ci-optional");
        check("ci-optional without the secret: notice, generic rules", false, fork.code === 0 && fork.out.includes("PRIVACY_NEEDLES"));
        check("an unknown needle mode is a usage error", true, tree(local, "--needles", "maybe").code === 64);
        check("an unknown argument is a usage error", true, tree(local, "--bogus").code === 64);
        check("a UTF-16 needle file fails", true, tree({ HARNESS_PRIVACY_LOCAL: file("n16.txt", utf16(`${N}\n`)) }).code === 1);
        check("a needle file with NUL fails", true, tree({ HARNESS_PRIVACY_LOCAL: file("nnul.txt", `${N}\0\n`) }).code === 1);
        check("--text rejects UTF-16", true, run(["--text", file("t16.md", utf16("clean\n"))], local).code === 1);
        const nul = run(["--text", file("tnul.md", "clean\0\n")], local);
        check("--text rejects NUL and reports the offset", true, nul.code === 1 && nul.out.includes("byte offset 5"));
        // Characters nobody sees: in the middle of a path or a needle they hide it from every rule
        for (const [label, ch, code] of [
            ["a zero-width space", "\u200b", "200B"],
            ["a soft hyphen", "\u00ad", "00AD"],
            ["a direction override", "\u202e", "202E"],
            ["a word joiner", "\u2060", "2060"],
            ["a C1 control character", "\u0085", "0085"],
            ["a CR without its LF", "\r", "000D"],
            ["a format character beyond the first plane", "\u{e0001}", "E0001"],
        ]) {
            const r = run(["--text", file("thidden.md", `clean${ch}text\n`)], local);
            check(`--text rejects ${label}`, true, r.code === 1 && r.out.includes(`U+${code}`));
        }
        check("--text takes CRLF line ends", false, run(["--text", file("tcrlf.md", "clean\r\nmore\r\n")], local).code === 0);
        check("--text drops a byte order mark", false, run(["--text", file("tbom.md", "\ufeffclean\n")], local).code === 0);
        // Called through a junction or symlink the CLI still runs instead of silently doing nothing
        const link = path.join(aux, "scripts-link");
        fs.symlinkSync(path.dirname(SELF), link, process.platform === "win32" ? "junction" : "dir");
        const card = file("card.md", `${needles.CASES[0][1]}\n`);
        check("called through a link it still fails", true, run(["--text", card], local, path.join(link, "check-privacy.mjs")).code === 1);
        // Hiding places: plain file, UTF-16 file, binary text chunk, file name; still caught in history after deletion
        const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 0]), Buffer.from(`tEXtAuthor\0${N}\0`)]);
        // NUL only after byte 8000: git and this script treat it as text. The .gitattributes line makes git diff
        // a binary file as text: git gives line numbers, this script only has the binary view (line 0)
        const lateNul = Buffer.concat([Buffer.from(`note ${N}\n${"x".repeat(8100)}`), Buffer.from([0, 10])]);
        const forced = Buffer.concat([Buffer.from([0, 1, 0]), Buffer.from(` ${N} `), Buffer.from([0])]);
        const wavInfo = Buffer.concat([Buffer.from("RIFF\0\0\0\0WAVELIST\0\0\0\0INFOIART"), Buffer.from([0, 0, 0, 0]), Buffer.from(`${N}\0`)]);
        repo.write(".gitattributes", "*.dat diff\n");
        commit("ci(test): attributes");
        const leaks = [
            ["plain file", "docs/leak.md", `note ${N}\n`],
            ["UTF-16 file", "docs/log16.txt", utf16(`path ${N}\n`)],
            ["binary text chunk", "docs/shot.png", png],
            ["WAV INFO list", "tests/fixtures/x.wav", wavInfo],
            ["file name", `docs/notes-${N}.md`, "x\n"],
            ["NUL only after byte 8000", "docs/late.txt", lateNul],
            ["binary diffed as text", "docs/blob.dat", forced],
        ];
        for (const [label, rel, data] of leaks) {
            repo.write(rel, data);
            commit("ci(test): smuggle");
            const r = tree(local);
            check(`${label}: worktree fails, needle not echoed`, true, r.code === 1 && !r.out.includes(N));
            repo.git(["rm", "-q", rel]);
            commit("ci(test): remove");
            const h = run(["--root", repo.dir, "--commits", "HEAD~2..HEAD"], local);
            check(`${label}: history fails after deletion, needle not echoed`, true, h.code === 1 && !h.out.includes(N));
        }
        check("the tree passes once everything is removed", false, tree(local).code === 0);
        // Line mapping: with a space in the path git appends a TAB on the +++ line; only added lines count
        const old = `${needles.CASES[0][1]}\n`;
        repo.write("docs/a b.md", old);
        commit("ci(test): old content");
        repo.write("docs/a b.md", `${old}a clean new line\n`);
        commit("ci(test): one added line");
        check("a path with a space: only added lines", false, run(["--root", repo.dir, "--commits", "HEAD~1..HEAD"], local).code === 0);
        repo.git(["commit", "-q", "--allow-empty", "-m", `ci(test): ${N}`]);
        const range = ["--root", repo.dir, "--commits", "HEAD~1..HEAD"];
        check("a needle in a commit message fails", true, run(range, local).code === 1);
        check("--no-messages skips messages", false, run([...range, "--no-messages"], local).code === 0);
        const t = (label, input, want) => check(label, false, patchPath(input) === want);
        t("patch path: trailing TAB dropped", "b/a b.md\t", "a b.md");
        t("patch path: C-style quotes", '"b/q\\"x.md"', 'q"x.md');
        t("patch path: octal escapes", '"b/\\346\\226\\207.md"', "文.md");
    } finally {
        repo.cleanup();
        cleanupTempDir(aux);
    }
    return caseResult(cases);
}

const OWN = { "--root": 1, "--text": 1, "--no-messages": 0, "--commits": 0, ...needles.NEEDLE_FLAGS };

function main(argv) {
    kit.assertNodeVersion();
    if (argv.includes("--list-rules")) {
        for (const r of needles.RULES) console.log(`  ${r.id}${r.binary ? " (binary files too)" : ""}`);
        console.log("  personal (personal needles, no exemption, binary files too)");
        return 0;
    }
    if (argv.includes("--self-test")) return kit.reportSelfTest("check-privacy", selfTest());
    if (argv.includes("--mutation-check")) {
        const r = needles.mutationCheck();
        for (const s of r.survived) console.error(`  mutant not caught by any fixture: ${s}`);
        console.log(`check-privacy --mutation-check: ${r.total} mutants, ${r.survived.length} survived`);
        return r.survived.length ? 1 : 0;
    }
    const opts = {};
    const free = [];
    for (let i = 0; i < argv.length; i++) {
        if (argv[i] in OWN) opts[argv[i]] = OWN[argv[i]] ? argv[++i] : true;
        else free.push(argv[i]);
    }
    if (free.length && !opts["--commits"]) throw new UsageError(`unknown arguments: ${free.join(" ")}`);
    if (opts["--commits"] && !free.length) throw new UsageError("--commits needs a revision range");
    const root = opts["--root"] ? path.resolve(opts["--root"]) : ROOT;
    const personal = needles.loadPersonalNeedles({ cwd: root, ...needles.needlesArgs(argv) });
    if (opts["--commits"]) {
        const found = scanCommits(free, root, personal.needles, { messages: !opts["--no-messages"] });
        return report(found, personal.notes);
    }
    if (opts["--text"]) {
        const src = opts["--text"];
        const text = needles.plainText(fs.readFileSync(src === "-" ? 0 : src), "the --text input");
        return report(tag("text", scan(text, {}, { personal: personal.needles })), personal.notes);
    }
    return report(scanTree(root, personal.needles), personal.notes);
}

kit.runCli("check-privacy", import.meta.url, main);
