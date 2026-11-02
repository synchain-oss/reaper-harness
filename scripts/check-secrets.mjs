// SPDX-License-Identifier: MIT
//
// Secret scan of a commit range with the pinned gitleaks: the one place for how the range is read and for what counts as a
// clean answer. The pre-push hook, scripts/maintainer/push.ps1 and CI all come through here.
//   node scripts/check-secrets.mjs [--repo <dir>] --commits <rev-list args...>
//   node scripts/check-secrets.mjs --self-test
// The exit code of gitleaks alone proves nothing: when git fails underneath it (an unknown revision, an option this git does
// not know, a directory that is not a repository) it logs the error, scans nothing and still exits 0. So clean means all of:
// exit code 0, no error line in its log, its count line present, and that count above 0 whenever git itself lists added lines
// in the range. A count of 0 is right for a range with nothing to read: no commits, or commits that only delete, rename or add
// binary files. git has to know --diff-merges=first-parent (git 2.31 or newer); an older git makes the scan fail, never pass.
// gitleaks comes from HARNESS_GITLEAKS or git config harness.gitleaks; its version must equal .gitleaks-version.
// Exit codes: 0 clean, 1 findings or a scan that did not finish, 64 usage error.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import * as kit from "./lib/check-kit.mjs";
import { cleanupTempDir, makeTempDir } from "./lib/safe-rm.mjs";

const { ROOT, UsageError, caseResult, git, j, localSetting, tempRepo } = kit;

// gitleaks runs git log -p itself; external diff and textconv drivers would rewrite the patches, and without first-parent diffs
// a merge commit shows no patch, so content that only the merge adds would not be scanned
const LOG_OPTS = ["--no-ext-diff", "--no-textconv", "--diff-merges=first-parent"];
const SAID_MAX = 4096;

/** The output of `gitleaks version` must be exactly the pinned version (a leading v aside). */
export function versionErrors(output, want) {
    const have = (output || "").trim().replace(/^v/, "");
    return have === want ? [] : [`gitleaks must be ${want} (.gitleaks-version), found ${have || "nothing"}`];
}

/** Added text lines git lists for the range, read with the options gitleaks gets. Throws when git cannot read the range. */
export function addedLines(revArgs, cwd, env) {
    let added = 0;
    for (const m of git(["log", "--numstat", "--format=", ...LOG_OPTS, ...revArgs], { cwd, env }).matchAll(/^(\d+)\t/gm)) added += Number(m[1]);
    return added;
}

/**
 * What a gitleaks run says: { ok, finding, message }. A finding is exit code 1 with its own "leaks found" line; everything that
 * is neither a finding nor a proven clean scan means the range was not scanned. The output is safe to show: it runs with --redact.
 */
