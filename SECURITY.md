# Security Policy

## Supported versions

Nothing has been released yet. Once releases exist, only the latest minor line (`x.Y.*`) receives
security fixes; please upgrade to it and reproduce there first.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub Private Vulnerability Reporting: repository page →
Security → Report a vulnerability.

If that channel is unavailable, email **contact@synchain.ca** with `[security]` in the subject.

Reports in English or Chinese are both welcome. Please include the harness commit or version, your
Windows and REAPER versions, the configuration file (or a minimal one that reproduces the problem)
and the steps to reproduce. **Do not include credentials**, and do not send your REAPER
configuration directory: it lists the plugins installed on your machine.

## Response targets

- First response: within 3 working days
- Fix or mitigation: 14 days for high severity, 30 days for medium severity
- Disclosure: a public advisory (GHSA) is published 7 days after the fix ships

## Scope

- In scope: the harness writing, deleting or modifying anything outside the private configuration
  directory, the work directory and the result directory it was given (above all REAPER's default
  resource directory); the harness ending or interacting with a process or a window it did not
  start; personal data (user names, machine names, local paths, the list of installed plugins)
  leaking into result files; a configuration file or a plugin under test making the harness run
  arbitrary commands; supply-chain issues in the scripts and the CI workflows.
- Out of scope: bugs in REAPER itself or in the plugins under test (report those to their
  vendors); scenarios that already require arbitrary code execution on your machine.
