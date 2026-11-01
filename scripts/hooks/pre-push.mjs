// SPDX-License-Identifier: MIT
//
// Criteria of the pre-push hook (the shell is pre-push next to this file). Pushed means public: refs/pull
// and forks keep it for good and deleting the branch does not take it back, so every push is checked:
//   1. Remote refs: only refs/heads/feat/<slug> (deletions included), the name free of private numbers and
//      personal needles. Long-lived branches (dev, prod, feature/*) only with HARNESS_ALLOW_LONGLIVED_PUSH=1,
//      tags (v*) only with HARNESS_ALLOW_TAG_PUSH=1; a tag may only point at commits the remote already
//      has, and an annotated tag's tagger and message are checked too. Pushed branches only fast-forward.
//   2. To GitHub the URL must carry DLsnows@ and gh's DLsnows credential must resolve to DLsnows.
//   3. Every commit the remote does not have yet: author and committer are the maintainer identity; the
//      same-repository rules of check-commits; privacy rules and personal needles (message, added content,
//      new paths).
//   4. gitleaks over the same commits, its version equal to .gitleaks-version (HARNESS_GITLEAKS or
//      git config harness.gitleaks).
//   node scripts/hooks/pre-push.mjs <remote name> <URL>   (ref update lines on stdin)
//   node scripts/hooks/pre-push.mjs --self-test

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { MAINTAINER, checkBranch, checkMessage } from "../check-commits.mjs";
import { formatFinding, scanCommits } from "../check-privacy.mjs";
import { FAKE_NEEDLE, loadPersonalNeedles, mask, redact, scan } from "../lib/privacy-needles.mjs";
import * as kit from "../lib/check-kit.mjs";
import { HOOKS } from "./commit-msg.mjs";

const { ROOT, caseResult, git, j, localSetting, tempRepo } = kit;
const ZERO = /^0+$/;
const LONG_LIVED = /^(?:dev|prod|feature\/[a-z0-9][a-z0-9.-]*)$/;

/** Each stdin line is "local ref, local sha, remote ref, remote sha"; malformed lines must not be dropped silently. */
export function parseUpdates(stdin) {
    return stdin
        .split(/\r?\n/)
        .filter((l) => l.trim())
        .map((l) => {
            const p = l.trim().split(/\s+/);
            const sha = /^[0-9a-f]{40,64}$/;
            if (p.length !== 4 || !sha.test(p[1]) || !sha.test(p[3])) throw new Error("malformed pre-push input line");
            return p;
        });
}

export function checkRef(remoteRef, { env = process.env, personal = [] } = {}) {
    if (remoteRef.startsWith("refs/heads/")) {
        const name = remoteRef.slice("refs/heads/".length);
        if (name.startsWith("feat/")) return checkBranch({ head: name, personal });
        if (LONG_LIVED.test(name) && env.HARNESS_ALLOW_LONGLIVED_PUSH === "1") return [];
        return [`only refs/heads/feat/* may be pushed (long-lived branches need HARNESS_ALLOW_LONGLIVED_PUSH=1): ${mask(remoteRef, personal)}`];
    }
    if (/^refs\/tags\/v\d[0-9A-Za-z.-]*$/.test(remoteRef) && env.HARNESS_ALLOW_TAG_PUSH === "1") return [];
    return [`refusing to push ${mask(remoteRef, personal)}`];
}