export function judgeScan({ status, output, added }) {
    const text = output.replace(/\x1b\[[0-9;]*m/g, "").trim();
    const said = text.length > SAID_MAX ? `${text.slice(0, SAID_MAX)}... (output cut at ${SAID_MAX} characters)` : text;
    const notFinished = (why) => ({ ok: false, finding: false, message: `gitleaks did not finish normally (${why}): ${said}` });
    if (status === 1 && /(?<!no )leaks found/.test(text)) return { ok: false, finding: true, message: `gitleaks reported findings: ${said}` };
    if (status !== 0) return notFinished(`exit code ${status}`);
    if (/^(?:\S+\s+)?(?:ERR|FTL)\s/m.test(text)) return notFinished("it logged an error under exit code 0, the range was not scanned");
    const count = /^(?:\S+\s+)?INF (\d+) commits? scanned/m.exec(text);
    if (!count) return notFinished("its log has no 'commits scanned' line");
    if (Number(count[1]) === 0 && added > 0) return notFinished(`0 commits scanned although the range adds ${added} line(s)`);
    return { ok: true, finding: false, message: `gitleaks scanned ${count[1]} commit(s), no findings` };
}

/** One gitleaks run over the range; the exit code and everything it printed. */
export function runGitleaks(bin, revArgs, cwd, env) {
    const logOpts = [...revArgs, ...LOG_OPTS].join(" ");
    const r = spawnSync(bin, ["git", "--no-banner", "--no-color", "--redact", "-v", `--log-opts=${logOpts}`, "."], { cwd, env, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
    return { status: r.status, output: `${r.stdout ?? ""}${r.stderr ?? ""}${r.error ? r.error.message : ""}` };
}

/** The scan of a range: { ok, finding, message }. run is the gitleaks run, the self-test puts answers of a broken tool there. */
export function scanRange(revArgs, { cwd = process.cwd(), env = process.env, run = runGitleaks } = {}) {
    const bin = localSetting("HARNESS_GITLEAKS", "harness.gitleaks", { env, cwd }) || "gitleaks";
    const want = fs.readFileSync(path.join(ROOT, ".gitleaks-version"), "utf8").trim();
    const wrong = versionErrors(spawnSync(bin, ["version"], { env, encoding: "utf8" }).stdout, want);
    if (wrong.length) return { ok: false, finding: false, message: wrong[0] };
    let added;
    try {
        added = addedLines(revArgs, cwd, env);
    } catch (e) {
        return { ok: false, finding: false, message: `git cannot read the commit range (an unknown revision, an option this git does not know, not a repository): ${e.message}` };
    }
    return judgeScan({ ...run(bin, revArgs, cwd, env), added });
}

export function selfTest() {
    const cases = [];
    const t = (label, bad, flagged) => cases.push({ label, bad, passed: bad ? flagged : !flagged });
    // the log of gitleaks 8.30.1 as it prints it
    const log = (n) => `5:00AM INF ${n} commits scanned.\n5:00AM INF scanned ~2 bytes (2 bytes) in 261ms\n5:00AM INF no leaks found\n`;
    const gitFailed = '5:00AM ERR [git] fatal: unrecognized argument: --nope\n5:00AM ERR error="stderr is not empty"\n';
    const judged = (status, output, added = 0) => judgeScan({ status, output, added });
    t("verdict: exit 0 with a count above 0 is clean", false, !judged(0, log(2), 5).ok);
    t("verdict: exit 0, a count of 0 and nothing added is clean", false, !judged(0, log(0), 0).ok);
    t("verdict: a count of 0 although the range adds lines", true, !judged(0, log(0), 3).ok && /adds 3 line/.test(judged(0, log(0), 3).message));
    t("verdict: no count line", true, !judged(0, "5:00AM INF no leaks found\n", 0).ok);
    t("verdict: an error line under exit 0", true, !judged(0, `${gitFailed}${log(0)}`).ok);
    t("verdict: an error line next to a count above 0", true, !judged(0, `${gitFailed}${log(1)}`, 1).ok);
    t("verdict: a fatal line under exit 0", true, !judged(0, `5:00AM FTL failed to scan\n${log(1)}`, 1).ok);
    t("verdict: the word ERR inside an info line is no error line", false, !judged(0, `5:00AM INF ERR is just a word here\n${log(1)}`, 1).ok);
    t("verdict: an error line says why and what git said", true, /logged an error.*unrecognized argument/s.test(judged(0, `${gitFailed}${log(0)}`).message));
    const found = judged(1, "Finding:     REDACTED\n5:00AM WRN leaks found: 1\n", 1);
    t("verdict: exit 1 with its finding line is a finding", true, found.finding && !found.ok && /^gitleaks reported findings/.test(found.message));
    t("verdict: a finding carries the output of gitleaks", true, /REDACTED/.test(found.message));
    for (const [label, status, output] of [
        ["exit 1 without a finding line", 1, "5:00AM FTL CreateFile wt: cannot find the file"],
        ["exit 1 that says no leaks", 1, "5:00AM INF no leaks found"],
        ["another exit code with the words of a finding", 2, "5:00AM WRN leaks found: 1"],
        ["a gitleaks that could not start", null, "spawn gitleaks ENOENT"],
        ["exit 1 behind a log that reads clean", 1, log(2)],
        ["exit 2 behind a log that reads clean", 2, log(2)],
    ]) {
        const r = judged(status, output);
        t(`verdict: ${label}: not a finding, and not clean`, true, !r.ok && !r.finding && /^gitleaks did not finish normally/.test(r.message) && r.message.includes(output.trim()));
    }
    t("verdict: colour codes are removed from the message", true, !/\x1b/.test(judged(1, "\x1b[33mWRN\x1b[0m leaks found: 1").message));
    t("verdict: a long output is cut", true, /output cut at 4096 characters/.test(judged(1, `${"x".repeat(9000)}\nleaks found: 1`).message));
    t("version: the pinned one", false, versionErrors("8.30.1\n", "8.30.1").length > 0);
    t("version: the pinned one with a leading v", false, versionErrors("v8.30.1", "8.30.1").length > 0);
    t("version: another one", true, versionErrors("8.30.0", "8.30.1").length > 0);
    t("version: no output", true, versionErrors(undefined, "8.30.1").length > 0);

    // The real tool on a real repository: the exit-0-without-a-scan shapes above come from here
    const gitleaks = localSetting("HARNESS_GITLEAKS", "harness.gitleaks", { cwd: ROOT }) || "gitleaks";
    if (spawnSync(gitleaks, ["version"], { encoding: "utf8" }).status !== 0) {
        const note = "gitleaks not found; end-to-end part not run (set HARNESS_GITLEAKS or git config harness.gitleaks)";
        // CI must run everything: missing gitleaks fails there; locally it is a note
        if (kit.inCI()) cases.push({ label: note, bad: true, passed: false });
        const r = caseResult(cases);
        if (!kit.inCI()) r.lines.push(note);
        return r;
    }
    const repo = tempRepo();
    const elsewhere = makeTempDir("harness-selftest-");
    const env = { ...repo.env, HARNESS_GITLEAKS: gitleaks };
    const scanOf = (...rev) => scanRange(rev, { cwd: repo.dir, env });
    const commit = (message, files = {}, extra = []) => {
        for (const [rel, data] of Object.entries(files)) repo.write(rel, data);
        repo.git(["add", "-A"]);
        repo.git(["commit", "-q", "--allow-empty", ...extra, "-m", message]);
        return repo.git(["rev-parse", "HEAD"]).trim();
    };
    const leak = j("gh", "p_", "Zr8XcV2nQ7tLm4Kp9Ws6Yb3Hd5Fg1Jq0Ae2T");
    try {
        const base = commit("base", { "a.txt": "one\n", "gone.txt": "two\n" });
        const clean = commit("clean", { "b.txt": "three\n" });
        t("real: a clean commit", false, !scanOf(`${base}..${clean}`).ok);
        t("real: the increment with --not, as the hook asks", false, !scanOf(clean, "--not", base).ok);
        t("real: an empty range is clean: nothing to scan", false, !scanOf(`${clean}..${clean}`).ok);
        const empty = commit("empty");
        t("real: a commit without changes is clean", false, !scanOf(`${clean}..${empty}`).ok);
        repo.git(["rm", "-q", "gone.txt"]);
        const deleted = commit("delete");
        t("real: a commit that only deletes is clean: gitleaks counts 0 and that is right", false, !scanOf(`${empty}..${deleted}`).ok);
        const binary = commit("binary", { "c.bin": Buffer.from([0, 1, 2, 3]) });
        t("real: a commit that only adds a binary file is clean", false, !scanOf(`${deleted}..${binary}`).ok);

        const dirty = commit("credential", { "d.txt": `auth = "${leak}"\n` });
        const caught = scanOf(`${binary}..${dirty}`);
        t("real: a credential is a finding", true, caught.finding && !caught.ok);
        t("real: the message does not show the credential", true, !caught.message.includes(leak));
        t("real: a credential behind --not, as the hook asks", true, scanOf(dirty, "--not", binary).finding);
        const after = commit("after", { "e.txt": "clean\n" });
        t("real: only the range is scanned, a credential before it is not its finding", false, !scanOf(`${dirty}..${after}`).ok);
        repo.git(["reset", "-q", "--hard", binary]);
        // the credential is in the merge commit only: neither parent has it, so a plain git log -p shows nothing
        repo.git(["checkout", "-q", "-b", "side", "HEAD~1"]);
        commit("side", { "side.txt": "clean\n" });
        repo.git(["checkout", "-q", "-"]);
        repo.git(["merge", "-q", "--no-ff", "--no-commit", "side"]);
        const merged = commit("merge", { "m.txt": `auth = "${leak}"\n` });
        t("real: a credential that only the merge commit adds", true, scanOf(`${binary}..${merged}`).finding);
        // what the count of gitleaks is held against: side.txt once in its commit, and side.txt and m.txt in the merge against its first parent
        const addedIn = (range) => addedLines([range], repo.dir, env);
        t("real: git lists the lines a range adds", false, addedIn(`${base}..${clean}`) !== 1);
        t("real: git lists no lines for a commit that only deletes", false, addedIn(`${empty}..${deleted}`) !== 0);
        t("real: git lists no lines for a binary file", false, addedIn(`${deleted}..${binary}`) !== 0);
        t("real: git lists the lines of a merge commit", false, addedIn(`${binary}..${merged}`) !== 3);
        // a gitleaks that counts nothing, on a range that does add lines
        const silent = scanRange([`${base}..${clean}`], { cwd: repo.dir, env, run: () => ({ status: 0, output: log(0) }) });
        t("real: gitleaks counts 0 on a range that adds lines: not clean", true, !silent.ok && !silent.finding && /adds 1 line/.test(silent.message));
        repo.git(["reset", "-q", "--hard", binary]);

        const reasonIs = (r, word) => !r.ok && !r.finding && word.test(r.message);
        t("real: an unknown revision is not clean", true, reasonIs(scanOf("harness-no-such-revision"), /git cannot read the commit range/));
        t("real: an option this git does not know is not clean", true, reasonIs(scanOf(`${base}..${binary}`, "--harness-no-such-option"), /git cannot read the commit range/));
        t("real: a directory that is not a repository is not clean", true, reasonIs(scanRange([base], { cwd: elsewhere, env }), /git cannot read the commit range/));
        t("real: a gitleaks that does not run is not clean", true, reasonIs(scanRange([base], { cwd: repo.dir, env: { ...env, HARNESS_GITLEAKS: path.join(elsewhere, "no-such-gitleaks") } }), /must be .* found nothing/));
        // the pinned tool itself, without the read of the range in front of it: it exits 0 and only its log tells
        for (const [label, rev, dir] of [
            ["an unknown revision", ["harness-no-such-revision"], repo.dir],
            ["an unknown option", [`${base}..${binary}`, "--harness-no-such-option"], repo.dir],
            ["a directory that is not a repository", ["HEAD"], elsewhere],
        ]) {
            const run = runGitleaks(gitleaks, rev, dir, env);
            t(`real: gitleaks alone on ${label}: exit 0, and the verdict still says not scanned`, true, run.status === 0 && !judgeScan({ ...run, added: 0 }).ok);
        }
        // the command line that CI and the wrapper use: exit codes 0, 1 and 64
        const cli = (args, from = repo.dir) => spawnSync(process.execPath, [fileURLToPath(import.meta.url), ...args], { cwd: from, env, encoding: "utf8" }).status;
        t("command line: a clean range exits 0", false, cli(["--commits", `${base}..${clean}`]) !== 0);
        t("command line: --repo names the repository", false, cli(["--repo", repo.dir, "--commits", `${base}..${clean}`], ROOT) !== 0);
        t("command line: a range that cannot be read exits 1", true, cli(["--commits", "harness-no-such-revision"]) === 1);
        t("command line: a credential exits 1", true, cli(["--commits", `${binary}..${dirty}`]) === 1);
        t("command line: no arguments", true, cli([]) === 64);
        t("command line: --repo without a directory", true, cli(["--repo"]) === 64);
        t("command line: --commits without a range", true, cli(["--commits"]) === 64);
    } finally {
        repo.cleanup();
        cleanupTempDir(elsewhere);
    }
    return caseResult(cases);
}

function main(argv) {
    if (argv[0] === "--self-test") return kit.reportSelfTest("check-secrets", selfTest());
    kit.assertNodeVersion();
    const usage = "usage: check-secrets.mjs [--repo <dir>] --commits <rev-list args...>";
    const fromRepo = argv[0] === "--repo";
    const rest = fromRepo ? argv.slice(2) : argv;
    if ((fromRepo && !argv[1]) || rest[0] !== "--commits" || rest.length < 2) throw new UsageError(usage);
    const r = scanRange(rest.slice(1), { cwd: fromRepo ? path.resolve(argv[1]) : process.cwd() });
    (r.ok ? console.log : console.error)(r.message);
    return r.ok ? 0 : 1;
}

kit.runCli("check-secrets", import.meta.url, main);
