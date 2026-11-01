// SPDX-License-Identifier: MIT
//
// Runs every self-test of the check scripts, the review bot and the hooks under node:test, so CI and a
// local run share one command:
//   node --test "scripts/**/*.test.mjs"
// Each script also runs its own self-test with --self-test; this file adds the pure cases of the shared
// libraries and the mutation check of the privacy rules (every criterion disabled in turn must turn a
// fixture red).

import assert from "node:assert/strict";
import test from "node:test";
import { caseResult } from "./check-kit.mjs";
import { mutationCheck } from "./privacy-needles.mjs";
import { selfTestCases as infraCases } from "./infra-paths.mjs";
import { selfTestCases as safeRmCases } from "./safe-rm.mjs";
import { selfTest as privacy } from "../check-privacy.mjs";
import { selfTest as commits } from "../check-commits.mjs";
import { selfTest as spdx } from "../check-spdx.mjs";
import { selfTest as workflows } from "../check-workflows.mjs";
import { selfTest as reviewBot } from "../review-bot.mjs";
import { selfTest as commitMsg } from "../hooks/commit-msg.mjs";
import { selfTest as prePush } from "../hooks/pre-push.mjs";

const SUITES = {
    "check-privacy": privacy,
    "check-commits": commits,
    "check-spdx": spdx,
    "check-workflows": workflows,
    "review-bot": reviewBot,
    "commit-msg hook": commitMsg,
    "pre-push hook": prePush,
    "lib: infra-paths and safe-rm": () => caseResult([...infraCases(), ...safeRmCases()]),
};

for (const [name, run] of Object.entries(SUITES)) {
    test(name, () => {
        const r = run();
        assert.ok(r.ok, `${name}:\n${r.lines.join("\n")}`);
        for (const l of r.lines) console.log(`# ${l}`);
    });
}

test("privacy rules: every mutant is caught", () => {
    const r = mutationCheck();
    assert.deepEqual(r.survived, [], `mutants not caught by any fixture: ${r.survived.join(", ")}`);
});
