// SPDX-License-Identifier: MIT
//
// The only recursive deletes in the scripts go through here:
//   makeTempDir(prefix)            creates a randomly named directory one level below the system temp
//                                  directory, records its real path and returns it
//   removeTempDir(dir) / cleanupTempDir(dir)
//                                  deletes only a directory this process created with makeTempDir,
//                                  re-checked by real path right before deleting
//   removeFixedDir(dir, { rel })   deletes only a fixed output directory of the repository: rel must be
//                                  listed in FIXED_DIRS and the real path of dir must be exactly <repo root>/rel
//   unlinkFixedLink(dir, { rel })  when that fixed location is a link, removes the link itself only
// The verdicts are pure functions so the self-test feeds them fake data and never deletes a real path.
// Links: paths are resolved level by level before comparing; fs.rmSync removes links inside a
// directory without following them.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

/** Repository root, derived from this module's own location (scripts/lib/), never from the caller. */
export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
/** Fixed output directories (relative to the repository root, as segment arrays) that may be deleted. */
export const FIXED_DIRS = [[".harness-review"]];

const WIN = process.platform === "win32";
const norm = (p) => (WIN ? p.toLowerCase() : p);
const same = (a, b) => norm(a) === norm(b);
const isUnder = (child, dir) => norm(child).startsWith(norm(dir.endsWith(path.sep) ? dir : dir + path.sep));

/** Real path: realpath of the deepest existing level, the missing rest appended literally. */
export function realPathLoose(p) {
    let cur = path.resolve(p);
    const rest = [];
    for (;;) {
        try {
            return path.join(fs.realpathSync.native(cur), ...rest.reverse());
        } catch {
            const up = path.dirname(cur);
            if (up === cur) return path.join(cur, ...rest.reverse());
            rest.push(path.basename(cur));
            cur = up;
        }
    }
}

/** A drive root, the home directory or one of its ancestors: returns the reason, otherwise null. */
export function dangerousReason(real, home = os.homedir()) {
    const r = real.replace(/[\\/]+$/, "") || real;
    const root = path.parse(real).root;
    if (same(r, root.replace(/[\\/]+$/, "") || root)) return "it is a drive root";
    if (home) {
        const h = realPathLoose(home).replace(/[\\/]+$/, "");
        if (same(r, h)) return "it is the home directory";
        if (isUnder(h, r)) return "it is an ancestor of the home directory";
    }
    return null;
}

/** Directories made by this process: normalized real path -> { real, prefix, parent }. */
const made = new Map();

/** Pure verdict for removeTempDir. Returns null (may delete) or the reason. */
export function tempVerdict({ real, entry, tmpReal, home }) {
    if (!entry) return "not created by makeTempDir in this process";
    const danger = dangerousReason(real, home);
    if (danger) return danger;
    if (!same(entry.parent, tmpReal) || !same(path.dirname(real), entry.parent)) {
        return "its real path is not one level below the system temp directory";
    }
    if (!path.basename(real).startsWith(entry.prefix)) return `its name does not start with ${entry.prefix}`;
    return null;
}

/** Pure verdict for removeFixedDir. Returns null (may delete) or the reason. */
export function fixedVerdict({ rootReal, targetReal, targetIsLink, rel, home, allowed = FIXED_DIRS }) {
    if (!Array.isArray(rel) || !rel.length || rel.some((s) => !s || s === "." || s === ".." || /[\\/:]/.test(s))) {
        return "the fixed relative path is malformed";
    }
    if (!allowed.some((a) => a.length === rel.length && a.every((x, i) => x === rel[i]))) {
        return `${rel.join("/")} is not listed in FIXED_DIRS`;
    }
    if (targetIsLink) return "the target itself is a link";
    const danger = dangerousReason(targetReal, home);
    if (danger) return danger;
    if (same(targetReal, rootReal)) return "the target is the repository root";
    if (!same(targetReal, path.join(rootReal, ...rel))) return "the target's real path is not the fixed directory";
    return null;
}

/** Creates a randomly named directory below the system temp directory. prefix looks like harness-xxx-. */
export function makeTempDir(prefix) {
    if (!/^harness-[a-z0-9-]+-$/.test(prefix)) throw new Error(`bad temp directory prefix: ${prefix}`);
    const base = os.tmpdir();
    for (let i = 0; i < 100; i++) {
        const dir = path.join(base, prefix + crypto.randomBytes(16).toString("hex"));
        try {
            fs.mkdirSync(dir, { mode: 0o700 });
        } catch (e) {
            if (e.code === "EEXIST") continue;
            throw e;
        }
        const real = realPathLoose(dir);
        made.set(norm(real), { real, prefix, parent: realPathLoose(base) });
        return dir;
    }
    throw new Error(`could not create a ${prefix} directory below the temp directory`);
}

