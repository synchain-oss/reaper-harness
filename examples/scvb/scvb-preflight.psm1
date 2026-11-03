# SPDX-License-Identifier: MIT
#
# Preflight for the SCVB example (see docs/EXTENDING.md). SCVB instances talk to each other through named shared
# memory, one set of sections per group (1..8), named only by the group number and created in the logon session's
# Local\ namespace. Another host on this desktop with SCVB loaded would therefore share a group with the instances the
# harness starts. Before anything is started, this opens each group's registry section read only and closes it again at
# once (MemoryMappedFile.OpenExisting with Read rights is OpenFileMapping with FILE_MAP_READ; no view is mapped and
# nothing is created). Any section that exists, or that cannot be probed, is a reason: the whole suite is SKIPPED with
# zero launches.
#
# This runs once, before the suite. An SCVB host started while the suite runs is not seen (there is no hook after the
# run); keep SCVB closed for the duration, or use a skip marker.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Register-HarnessExtension {
    @{
        Name      = 'scvb-preflight'
        Preflight = {
            param($Config)
            foreach ($group in 1..8) {
                $name = "Local\SynchainSCVB.v1.g$group.registry"
                try {
                    $section = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($name, [IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
                    $section.Dispose()
                    "an SCVB instance is live in this session (group $group): close the host that has SCVB loaded"
                } catch [IO.FileNotFoundException] {
                    # no such section: no SCVB instance of this group in this session
                } catch {
                    "the SCVB section of group $group could not be probed ($($_.Exception.GetBaseException().GetType().Name)), so it may be live"
                }
            }
        }
    }
}

Export-ModuleMember -Function Register-HarnessExtension
