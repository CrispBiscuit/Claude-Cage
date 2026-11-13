#requires -Version 7.0
# Every Hyper-V command is mocked. This test does not query or mutate any VM.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Import-Reference.ps1')
function Equal($Actual,$Expected){if($Actual -cne $Expected){throw "Expected <$Expected>, got <$Actual>"}}
function Refuses([scriptblock]$Body,[string]$Message){$threw=$false;try{& $Body|Out-Null}catch{if($_.Exception.Message -notlike ('*'+$Message+'*')){throw};$threw=$true};if(-not $threw){throw 'Expected refusal did not happen.'}}
function Clone($Object){$Object|ConvertTo-Json -Depth 40|ConvertFrom-Json}
$script:checks=0
function Check([string]$Name,[scriptblock]$Body){& $Body;$script:checks++;Write-Output "PASS $Name"}
Check 'Unimplemented integration blocks host and guest phases' {
    Refuses {Invoke-CgAttach $null} 'Integration required'
    Refuses {Invoke-CgRollbackAdapter $null} 'Integration required'
    Refuses {Initialize-CgGuestRun $null} 'Integration required'
    Refuses {Get-CgHostDiagnosticRoot} 'Integration required'
    Refuses {Get-CgGuestRunPath $null} 'Integration required'
    Refuses {Assert-CgQuiet $null} 'Integration required'
    Refuses {Read-CgHostJournal $null} 'Integration required'
    Refuses {Save-CgHostJournal $null $null} 'Integration required'
}
$script:path='\\?\PCI#VEN_10DE&DEV_1234&SUBSYS_00000000#SYNTHETIC_INSTANCE#{064092b3-625e-43bf-9eb5-dc845897dd59}\GPUPARAV'
function Reset-Fixture {
    $script:vm=[pscustomobject]@{Id='00000000-0000-0000-0000-000000000001';State='Off';GuestControlledCacheTypes=$false;LowMemoryMappedIoSpace=128MB;HighMemoryMappedIoSpace=512MB;GpuAdapters=@()}
    $script:plan=[pscustomobject]@{VM=(Clone $script:vm);Manifest=[pscustomobject]@{Active=[pscustomobject]@{GpuInstancePath=$script:path}};RequestedVmSettings=[pscustomobject]@{GuestControlledCacheTypes=$true;LowMemoryMappedIoSpace=1GB;HighMemoryMappedIoSpace=16GB}}
    $script:backup=[pscustomobject]@{Identity='synthetic-backup-file';Length=4;SHA256=('A'*64);Attributes=32;Acl=[pscustomobject]@{Owner='S-1-5-18';Dacl='synthetic-dacl'}}
    $script:journal=[pscustomobject]@{Stage='GuestFilesVerified';Backup=(Clone $script:backup);BackupPath='synthetic-backup';MmioStatus=$null;MmioBefore=$null;MmioAfter=$null;Adapter=$null}
    $script:writes=@();$script:saves=@();$script:quiet=$true;$script:manifestCurrent=$true;$script:backupCurrent=$true;$script:backupExists=$true;$script:backupReads=0;$script:addFails=$false
}
function Assert-CgPlanCurrent($Plan,$State='Any') {
    if($Plan.VM.Id -cne $script:vm.Id){throw 'VM identity drift'}
    if($State -ne 'Any' -and $script:vm.State -cne $State){throw 'Actual VM state must be Off'}
    [pscustomobject]@{VM=(Clone $script:vm)}
}
function Assert-CgQuiet($Plan){if(-not $script:quiet){throw 'Cage is not quiet'}}
function Read-CgHostJournal($Plan){Clone $script:journal}
function Save-CgHostJournal($Plan,$Journal){$script:journal=Clone $Journal;$script:saves+=@($Journal.Stage)}
function Assert-CgHostManifestCurrent($Manifest){if(-not $script:manifestCurrent){throw 'Driver manifest drift'}}
function Get-CgFileState($Path){
    if($Path -cne 'synthetic-backup'){throw 'Unexpected file lookup'}
    $script:backupReads++
    if(-not $script:backupExists){return $null}
    $state=Clone $script:backup;if(-not $script:backupCurrent){$state.SHA256='B'*64};$state
}
# Use the real Common.ps1 Assert-CgSameState comparator, including its null behavior.
function Get-VM($Id){if([string]$Id -cne $script:vm.Id){throw 'Wrong VM lookup'};$script:vm}
function Set-VM($VM,$GuestControlledCacheTypes,$LowMemoryMappedIoSpace,$HighMemoryMappedIoSpace){
    if($script:journal.Stage -notin @('AttachIntent','AdapterRollbackIntent')){throw 'Write before durable intent'}
    $script:writes+=@('Settings');$script:vm.GuestControlledCacheTypes=$GuestControlledCacheTypes;$script:vm.LowMemoryMappedIoSpace=$LowMemoryMappedIoSpace;$script:vm.HighMemoryMappedIoSpace=$HighMemoryMappedIoSpace
}
function Add-VMGpuPartitionAdapter($VM,$InstancePath,[switch]$Passthru){
    if($script:journal.MmioStatus -cne 'Written' -or $InstancePath -cne $script:path){throw 'Unexpected attachment ordering/selection'}
    $script:writes+=@('Add');if($script:addFails){throw 'Injected adapter failure'}
    $a=[pscustomobject]@{Id='synthetic-adapter';InstancePath=$InstancePath};$script:vm.GpuAdapters=@($a);$a
}
function Get-VMGpuPartitionAdapter($VM){$script:vm.GpuAdapters}
function Remove-VMGpuPartitionAdapter($VMGpuPartitionAdapter,[switch]$Confirm){
    if($VMGpuPartitionAdapter.Id -cne 'synthetic-adapter' -or $script:journal.Stage -cne 'AdapterRollbackIntent'){throw 'Unowned adapter removal'}
    $script:writes+=@('Remove');$script:vm.GpuAdapters=@()
}
Check 'Exact adapter attach and rollback preserve original settings' {
    Reset-Fixture
    Equal (Invoke-CgAttach $script:plan).Status 'AttachedOff'
    Equal ($script:writes -join ',') 'Settings,Add'
    Equal $script:journal.Adapter.InstancePath $script:path
    Equal (Invoke-CgRollbackAdapter $script:plan).Status 'AdapterRolledBackOff'
    Equal ($script:writes -join ',') 'Settings,Add,Remove,Settings'
    Equal $script:vm.GuestControlledCacheTypes $false
    Equal $script:vm.LowMemoryMappedIoSpace 128MB
    Equal $script:vm.HighMemoryMappedIoSpace 512MB
    Equal (Invoke-CgRollbackAdapter $script:plan).Status 'AlreadyAdapterRolledBack'
    Equal $script:writes.Count 4
}
Check 'Running and Saved states never attach' {
    foreach($state in @('Running','Saved')){Reset-Fixture;$script:vm.State=$state;Refuses {Invoke-CgAttach $script:plan} 'Actual VM';Equal $script:writes.Count 0}
}
Check 'Missing backup metadata or file refuses attach before any mutation' {
    foreach($kind in @('null-record','missing-record','empty-path','missing-path','missing-file','null-record-and-file')){
        Reset-Fixture
        switch($kind){
            'null-record'{$script:journal.Backup=$null}
            'missing-record'{$script:journal.PSObject.Properties.Remove('Backup')}
            'empty-path'{$script:journal.BackupPath=''}
            'missing-path'{$script:journal.PSObject.Properties.Remove('BackupPath')}
            'missing-file'{$script:backupExists=$false}
            'null-record-and-file'{$script:journal.Backup=$null;$script:backupExists=$false}
        }
        Refuses {Invoke-CgAttach $script:plan} 'cold backup'
        Equal $script:writes.Count 0;Equal $script:saves.Count 0
        Equal $script:vm.GpuAdapters.Count 0;Equal $script:vm.GuestControlledCacheTypes $false
        Equal $script:vm.LowMemoryMappedIoSpace 128MB;Equal $script:vm.HighMemoryMappedIoSpace 512MB
        Equal $script:backupReads $(if($kind -eq 'missing-file'){1}else{0})
    }
}
Check 'Unverified staging, busy Cage, backup and manifest drift never write' {
    foreach($kind in @('stage','quiet','backup','manifest')){
        Reset-Fixture
        switch($kind){'stage'{$script:journal.Stage='Prepared'};'quiet'{$script:quiet=$false};'backup'{$script:backupCurrent=$false};'manifest'{$script:manifestCurrent=$false}}
        Refuses {Invoke-CgAttach $script:plan} '';Equal $script:writes.Count 0
    }
}
Check 'Existing adapter and changed MMIO refuse attachment' {
    Reset-Fixture;$script:vm.GpuAdapters=@([pscustomobject]@{Id='unowned';InstancePath='other'})
    Refuses {Invoke-CgAttach $script:plan} 'Unexpected GPU';Equal $script:writes.Count 0
    Reset-Fixture;$script:vm.LowMemoryMappedIoSpace=2GB
    Refuses {Invoke-CgAttach $script:plan} 'MMIO';Equal $script:writes.Count 0
}
Check 'Adapter identity drift preserves every adapter and setting' {
    Reset-Fixture;$null=Invoke-CgAttach $script:plan;$script:vm.GpuAdapters[0].Id='unowned'
    Refuses {Invoke-CgRollbackAdapter $script:plan} 'identity drift';Equal $script:writes.Count 2
}
Check 'External MMIO change refuses rollback before adapter removal' {
    Reset-Fixture;$null=Invoke-CgAttach $script:plan;$script:vm.HighMemoryMappedIoSpace=32GB
    Refuses {Invoke-CgRollbackAdapter $script:plan} 'MMIO/cache drift';Equal $script:writes.Count 2
}
Check 'Unobserved interrupted attachment does not guess ownership' {
    Reset-Fixture;$script:addFails=$true;Refuses {Invoke-CgAttach $script:plan} 'Injected adapter failure'
    Refuses {Invoke-CgRollbackAdapter $script:plan} 'Interrupted unobserved';Equal $script:writes.Count 2
    Reset-Fixture;$script:journal.MmioStatus='Intent'
    Refuses {Invoke-CgRollbackAdapter $script:plan} 'Interrupted unobserved';Equal $script:writes.Count 0
}
Write-Output "Passed $script:checks host adapter cases; all Hyper-V operations mocked."
