#requires -Version 5.1
# Dot-source for code inspection/offline tests. No inventory or live phase runs.
# Integration.ps1 intentionally blocks live use until a reviewed integration exists.
foreach ($file in @('Common.ps1','Nvidia.ps1','Guest.ps1','Host-Adapter.ps1','Integration.ps1')) {
    . (Join-Path $PSScriptRoot $file)
}
