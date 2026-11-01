// SPDX-License-Identifier: MIT
//
// The only machine-readable list of infrastructure paths. A pull request that changes any of them is not
// merged by an agent on its own: after a clean review it needs a recorded maintainer approval for its
// exact head. The merge script reads this list; CLAUDE.md only names the categories and points here.
// The list covers the merge criteria themselves: CI configuration, the scripts CI runs, the review bot,
// the check scripts and their shared libraries, the hooks, tool pins, normalisation settings, the
// configuration files review bots read from the default branch, and this file (it is under scripts/lib/**).
// Glob syntax: ** crosses directories, * does not cross /, paths are relative to the repository root.
// Matching ignores case: the Windows file system does too, so Scripts/hooks/x checks out as scripts/hooks/x.

export const INFRA_PATHS = [
    ".github/**",
    "scripts/maintainer/**",
    "scripts/hooks/**",
    "scripts/lib/**",
    "scripts/check-*.mjs",
    "scripts/review-bot.mjs",
    // Tool pins (Node, gitleaks, actionlint) and the settings that decide how files are normalised and scanned
    ".*-version",
    ".gitattributes",
    ".gitleaks.toml",
    // pr-agent and other bots read these from the default branch and reconfigure themselves
    ".pr_agent.toml",
    "**/.pr_agent.toml",
    "AGENTS.md",
    "**/AGENTS.md",
    "CLAUDE.md",
    "**/CLAUDE.md",
    ".claude/**",
];

/** Files review bots read from the default branch to reconfigure themselves; committing one bypasses the approval. */
export const BOT_CONFIG_PATHS = [".pr_agent.toml", "**/.pr_agent.toml", "AGENTS.md", "**/AGENTS.md", ".claude/**", "**/.mcp.json"];
/** Registered exemptions (repository-relative paths). An empty list means none may be committed. */
export const ALLOWED_BOT_CONFIG = [];

const globRe = (g, flags) =>
    new RegExp(
        `^${g
            .replace(/[.+^${}()|[\]\\]/g, "\\$&")
            .replace(/\*\*\//g, "\u0001")
            .replace(/\*\*/g, "\0")
            .replace(/\*/g, "[^/]*")
            .replace(/\u0001/g, "(?:.*/)?")
            .replace(/\0/g, ".*")}$`,
        flags,
    );

/** A predicate from a glob list: does a repository-relative path (forward slashes) match one of them. */
export function infraMatcher(globs, { ignoreCase = true } = {}) {
    const res = globs.map((g) => globRe(g, ignoreCase ? "i" : ""));
    return (p) => res.some((re) => re.test(p));
}

export const isInfraPath = infraMatcher(INFRA_PATHS);

/** files are repository-relative paths; returns the bot configuration files that are not registered exemptions. */
export function botConfigErrors(files, allowed = ALLOWED_BOT_CONFIG) {
    const hit = infraMatcher(BOT_CONFIG_PATHS);
    const ok = (p) => allowed.some((a) => a.toLowerCase() === p.toLowerCase());
    return files
        .filter((p) => hit(p) && !ok(p))
        .map((p) => `${p}: review bots read it from the default branch to reconfigure themselves; register it in ALLOWED_BOT_CONFIG first`);
}

/** Pure cases for the self-test aggregator: [{ label, bad, passed }]; bad = the path must count as infrastructure. */
export function selfTestCases() {
    const infra = [
        ".github/workflows/ci.yml",
        ".github/CODEOWNERS",
        "scripts/maintainer/pr-merge.ps1",
        "scripts/hooks/pre-push",
        "Scripts/Hooks/pre-push.mjs",
        "scripts/lib/infra-paths.mjs",
        "scripts/check-privacy.mjs",
        "scripts/review-bot.mjs",
        ".node-version",
        ".gitleaks-version",
        ".gitattributes",
        "CLAUDE.md",
        "docs/CLAUDE.md",
        "AGENTS.md",
        "examples/x/AGENTS.md",
        ".pr_agent.toml",
        ".claude/settings.json",
    ];
    // scripts/check-x/y.mjs: * in scripts/check-*.mjs does not cross a directory
    const plain = ["run.ps1", "src/Guard.psm1", "lua/driver.lua", "docs/USAGE.md", "scripts/checker.mjs", "README.md", "tests/check-x.mjs", "scripts/check-x/y.mjs"];
    const cases = [
        ...infra.map((p) => ({ label: `infra-paths: ${p} is infrastructure`, bad: true, passed: isInfraPath(p) })),
        ...plain.map((p) => ({ label: `infra-paths: ${p} is not infrastructure`, bad: false, passed: !isInfraPath(p) })),
    ];
    const bot = (label, bad, files, allowed) =>
        cases.push({ label: `bot config: ${label}`, bad, passed: (botConfigErrors(files, allowed).length > 0) === bad });
    bot("a committed .pr_agent.toml", true, ["docs/.pr_agent.toml"]);
    bot("a committed .mcp.json", true, ["x/.mcp.json"]);
    bot("a .mcp.json at the root (**/ matches the root too)", true, [".mcp.json"]);
    bot("a registered exemption", false, ["AGENTS.md"], ["agents.md"]);
    bot("ordinary files", false, ["README.md", "scripts/check-spdx.mjs"]);
    return cases;
}
