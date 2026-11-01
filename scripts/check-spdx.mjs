// SPDX-License-Identifier: MIT
//
// SPDX header gate: every tracked source file that can carry a comment has the MIT SPDX licence
// identifier line within its first five lines, and no other SPDX licence identifier there.
//   node scripts/check-spdx.mjs [--self-test]
// Exit codes: 0 pass, 1 files without the header (or no candidate files at all), 64 usage error.

import path from "node:path";
import { ROOT, UsageError, assertNodeVersion, caseResult, j, readText, reportSelfTest, runCli, trackedFiles } from "./lib/check-kit.mjs";

/** Files that must carry the header: scripts, modules, Lua, C#, workflow and template YAML, and the hook shells. */
export const SOURCE = /\.(?:mjs|cjs|js|ps1|psm1|psd1|lua|cs|sh|py|ya?ml)$|^scripts\/hooks\/[^/.]+$/;
// Assembled from fragments: a complete identifier line in the source would read as this file's own declaration
const KEY = j("SPDX-License-", "Identifier:");
const HEADER = `${KEY} MIT`;

/** files: repository-relative paths; read(rel) returns the text or null. Null when there is no candidate at all (a broken list). */
export function missingHeaders(files, read) {
    const cand = files.filter((f) => SOURCE.test(f));
    if (!cand.length) return null;
    return cand.filter((f) => {
        const text = read(f);
        if (text === null) return false; // binary or unreadable: not a source file after all
        const head = text.split(/\r?\n/, 5);
        const ids = head.filter((l) => l.includes(KEY));
        return !ids.length || ids.some((l) => !new RegExp(`${KEY}\\s*MIT\\s*(?:-->|\\*/)?\\s*$`).test(l));
    });
}

export function checkTree(root = ROOT) {
    return missingHeaders(trackedFiles(root), (rel) => readText(path.join(root, rel)));
}

export function selfTest() {
    const files = {
        "scripts/a.mjs": `// ${HEADER}\nexport {};\n`,
        "src/Guard.psm1": `#Requires -Version 7\n# ${HEADER}\n`,
        "lua/driver.lua": `-- ${HEADER}\n`,
        ".github/workflows/ci.yml": `# ${HEADER}\nname: CI\n`,
        "scripts/hooks/pre-push": `#!/bin/sh\n# ${HEADER}\n`,
        "README.md": "# x\n",
        "tests/fixtures/a.json": "{}\n",
    };
    const read = (f) => files[f] ?? null;
    const run = (extra) => missingHeaders(Object.keys({ ...files, ...extra }), (f) => extra[f] ?? read(f));
    const cases = [
        ["headers present; Markdown and JSON are not sources", false, run({})],
        ["a module without the header", true, run({ "src/Wav.psm1": "Set-StrictMode -Version Latest\n" })],
        ["a C# source without the header", true, run({ "src/Wav.cs": "class W {}\n" })],
        ["a workflow without the header", true, run({ ".github/workflows/x.yml": "name: x\n" })],
        ["the header after line 5", true, run({ "scripts/c.mjs": `${"\n".repeat(5)}// ${HEADER}\n` })],
        ["a hook shell without the header", true, run({ "scripts/hooks/commit-msg": "#!/bin/sh\n" })],
        ["another licence", true, run({ "scripts/d.js": `// ${KEY} GPL-3.0-or-later\n` })],
        ["MIT plus a second identifier", true, run({ "scripts/e.mjs": `// ${HEADER}\n// ${KEY} Apache-2.0\n` })],
        ["MIT OR another licence", true, run({ "scripts/f.mjs": `// ${HEADER} OR Apache-2.0\n` })],
        ["no candidate files at all", true, missingHeaders(["README.md"], read)],
    ].map(([label, bad, missing]) => ({ label, bad, passed: bad ? missing === null || missing.length > 0 : missing?.length === 0 }));
    return caseResult(cases);
}

function main(argv) {
    assertNodeVersion();
    if (argv.includes("--self-test")) return reportSelfTest("check-spdx", selfTest());
    if (argv.length) throw new UsageError(`unknown arguments: ${argv.join(" ")}`);
    const missing = checkTree();
    if (missing === null) {
        console.error("check-spdx FAILED: no source file that needs an SPDX header was found");
        return 1;
    }
    if (!missing.length) {
        console.log("check-spdx passed");
        return 0;
    }
    console.error(`check-spdx FAILED: ${missing.length} file(s) lack "${HEADER}" in their first five lines`);
    for (const f of missing) console.error(`  ${f}`);
    return 1;
}

runCli("check-spdx", import.meta.url, main);
