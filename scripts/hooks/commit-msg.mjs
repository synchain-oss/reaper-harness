// SPDX-License-Identifier: MIT
//
// Criteria of the commit-msg hook (the shell is commit-msg next to this file). Two rules stricter than the
// same-repository tier of check-commits: author and committer are both the maintainer identity, and there
// is exactly one sign-off. The message goes through the generic rules, the personal needles and the AI
// trailer rule, and so do the comment lines git puts into the editor (with -m, lines starting with # stay
// in the history).
//   node scripts/hooks/commit-msg.mjs <message file>
//   node scripts/hooks/commit-msg.mjs --self-test    pure fixtures, plus commits through the real hook in a temp repository

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { MAINTAINER, SIGNOFF, checkMessage, hasAiTrailer } from "../check-commits.mjs";
import { FAKE_NEEDLE, loadPersonalNeedles, redact, scan } from "../lib/privacy-needles.mjs";
import { assertNodeVersion, caseResult, git, isMain, j, reportSelfTest, tempRepo } from "../lib/check-kit.mjs";

export const HOOKS = path.dirname(fileURLToPath(import.meta.url));

export function checkCommitMsg(raw, { authorIdent, committerIdent, personal = [] }) {
    const kept = [];
    const comments = [];
    const lines = raw.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
        // Only git's own scissors line (followed by its comment) ends the message: with --verbose the diff
        // follows it. The same line given with -m stays in the message, so it cannot end it
        if (/^# -+ >8 -+$/.test(lines[i]) && (lines[i + 1] || "").startsWith("#")) break;
        (lines[i].startsWith("#") ? comments : kept).push(lines[i]);
    }
    const errors = [];
    if (!authorIdent.startsWith(`${MAINTAINER} `) || !committerIdent.startsWith(`${MAINTAINER} `)) {
        errors.push(`author and committer must both be ${MAINTAINER} (user.name / user.email of the repository)`);
    }
    const message = `${kept.join("\n").trim()}\n`;
    errors.push(...checkMessage(message, { exactlyOne: true, personal }).errors);
    for (const f of scan(comments.join("\n"), {}, { personal })) errors.push(`comment line [${f.rule.id}] ${redact(f)}`);
    if (hasAiTrailer(comments)) errors.push("comment line: AI attribution trailers are not allowed");
    return errors;
}

export function selfTest() {
    const cases = [];
    const me = `${MAINTAINER} 1760000000 +0800`;
    const ids = { authorIdent: me, committerIdent: me, personal: [FAKE_NEEDLE] };
    const t = (label, bad, raw, extra = {}) => {
        const errors = checkCommitMsg(raw, { ...ids, ...extra });
        cases.push({ label, bad, passed: bad ? errors.length > 0 : errors.length === 0 });
    };
    const good = `ci(hooks): add hooks\n\nExplanation.\n\n${SIGNOFF}\n`;
    t("a good message", false, `${good}# Please enter the commit message\n`);
    const scissors = "# ------------------------ >8 ------------------------";
    t("below git's scissors line is no message", false, `${good}${scissors}\n# Do not modify or remove the line above.\n+${j("R", "H-12")}\n`);
    t("a scissors line given with -m does not cut", true, `${good}${scissors}\n${j("R", "H-12")}\n`);
    t("no sign-off", true, "ci(hooks): add hooks\n");
    t("two sign-offs", true, `${good}${SIGNOFF}\n`);
    t("wrong sign-off identity", true, "ci(hooks): add hooks\n\nSigned-off-by: Someone <s@example.com>\n");
    t("wrong author identity", true, good, { authorIdent: "Someone <s@example.com> 1760000000 +0800" });
    t("wrong committer identity", true, good, { committerIdent: "Someone <s@example.com> 1760000000 +0800" });
    t("card number", true, `ci(hooks): ${j("R", "N01")} wrap-up\n\n${SIGNOFF}\n`);
    t("card number in a comment line", true, `${good}# On branch ${j("feat/r", "h-01")}\n`);
    t("personal needle", true, `ci(hooks): add hooks\n\n${FAKE_NEEDLE}\n\n${SIGNOFF}\n`);
    t("AI attribution trailer in a comment line (kept by -m)", true, `${good}# ${j("Co-authored", "-by: Someone <s@example.com>")}\n`);
    t("AI attribution trailer", true, `ci(hooks): add hooks\n\n${j("Co-Authored", "-By: Cla", "ude <x@example.com>")}\n${SIGNOFF}\n`);

    // End to end: commits in a temp repository through the real sh shell and this file
    const repo = tempRepo();
    const nf = `${repo.dir}-needles.txt`;
    fs.writeFileSync(nf, `${FAKE_NEEDLE}\n`);
    const env = { ...repo.env, HARNESS_NODE: process.execPath, HARNESS_PRIVACY_LOCAL: nf };
    try {
        repo.git(["config", "core.hooksPath", HOOKS]);
        const c = (label, bad, flags, gitOpts = [], more = {}) => {
            const args = [...gitOpts, "commit", "-q", "--allow-empty", ...flags];
            const ok = repo.git(args, { env: { ...env, ...more }, allowFail: true });
            cases.push({ label: `end to end: ${label}`, bad, passed: bad ? ok === null : ok !== null });
        };
        c("a good commit", false, ["-s", "-m", "ci(test): good commit"]);
        c("no sign-off", true, ["-m", "ci(test): unsigned"]);
        c("card number", true, ["-s", "-m", `ci(test): ${j("R", "H-01")}`]);
        c("personal needle", true, ["-s", "-m", `ci(test): ${FAKE_NEEDLE}`]);
        c("author is not the maintainer", true, ["-s", "-m", "ci(test): someone else"], ["-c", "user.email=other@example.com"]);
        const ci = { HARNESS_PRIVACY_LOCAL: "", CI: "true", GITHUB_ACTIONS: "true" };
        c("no personal needles: CI=true does not relax it", true, ["-s", "-m", "ci(test): no needles"], [], ci);
    } finally {
        repo.cleanup();
        fs.rmSync(nf, { force: true });
    }
    return caseResult(cases);
}

function main(argv) {
    if (argv[0] === "--self-test") return reportSelfTest("commit-msg", selfTest());
    const cwd = process.cwd();
    let errors;
    try {
        assertNodeVersion();
        if (!argv[0]) throw new Error("usage: commit-msg.mjs <message file>");
        const ident = (k) => git(["var", k], { cwd }).trim();
        errors = checkCommitMsg(fs.readFileSync(argv[0], "utf8"), {
            authorIdent: ident("GIT_AUTHOR_IDENT"),
            committerIdent: ident("GIT_COMMITTER_IDENT"),
            personal: loadPersonalNeedles({ cwd, mode: "local" }).needles,
        });
    } catch (e) {
        errors = [e.message];
    }
    if (!errors.length) return 0;
    console.error("commit-msg rejected the commit:");
    for (const e of errors) console.error(`  ${e}`);
    return 1;
}

if (isMain(import.meta.url)) process.exitCode = main(process.argv.slice(2));
