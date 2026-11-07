# SPDX-License-Identifier: MIT
#
# A minimal extension for the self-test: one scenario kind that never starts REAPER, and a preflight check. See
# docs/EXTENDING.md for the contract.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Register-HarnessExtension {
    @{
        Name      = 'fixture'
        Kinds     = @{
            'fixture-count' = @{
                # Item: the scenario's fields other than id, kind, expect and expectDetail. Returns problem strings.
                Validate = {
                    param($Item)
                    foreach ($k in $Item.get_Keys()) { if ($k -cne 'count') { "unknown key '$k'" } }
                    if ($Item['count'] -isnot [long] -or $Item['count'] -lt 0 -or $Item['count'] -gt 10) { "'count' must be an integer 0..10" }
                }
                # Returns an outcome made with Ctx.Api.Outcome (PASS / FAIL / INCOMPLETE).
                Run      = {
                    param($Ctx, $Scenario)
                    $n = [int]$Scenario.raw['count']
                    if ($n -lt 1) { return & $Ctx.Api.Outcome FAIL "counted $n, expected at least 1" }
                    # The facts carry a local path on purpose: the suite masks whatever an extension puts there
                    & $Ctx.Api.Outcome PASS "counted $n" ([ordered]@{ count = $n; workDir = $Ctx.Work })
                }
            }
        }
        Preflight = {
            param($Config)
            if ($env:REAPER_HARNESS_FIXTURE_SKIP) { 'REAPER_HARNESS_FIXTURE_SKIP is set' }
        }
    }
}

Export-ModuleMember -Function Register-HarnessExtension
