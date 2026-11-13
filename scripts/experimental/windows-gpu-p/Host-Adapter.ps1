# Experimental reference components; see README.md before use.
# Functions only. Live integration hooks intentionally fail closed.
Set-StrictMode -Version Latest
function Assert-CgNoAdapters($Snapshot) { if(@($Snapshot.VM.GpuAdapters).Count -ne 0){throw 'Unexpected GPU adapter; this phase requires CPU-only current Cage.'} }
function Assert-CgOriginalMmio($Plan,$Snapshot) {
    foreach($name in @('GuestControlledCacheTypes','LowMemoryMappedIoSpace','HighMemoryMappedIoSpace')){if($Snapshot.VM.$name -ne $Plan.VM.$name){throw 'MMIO/cache differs from captured baseline.'}}
}
function Invoke-CgAttach($Plan) {
    $now=Assert-CgPlanCurrent $Plan -State Off;Assert-CgNoAdapters $now;Assert-CgOriginalMmio $Plan $now;Assert-CgQuiet $Plan
    $j=Read-CgHostJournal $Plan
    if($j.Stage -ne 'GuestFilesVerified'){throw 'A verified guest transaction is required before attach.'}
    if(-not $j.PSObject.Properties['Backup'] -or $null -eq $j.Backup -or -not $j.PSObject.Properties['BackupPath'] -or [string]::IsNullOrWhiteSpace($j.BackupPath)){throw 'A recorded cold backup is required before attach.'}
    $backupNow=Get-CgFileState $j.BackupPath
    if($null -eq $backupNow){throw 'The recorded cold backup file is missing.'}
    Assert-CgSameState $j.Backup $backupNow
    Assert-CgHostManifestCurrent $Plan.Manifest
    $vm=Get-VM -Id ([guid]$Plan.VM.Id)
    $j.Stage='AttachIntent';$j.MmioStatus='Intent';$j.MmioBefore=[pscustomobject]@{GuestControlledCacheTypes=$now.VM.GuestControlledCacheTypes;LowMemoryMappedIoSpace=$now.VM.LowMemoryMappedIoSpace;HighMemoryMappedIoSpace=$now.VM.HighMemoryMappedIoSpace};$j.MmioAfter=$Plan.RequestedVmSettings;Save-CgHostJournal $Plan $j
    Set-VM -VM $vm -GuestControlledCacheTypes $Plan.RequestedVmSettings.GuestControlledCacheTypes -LowMemoryMappedIoSpace $Plan.RequestedVmSettings.LowMemoryMappedIoSpace -HighMemoryMappedIoSpace $Plan.RequestedVmSettings.HighMemoryMappedIoSpace
    $now=Assert-CgPlanCurrent $Plan -State Off
    foreach($name in @('GuestControlledCacheTypes','LowMemoryMappedIoSpace','HighMemoryMappedIoSpace')){if($now.VM.$name -ne $Plan.RequestedVmSettings.$name){throw 'MMIO/cache readback mismatch.'}}
    $j.MmioStatus='Written';Save-CgHostJournal $Plan $j
    # Exact instance only. No AUTO selection and no global GPU partition quota changes.
    $a=Add-VMGpuPartitionAdapter -VM $vm -InstancePath $Plan.Manifest.Active.GpuInstancePath -Passthru
    $j.Adapter=[pscustomobject]@{Id=$a.Id.ToString();InstancePath=$a.InstancePath};Save-CgHostJournal $Plan $j
    $now=Assert-CgPlanCurrent $Plan -State Off
    if(@($now.VM.GpuAdapters).Count -ne 1 -or $now.VM.GpuAdapters[0].Id.ToString() -cne $j.Adapter.Id -or $now.VM.GpuAdapters[0].InstancePath -cne $Plan.Manifest.Active.GpuInstancePath){throw 'Created GPU adapter identity/path readback mismatch.'}
    $j.Stage='Attached';Save-CgHostJournal $Plan $j
    [pscustomobject]@{Status='AttachedOff';Adapter=$j.Adapter;Next='Normal Cage start, D3D hardware probe, and separate normal-user Edge GUI validation.'}
}
function Invoke-CgRollbackAdapter($Plan) {
    $now=Assert-CgPlanCurrent $Plan -State Off;Assert-CgQuiet $Plan;$j=Read-CgHostJournal $Plan
    if($j.Stage -eq 'AdapterRolledBack'){return [pscustomobject]@{Status='AlreadyAdapterRolledBack';NoWrites=$true}}
    if($j.MmioStatus -eq 'Intent' -or ($j.Stage -eq 'AttachIntent' -and $null -eq $j.Adapter)){throw 'Interrupted unobserved attachment/settings action; no guessed adapter removal or setting restore.'}
    if($null -ne $j.Adapter){
        if(@($now.VM.GpuAdapters).Count -ne 1 -or $now.VM.GpuAdapters[0].Id.ToString() -cne $j.Adapter.Id -or $now.VM.GpuAdapters[0].InstancePath -cne $j.Adapter.InstancePath){throw 'Created adapter identity drift; preserve all adapters.'}
    }elseif(@($now.VM.GpuAdapters).Count){throw 'Unrecorded adapter; preserve it.'}
    if($j.MmioStatus -eq 'Written'){foreach($name in @('GuestControlledCacheTypes','LowMemoryMappedIoSpace','HighMemoryMappedIoSpace')){if($now.VM.$name -ne $j.MmioAfter.$name){throw 'MMIO/cache drift; do not overwrite later changes.'}}}
    $j.Stage='AdapterRollbackIntent';Save-CgHostJournal $Plan $j
    $vm=Get-VM -Id ([guid]$Plan.VM.Id)
    if($null -ne $j.Adapter){$adapter=@(Get-VMGpuPartitionAdapter -VM $vm|Where-Object {$_.Id.ToString() -ceq $j.Adapter.Id -and $_.InstancePath -ceq $j.Adapter.InstancePath});if($adapter.Count -ne 1){throw 'Recorded adapter no longer uniquely matches.'};Remove-VMGpuPartitionAdapter -VMGpuPartitionAdapter $adapter[0] -Confirm:$false}
    if($j.MmioStatus -eq 'Written'){
        Set-VM -VM $vm -GuestControlledCacheTypes $j.MmioBefore.GuestControlledCacheTypes -LowMemoryMappedIoSpace $j.MmioBefore.LowMemoryMappedIoSpace -HighMemoryMappedIoSpace $j.MmioBefore.HighMemoryMappedIoSpace
        $now=Assert-CgPlanCurrent $Plan -State Off;Assert-CgOriginalMmio $Plan $now
        $j.MmioStatus='Restored'
    }
    $now=Assert-CgPlanCurrent $Plan -State Off;Assert-CgNoAdapters $now
    $j.Stage='AdapterRolledBack';Save-CgHostJournal $Plan $j
    [pscustomobject]@{Status='AdapterRolledBackOff';Next='Normal CPU-only Cage start, then RollbackFiles with human PSDirect session.'}
}