/** Deletes a temp directory made by this process. Returns null when gone, otherwise the reason. */
export function removeTempDir(dir) {
    if (!dir) return null;
    try {
        fs.lstatSync(dir);
    } catch (e) {
        return e.code === "ENOENT" ? null : `not deleting ${dir}: ${e.message}`;
    }
    const real = realPathLoose(dir);
    const entry = made.get(norm(real));
    const why = tempVerdict({ real, entry, tmpReal: realPathLoose(os.tmpdir()) });
    if (why) return `not deleting ${dir}: ${why}`;
    try {
        fs.rmSync(entry.real, { recursive: true, force: true, maxRetries: 3, retryDelay: 300 });
        made.delete(norm(real));
        return null;
    } catch (e) {
        return `could not delete ${dir}: ${e.message}`;
    }
}

/** For finally blocks: never throws, but a directory that could not be removed is reported on stderr. */
export function cleanupTempDir(dir) {
    const why = removeTempDir(dir);
    if (why) console.error(`temp directory left behind: ${why}`);
    return why;
}

/** Deletes the fixed output directory <repo root>/rel. Returns null when gone, otherwise the reason. */
export function removeFixedDir(dir, { rel }) {
    let st;
    try {
        st = fs.lstatSync(dir);
    } catch (e) {
        return e.code === "ENOENT" ? null : `not deleting ${dir}: ${e.message}`;
    }
    const target = realPathLoose(dir);
    const why = fixedVerdict({
        rootReal: realPathLoose(REPO_ROOT),
        targetReal: target,
        targetIsLink: st.isSymbolicLink(),
        rel,
    });
    if (why) return `not deleting ${dir}: ${why}`;
    try {
        if (fs.lstatSync(target).isSymbolicLink()) return `not deleting ${dir}: it turned into a link`;
        fs.rmSync(target, { recursive: true, force: true });
        return null;
    } catch (e) {
        return `could not delete ${dir}: ${e.message}`;
    }
}

/** When <repo root>/rel is a link, removes the link only. Returns null when nothing is left to do. */
export function unlinkFixedLink(dir, { rel }) {
    let st;
    try {
        st = fs.lstatSync(dir);
    } catch (e) {
        return e.code === "ENOENT" ? null : `not touching ${dir}: ${e.message}`;
    }
    if (!st.isSymbolicLink()) return null;
    if (!FIXED_DIRS.some((a) => a.join("/") === (rel || []).join("/"))) return `not touching ${dir}: not in FIXED_DIRS`;
    if (!same(path.resolve(dir), path.join(REPO_ROOT, ...rel))) return `not touching ${dir}: not <repo root>/rel`;
    try {
        fs.unlinkSync(dir); // a directory junction is removed with unlink on Windows as well
        return null;
    } catch (e) {
        return `could not unlink ${dir}: ${e.message}`;
    }
}

/** Pure-function cases for the self-test aggregator: [{ label, bad, passed }]. */
export function selfTestCases() {
    const root = path.resolve(os.tmpdir(), "harness-fake-root");
    const home = path.resolve(os.tmpdir(), "harness-fake-home");
    const tmp = path.resolve(os.tmpdir());
    const fixed = (extra) =>
        fixedVerdict({ rootReal: root, targetReal: path.join(root, ".harness-review"), rel: [".harness-review"], home, ...extra });
    const temp = (extra) =>
        tempVerdict({
            real: path.join(tmp, "harness-x-1"),
            entry: { prefix: "harness-x-", parent: tmp },
            tmpReal: tmp,
            home,
            ...extra,
        });
    const cases = [
        ["safe-rm: fixed directory at <root>/rel", false, fixed()],
        ["safe-rm: rel not in FIXED_DIRS", true, fixed({ rel: ["src"], targetReal: path.join(root, "src") })],
        ["safe-rm: rel with ..", true, fixed({ rel: [".."] })],
        ["safe-rm: target is a link", true, fixed({ targetIsLink: true })],
        ["safe-rm: target elsewhere", true, fixed({ targetReal: path.join(tmp, "elsewhere") })],
        ["safe-rm: target is the root", true, fixed({ targetReal: root })],
        ["safe-rm: home directory", true, fixed({ targetReal: home })],
        // The cases below put the danger exactly at the allowed location, so no later check can catch it instead
        ["safe-rm: a malformed rel even when listed", true, fixed({ rel: [".."], allowed: [[".."]], targetReal: path.dirname(root), home: "" })],
        ["safe-rm: the fixed directory is the home directory", true, fixed({ home: path.join(root, ".harness-review") })],
        ["safe-rm: the fixed directory is an ancestor of the home directory", true, fixed({ home: path.join(root, ".harness-review", "u") })],
        ["safe-rm: a drive root (no home directory to compare with)", true, dangerousReason(path.parse(tmp).root, "")],
        ["safe-rm: a temp directory that is the home directory", true, temp({ home: path.join(tmp, "harness-x-1") })],
        ["safe-rm: temp directory made here", false, temp()],
        ["safe-rm: temp directory not made here", true, temp({ entry: undefined })],
        ["safe-rm: temp directory moved", true, temp({ real: path.join(root, "harness-x-1") })],
        ["safe-rm: temp directory renamed", true, temp({ real: path.join(tmp, "other-1") })],
    ];
    return cases.map(([label, bad, why]) => ({ label, bad, passed: bad ? why !== null : why === null }));
}
