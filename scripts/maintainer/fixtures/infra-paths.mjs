// SPDX-License-Identifier: MIT
//
// Stand-in for scripts/lib/infra-paths.mjs, used only by the maintainer self-tests (Set-HarnessInfraModule): the list and
// the glob rule are copies of the real module, so the self-tests judge a path the way a real run does. A real run reads
// scripts/lib/infra-paths.mjs of the checkout it runs in and fails when that file is missing.
// Glob syntax: ** crosses directories, * does not cross /, "**/" also matches no directory at all; matching ignores case.

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