/** Remotes that are not GitHub (local paths and the like) publish nothing; no account check. */
export function checkRemote(url, ghLogin) {
    if (!/github\.com[/:]/i.test(url)) return [];
    if (!/^https:\/\/DLsnows@github\.com\//.test(url)) return ["a GitHub remote URL must carry DLsnows@"];
    return ghLogin() === "DLsnows" ? [] : ["gh's DLsnows credential does not resolve to DLsnows; refusing to push"];
}

/** An annotated tag carries its own tagger and message, independent of its commit; a lightweight tag has neither. */
function checkTag(sha, cwd, personal) {
    if (git(["cat-file", "-t", sha], { cwd }).trim() !== "tag") return [];
    const raw = git(["cat-file", "tag", sha], { cwd });
    const cut = raw.indexOf("\n\n");
    const tagger = /^tagger (.+?) \d+ [+-]\d{4}$/m.exec(cut < 0 ? raw : raw.slice(0, cut))?.[1];
    const errors = tagger === MAINTAINER ? [] : [`the tagger must be ${MAINTAINER}`];
    const message = cut < 0 ? "" : raw.slice(cut + 2);
    for (const f of scan(message, {}, { personal })) errors.push(`tag message line ${f.line} [${f.rule.id}] ${redact(f)}`);
    return errors;
}

const run = (cmd, args, env) => spawnSync(cmd, args, { env, encoding: "utf8" });

function ghLogin(env) {
    const token = env.GH_TOKEN || run("gh", ["auth", "token", "--user", "DLsnows"], env).stdout?.trim();
    return (run("gh", ["api", "user", "--jq", ".login"], { ...env, GH_TOKEN: token }).stdout || "").trim();
}

/** The output of `gitleaks version` must be exactly the pinned version (a leading v aside). */
export function versionErrors(output, want) {
    const have = (output || "").trim().replace(/^v/, "");
    return have === want ? [] : [`gitleaks must be ${want} (.gitleaks-version), found ${have || "nothing"}`];
}

function gitleaksCheck(revArgs, cwd, env) {
    const bin = localSetting("HARNESS_GITLEAKS", "harness.gitleaks", { env, cwd }) || "gitleaks";
    const want = fs.readFileSync(path.join(ROOT, ".gitleaks-version"), "utf8").trim();
    const wrong = versionErrors(run(bin, ["version"], env).stdout, want);
    if (wrong.length) return wrong;
    // gitleaks runs git log -p itself; external diff and textconv drivers would rewrite the patches
    const logOpts = [...revArgs, "--no-ext-diff", "--no-textconv"].join(" ");
    const r = spawnSync(bin, ["git", "--no-banner", "--no-color", "--redact", "-v", `--log-opts=${logOpts}`, "."], { cwd, env, encoding: "utf8" });
    if (r.status === 0) return [];
    return ["gitleaks found possible secrets (redacted):", ...`${r.stdout}${r.stderr}`.trim().split("\n").map((l) => `  ${l}`)];
}

export function prePush({ updates, remote, url, cwd, env, needles, login = () => ghLogin(env) }) {
    const errors = [];
    for (const [, localSha, remoteRef, remoteSha] of updates) {
        errors.push(...checkRef(remoteRef, { env, personal: needles }));
        if (ZERO.test(localSha)) continue; // deleting a remote branch carries no content
        const hasOld = !ZERO.test(remoteSha) && git(["cat-file", "-e", remoteSha], { cwd, allowFail: true }) !== null;
        if (remoteRef.startsWith("refs/heads/") && !ZERO.test(remoteSha)) {
            // A pushed branch only fast-forwards: published history is never rewritten
            if (!hasOld) errors.push("the remote branch's commit is not available locally: fetch first");
            else if (git(["merge-base", "--is-ancestor", remoteSha, localSha], { cwd, allowFail: true }) === null) {
                errors.push("non-fast-forward pushes are not allowed: published history cannot be rewritten");
            }
        }
        // Only commits the remote does not have: anything on a remote branch is already public
        const revArgs = [localSha, ...(hasOld ? [`^${remoteSha}`] : []), "--not", `--remotes=${remote}`];
        const shas = git(["rev-list", ...revArgs], { cwd }).split("\n").filter(Boolean);
        if (remoteRef.startsWith("refs/tags/")) {
            if (shas.length) errors.push("a tag may only point at commits the remote already has");
            errors.push(...checkTag(localSha, cwd, needles));
            continue;
        }
        if (!shas.length) continue;
        for (const sha of shas) {
            const [author, committer, parents, message] = git(["log", "-1", "--format=%an <%ae>%x00%cn <%ce>%x00%P%x00%B", sha], { cwd }).split("\0");
            const s7 = sha.slice(0, 7);
            if (author !== MAINTAINER || committer !== MAINTAINER) errors.push(`${s7} author and committer must be ${MAINTAINER}`);
            const merge = parents.trim().includes(" ");
            errors.push(...checkMessage(message, { merge, personal: needles }).errors.map((e) => `${s7} ${e}`));
        }
        errors.push(...scanCommits(revArgs, cwd, needles, { messages: false }).map(formatFinding));
        errors.push(...gitleaksCheck(revArgs, cwd, env));
    }
    if (updates.length) errors.push(...checkRemote(url, login));
    return errors;
}

export function selfTest() {
    const cases = [];
    const t = (label, bad, errors) => cases.push({ label, bad, passed: bad ? errors.length > 0 : errors.length === 0 });
    const ref = (r, env = {}) => checkRef(r, { env, personal: [FAKE_NEEDLE] });
    const longLived = { HARNESS_ALLOW_LONGLIVED_PUSH: "1" };
    t("ref: feat/<slug>", false, ref("refs/heads/feat/check-scripts"));
    t("ref: dev", true, ref("refs/heads/dev"));
    t("ref: feature/v1", true, ref("refs/heads/feature/v1"));
    t("ref: feature/v1 with the long-lived switch", false, ref("refs/heads/feature/v1", longLived));
    t("ref: dev with the long-lived switch", false, ref("refs/heads/dev", longLived));
    t("ref: main even with the long-lived switch", true, ref("refs/heads/main", longLived));
    t("ref: the switch set to something else than 1", true, ref("refs/heads/dev", { HARNESS_ALLOW_LONGLIVED_PUSH: "true" }));
    t("ref: card number in the branch name", true, ref(j("refs/heads/feat/r", "h-01")));
    t("ref: personal needle in the branch name", true, ref(`refs/heads/feat/${FAKE_NEEDLE}`));
    t("ref: tag without the switch", true, ref("refs/tags/v0.9.0-rc.1"));
    t("ref: tag with the switch", false, ref("refs/tags/v0.9.0-rc.1", { HARNESS_ALLOW_TAG_PUSH: "1" }));
    t("ref: non-version tag with the switch", true, ref("refs/tags/latest", { HARNESS_ALLOW_TAG_PUSH: "1" }));
    t("ref: notes ref", true, ref("refs/notes/commits"));
    const url = "https://DLsnows@github.com/synchain-oss/reaper-harness.git";
    t("remote: GitHub URL without DLsnows@", true, checkRemote(url.replace("DLsnows@", ""), () => "DLsnows"));
    t("remote: credential resolves to another account", true, checkRemote(url, () => "someone-else"));
    t("remote: DLsnows", false, checkRemote(url, () => "DLsnows"));
    t("remote: a local path needs no account", false, checkRemote("/tmp/x.git", () => ""));
    const z = "0".repeat(40);
    const del = [["(delete)", z, "refs/heads/feat/x", "a".repeat(40)]];
    const pushTo = (login) => prePush({ updates: del, remote: "origin", url, cwd: ROOT, env: {}, needles: [], login });
    t("push: a GitHub remote checks the account", true, pushTo(() => "someone-else"));
    t("push: a GitHub remote with the DLsnows account", false, pushTo(() => "DLsnows"));
    t("input: four fields", false, parseUpdates(`refs/heads/feat/x ${"a".repeat(40)} refs/heads/feat/x ${z}\n`).length ? [] : ["x"]);
    let threw = false;
    try {
        parseUpdates("refs/heads/feat/x deadbeef\n");
    } catch {
        threw = true;
    }
    cases.push({ label: "input: a malformed line fails", bad: true, passed: threw });
    t("gitleaks: the pinned version", false, versionErrors("8.30.1\n", "8.30.1"));
    t("gitleaks: the pinned version with a leading v", false, versionErrors("v8.30.1", "8.30.1"));
    t("gitleaks: another version", true, versionErrors("8.30.0", "8.30.1"));
    t("gitleaks: no output", true, versionErrors(undefined, "8.30.1"));

    // End to end through the real sh shell into a local bare repository. Bad commits are made in the temp repository
    // without hooks; the hook is attached only to the push.
    const gitleaks = localSetting("HARNESS_GITLEAKS", "harness.gitleaks", { cwd: ROOT }) || "gitleaks";
    if (run(gitleaks, ["version"], process.env).status !== 0) {
        const note = "gitleaks not found; end-to-end part not run (set HARNESS_GITLEAKS or git config harness.gitleaks)";
        // CI must run everything: missing gitleaks fails there; locally it is a note
        if (kit.inCI()) cases.push({ label: note, bad: true, passed: false });
        const r = caseResult(cases);
        if (!kit.inCI()) r.lines.push(note);
        return r;
    }
    const remote = tempRepo({ bare: true });
    const repo = tempRepo();
    const nf = `${repo.dir}-needles.txt`;
    fs.writeFileSync(nf, `${FAKE_NEEDLE}\n`);
    const env = { ...repo.env, HARNESS_NODE: process.execPath, HARNESS_PRIVACY_LOCAL: nf, HARNESS_GITLEAKS: gitleaks };
    const push = (label, bad, refspec, extra = [], more = {}) => {
        const args = ["-c", `core.hooksPath=${HOOKS}`, "push", "-q", ...extra, "origin", refspec];
        const ok = repo.git(args, { env: { ...env, ...more }, allowFail: true });
        cases.push({ label: `end to end: ${label}`, bad, passed: bad ? ok === null : ok !== null });
    };
    const signed = "\n\nSigned-off-by: DLsnows <noreply@synchain.ca>";
    const commit = (file, text, msg, gitOpts = [], commitOpts = []) => {
        repo.write(file, text);
        repo.git(["add", "."]);
        repo.git([...gitOpts, "commit", "-q", ...commitOpts, "-m", msg]);
    };
    const bad = (label, ...args) => {
        commit(...args);
        push(label, true, "HEAD:refs/heads/feat/ok");
        repo.git(["reset", "-q", "--hard", "HEAD~1"]);
    };
    const other = ["-c", "user.name=Other", "-c", "user.email=other@example.com"];
    try {
        repo.git(["remote", "add", "origin", remote.dir]);
        commit("docs/a.md", "clean\n", `docs(test): clean${signed}`);
        push("a good commit to feat/", false, "HEAD:refs/heads/feat/ok");
        commit("docs/b.md", "clean\n", `docs(test): one more${signed}`);
        push("fast-forward push", false, "HEAD:refs/heads/feat/ok");
        push("a long-lived branch", true, "HEAD:refs/heads/dev");
        push("a long-lived branch with the switch", false, "HEAD:refs/heads/feature/v1", [], { HARNESS_ALLOW_LONGLIVED_PUSH: "1" });
        push("card number in the branch name", true, j("HEAD:refs/heads/feat/r", "h-01a"));
        push("personal needle in the branch name", true, `HEAD:refs/heads/feat/${FAKE_NEEDLE}`);
        const tip = repo.git(["rev-parse", "HEAD"]).trim();
        repo.git(["reset", "-q", "--hard", "HEAD~1"]);
        commit("docs/c.md", "clean\n", `docs(test): rewritten history${signed}`);
        push("force push rewriting published history", true, "HEAD:refs/heads/feat/ok", ["--force"]);
        repo.git(["reset", "-q", "--hard", tip]);
        bad("added content with a personal needle", "docs/d.md", `${FAKE_NEEDLE}\n`, `docs(test): smuggle${signed}`);
        bad("a new path with a card number (empty file: no +++ line)", j("docs/R", "H-01.md"), "", `docs(test): path${signed}`);
        bad("a message without sign-off", "docs/e.md", "x\n", "docs(test): unsigned");
        bad("an author who is not the maintainer", "docs/f.md", "x\n", `docs(test): someone else${signed}`, [], ["--author=Other <other@example.com>"]);
        bad("a committer who is not the maintainer", "docs/f.md", "x\n", `docs(test): someone else${signed}`, other, [`--author=${MAINTAINER}`]);
        const leak = j("gh", "p_", "Zr8XcV2nQ7tLm4Kp9Ws6Yb3Hd5Fg1Jq0Ae2T");
        bad("gitleaks catches a credential", "src/g.txt", `auth = "${leak}"\n`, `docs(test): credential${signed}`);
        const allow = { HARNESS_ALLOW_TAG_PUSH: "1" };
        repo.git(["tag", "-a", "v0.0.1", "-m", "v0.0.1"]);
        push("an annotated tag with the switch", false, "refs/tags/v0.0.1", [], allow);
        repo.git([...other, "tag", "-a", "v0.0.2", "-m", "v0.0.2"]);
        push("an annotated tag by another tagger", true, "refs/tags/v0.0.2", [], allow);
        repo.git(["tag", "-a", "v0.0.4", "-m", `release ${FAKE_NEEDLE}`]);
        push("an annotated tag with a personal needle in its message", true, "refs/tags/v0.0.4", [], allow);
        commit("docs/h.md", "clean\n", `docs(test): not on the remote${signed}`);
        repo.git(["tag", "v0.0.3"]);
        push("a tag on a commit the remote lacks", true, "refs/tags/v0.0.3", [], allow);
        repo.git(["reset", "-q", "--hard", "HEAD~1"]);
        push("deleting a feat/ branch", false, ":refs/heads/feat/ok");
    } finally {
        repo.cleanup();
        remote.cleanup();
        fs.rmSync(nf, { force: true });
    }
    return caseResult(cases);
}

function main(argv) {
    if (argv[0] === "--self-test") return kit.reportSelfTest("pre-push", selfTest());
    const [remote, url = ""] = argv;
    const cwd = process.cwd();
    let errors;
    try {
        kit.assertNodeVersion();
        if (!remote) throw new Error("usage: pre-push.mjs <remote name> <URL>");
        const updates = parseUpdates(fs.readFileSync(0, "utf8"));
        const { needles } = loadPersonalNeedles({ cwd, mode: "local" });
        errors = prePush({ updates, remote, url, cwd, env: process.env, needles });
    } catch (e) {
        errors = [e.message];
    }
    if (!errors.length) return 0;
    console.error("pre-push rejected the push:");
    for (const e of errors) console.error(`  ${e}`);
    return 1;
}

if (kit.isMain(import.meta.url)) process.exitCode = main(process.argv.slice(2));
