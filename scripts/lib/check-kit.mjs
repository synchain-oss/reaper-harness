// SPDX-License-Identifier: MIT
//
// Small helpers shared by the check scripts and hooks: repository root, git calls, tracked files,
// local settings, the Node version assertion, temporary repositories for self-tests and the CLI
// wrapper. No dependencies; the Node version is pinned in .node-version.
// Exit codes of every script: 0 pass, 1 findings or failed self-test, 64 usage error.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { cleanupTempDir, makeTempDir } from "./safe-rm.mjs";

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

/** Fragment join. Rules and fixtures are assembled with it so no complete forbidden form appears in source. */
export const j = (...parts) => parts.join("");

/** A wrong command line: reported with exit code 64, not 1. */
export class UsageError extends Error {}

/**
 * Whether the module was started directly with `node <file>` (not imported). Both sides are resolved
 * to real paths: through a symlink or junction argv holds the link while import.meta.url is resolved.
 */
export function isMain(url) {
    try {
        return !!process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(url));
    } catch {
        return false;
    }
}

/** Runs main(argv) when the module is the entry point; UsageError exits 64, any other error exits 1. */
export function runCli(name, url, main) {
    if (!isMain(url)) return;
    try {
        process.exitCode = main(process.argv.slice(2));
    } catch (e) {
        console.error(`${name}: ${e.message}`);
        process.exitCode = e instanceof UsageError ? 64 : 1;
    }
}

/** Prints a self-test result in the common shape and returns the exit code. */
export function reportSelfTest(name, r) {
    for (const l of r.lines) console.error(l);
    console.log(`${name} --self-test: ${r.ok ? "passed" : "FAILED"} (bad cases ${r.bad}, good cases ${r.good})`);
    return r.ok ? 0 : 1;
}

/** Runs git and returns stdout (a Buffer when raw). Throws on failure; returns null with allowFail. */
export function git(args, { cwd = ROOT, input, env, allowFail = false, raw = false } = {}) {
    const r = spawnSync("git", ["-c", "core.quotepath=false", ...args], {
        cwd,
        input,
        env,
        encoding: raw ? "buffer" : "utf8",
        maxBuffer: 256 * 1024 * 1024,
    });
    if (r.status === 0) return r.stdout;
    if (allowFail) return null;
    throw new Error(`git ${args[0]} failed (exit ${r.status}): ${String(r.stderr || "").trim()}`);
}

export const trackedFiles = (root = ROOT) => git(["ls-files", "-z"], { cwd: root }).split("\0").filter(Boolean);

/**
 * Decodes by BOM: UTF-8 (BOM dropped), UTF-16LE, UTF-16BE. Without a BOM a NUL within the first 8000
 * bytes means binary (the same test git uses) and null is returned. Windows PowerShell 5.1 writes
 * UTF-16LE with `>` and Out-File by default.
 */
export function decodeText(buf) {
    if (buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) return buf.subarray(3).toString("utf8");
    if (buf[0] === 0xff && buf[1] === 0xfe) return buf.subarray(2).toString("utf16le");
    if (buf[0] === 0xfe && buf[1] === 0xff) {
        const le = Buffer.from(buf.subarray(2, buf.length - (buf.length % 2)));
        return le.swap16().toString("utf16le");
    }
    return buf.subarray(0, 8000).includes(0) ? null : buf.toString("utf8");
}

/** Reads a text file decoded by BOM; null for binary or unreadable files. */
export function readText(abs) {
    try {
        return decodeText(fs.readFileSync(abs));
    } catch {
        return null;
    }
}

/**
 * A local setting: the environment variable first, then git config. The main clone's local config
 * applies to all its worktrees, so hooks do not depend on the caller's shell; no local path is ever
 * written into the repository.
 */
export function localSetting(envName, gitKey, { env = process.env, cwd = process.cwd() } = {}) {
    if (env[envName]) return env[envName];
    return (git(["config", "--get", gitKey], { cwd, env, allowFail: true }) || "").trim();
}

export const inCI = (env = process.env) => env.GITHUB_ACTIONS === "true" || env.CI === "true";

/** The major version must equal .node-version: the machine's global Node may be another major version. */
export function assertNodeVersion(root = ROOT) {
    const want = fs.readFileSync(path.join(root, ".node-version"), "utf8").trim().split(".")[0];
    const have = process.versions.node.split(".")[0];
    if (want !== have) {
        throw new Error(
            `Node ${want} is required (see .node-version), this is ${process.versions.node}; ` +
                "hooks take the pinned Node from HARNESS_NODE or git config harness.node",
        );
    }
}

/** An environment unaffected by the caller's git setup: GIT_* removed, no system or global git config. */
export function isolatedEnv(extra = {}) {
    const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("GIT_")));
    return { ...env, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", ...extra };
}

/** A temporary repository for self-tests, with the maintainer identity; call cleanup() when done. */
export function tempRepo({ bare = false } = {}) {
    const dir = makeTempDir("harness-selftest-");
    const env = isolatedEnv();
    const run = (args, opts = {}) => git(args, { cwd: dir, env, ...opts });
    run(bare ? ["init", "-q", "--bare"] : ["init", "-q", "-b", "main"]);
    if (!bare) {
        run(["config", "user.name", "DLsnows"]);
        run(["config", "user.email", "noreply@synchain.ca"]);
    }
    return {
        dir,
        env,
        git: run,
        write(rel, data) {
            const abs = path.join(dir, rel);
            fs.mkdirSync(path.dirname(abs), { recursive: true });
            fs.writeFileSync(abs, data);
        },
        cleanup: () => cleanupTempDir(dir),
    };
}

/** Folds self-test cases into the common result shape; there must be bad cases and good cases. */
export function caseResult(cases) {
    const failures = cases.filter((c) => !c.passed).map((c) => c.label);
    const bad = cases.filter((c) => c.bad).length;
    const good = cases.length - bad;
    const lines = failures.map((l) => `self-test case failed: ${l}`);
    if (!bad || !good) lines.push("self-test needs both bad and good cases");
    return { ok: failures.length === 0 && bad > 0 && good > 0, bad, good, lines };
}

/** Merges several self-test results into one. */
export const mergeResults = (...rs) => ({
    ok: rs.every((r) => r.ok),
    bad: rs.reduce((n, r) => n + r.bad, 0),
    good: rs.reduce((n, r) => n + r.good, 0),
    lines: rs.flatMap((r) => r.lines),
});
