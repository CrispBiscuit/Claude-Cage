#requires -Version 7.0
[CmdletBinding()]param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Nvidia.ps1')
. (Join-Path $PSScriptRoot 'Guest.ps1')
. (Join-Path $PSScriptRoot 'Host-Adapter.ps1')
. (Join-Path $PSScriptRoot 'Integration.ps1')
Initialize-CgTargetPolicy ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Nvidia-TargetPolicy.json')))
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a fresh offline test directory.'}
New-CgPrivateDirectory $OutputDirectory
$script:checks=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[scriptblock]$Body){try{& $Body;$script:checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=$null})}catch{$script:checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message})}}
function Equal($Actual,$Expected){if($Actual -cne $Expected){throw "Expected <$Expected>, got <$Actual>"}}
function Refuses([scriptblock]$Body,[string]$Message){$threw=$false;try{& $Body|Out-Null}catch{if($_.Exception.Message -notlike ('*'+$Message+'*')){throw};$threw=$true};if(-not $threw){throw 'Expected refusal did not happen.'}}
function Clone($Object){$Object|ConvertTo-Json -Depth 40|ConvertFrom-Json}
Check 'All maintained PowerShell files parse' {
    foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1'){$t=$null;$e=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$t,[ref]$e);if($e.Count){throw ($e.Message -join '; ')}}
}
Check 'Paths reject traversal, ADS, UNC and trailing dots' {
    foreach($p in @('C:\Windows\System32\..\x.dll','C:\Windows\x.dll:stream','\\server\x','C:\Windows\x.')){Refuses {Get-CgFullPath $p} 'refused'}
}
Check 'Target paths allow active package and exact system DLL only' {
    Assert-CgTarget 'C:\Windows\System32\HostDriverStore\FileRepository\nv_dispi.inf_amd64_ab12\nested\x.dll' 'nv_dispi.inf_amd64_ab12'
    Assert-CgTarget 'C:\Windows\SysWOW64\nvd3dum.dll' 'nv_dispi.inf_amd64_ab12'
    Refuses {Assert-CgTarget 'C:\Users\someone\Cookies' 'nv_dispi.inf_amd64_ab12'} 'outside'
    Refuses {Assert-CgTarget 'C:\Windows\System32\other\x.dll' 'nv_dispi.inf_amd64_ab12'} 'outside'
}
$vm=[pscustomobject]@{Id='00000000-0000-0000-0000-000000000001'}
$device='PCI\VEN_10DE&DEV_1234&SUBSYS_00000000&REV_00\SYNTHETIC_INSTANCE'
$gpu='\\?\PCI#VEN_10DE&DEV_1234&SUBSYS_00000000&REV_00#SYNTHETIC_INSTANCE#{064092b3-625e-43bf-9eb5-dc845897dd59}\GPUPARAV'
$driver=[pscustomobject]@{DeviceID=$device;IsSigned=$true;ClassLink='{4d36e968-e325-11ce-bfc1-08002be10318}\0007'}
$gpus=@([pscustomobject]@{Name='another GPU'},[pscustomobject]@{Name=$gpu})
Check 'Multiple GPUs require exact matching selected path' {Assert-CgAdapterSelection $driver $gpu $gpus;Refuses {Assert-CgAdapterSelection $driver 'AUTO' $gpus} 'Explicit';Refuses {Assert-CgAdapterSelection $driver 'another GPU' $gpus} 'same device'}
Check 'GPU PnP identity mismatch and unsigned driver fail' {$bad=Clone $driver;$bad.DeviceID=$device.Replace('1234','5678');Refuses {Assert-CgAdapterSelection $bad $gpu $gpus} 'same device';$bad=Clone $driver;$bad.IsSigned=$false;Refuses {Assert-CgAdapterSelection $bad $gpu $gpus} 'signed'}
Check 'Non-0000 class mapping is not rejected or normalized' {Equal $driver.ClassLink '{4d36e968-e325-11ce-bfc1-08002be10318}\0007';Assert-CgAdapterSelection $driver $gpu $gpus; $text=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Nvidia.ps1') -Raw;if($text.Contains('\0000')){throw 'Provider hardcodes class index zero.'}}
$package='C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf_amd64_ab12'
Check 'WOW64 source rename maps to SysWOW64' {$m=ConvertTo-CgRegistryMapping ([pscustomobject]@{Key='CopyToVmWhenNewerWow64';Kind='MultiString';Name='umd';Value=@('Display.Driver\nvwow.dll','nv.dll')}) $package;Equal $m.Target 'C:\Windows\SysWOW64\nv.dll';Equal $m.Mode 'WhenNewer'}
Check 'CopyToVm traversal/rename escape is rejected' {Refuses {ConvertTo-CgRegistryMapping ([pscustomobject]@{Key='CopyToVmOverwrite';Kind='String';Name='x';Value=@('..\x.dll')}) $package} 'refused';Refuses {ConvertTo-CgRegistryMapping ([pscustomobject]@{Key='CopyToVmOverwrite';Kind='MultiString';Name='x';Value=@('x.dll','..\evil.dll')}) $package} 'basename'}
Check 'Registry mapping overrides association, conflicts stop' {$t=@{};Add-CgMapping $t ([pscustomobject]@{Target='C:\Windows\System32\x.dll';Source='C:\Windows\System32\x.dll';Mode='Exact';Reason='Association'});Add-CgMapping $t ([pscustomobject]@{Target='C:\Windows\System32\x.dll';Source=($package+'\x.dll');Mode='Overwrite';Reason='CopyToVm'});Equal $t.Values.Source ($package+'\x.dll');Refuses {Add-CgMapping $t ([pscustomobject]@{Target='C:\Windows\System32\x.dll';Source=($package+'\other.dll');Mode='Overwrite';Reason='CopyToVm'})} 'Conflicting'}
Check 'WhenNewer keeps newer version even if source date later' {$f=[pscustomobject]@{Mode='WhenNewer';SHA256='NEW';NumericVersion='1.0.0.0';LastWriteTimeUtc='2026-11-01T00:00:00Z'};$b=[pscustomobject]@{SHA256='OLD';NumericVersion='2.0.0.0';LastWriteTimeUtc='2025-01-01T00:00:00Z'};Equal (Get-CgCopyDecision $f $b) 'KeepNewerOrEqual';$b.NumericVersion='0.5.0.0';Equal (Get-CgCopyDecision $f $b) 'Copy';$b.SHA256='NEW';Equal (Get-CgCopyDecision $f $b) 'Identical'}
Check 'WhenNewer equal version uses timestamp without downgrade' {$f=[pscustomobject]@{Mode='WhenNewer';SHA256='NEW';NumericVersion='1.0.0.0';LastWriteTimeUtc='2026-01-01T00:00:00Z'};$b=[pscustomobject]@{SHA256='OLD';NumericVersion='1.0.0.0';LastWriteTimeUtc='2026-01-01T00:00:00Z'};Equal (Get-CgCopyDecision $f $b) 'KeepNewerOrEqual'}
function Invoke-ProviderFixture([string]$Kind){
    function Get-CgHostDiagnosticRoot { $OutputDirectory }
    $selected=[pscustomobject]@{DeviceID=$device;DeviceName='Synthetic NVIDIA';InfName='oem55.inf';DriverVersion='1.2.3.4';Signer='Synthetic signed driver';IsSigned=$true}
    function Get-CimInstance {param($ClassName,$Filter);$selected}
    function Get-VMHostPartitionableGpu {$gpus}
    function Get-ItemProperty {param($LiteralPath,$Name);if($LiteralPath -like '*\Enum\*'){return [pscustomobject]@{Driver='{4d36e968-e325-11ce-bfc1-08002be10318}\0007'}};[pscustomobject]@{InfPath=$(if($Kind -eq 'InfConflict'){'oem66.inf'}else{'oem55.inf'});DriverVersion='1.2.3.4';UserModeDriverName=@($package+'\umd.dll')}}
    function Get-WindowsDriver {param([switch]$Online,$Driver,$LogPath,$ScratchDirectory);[pscustomobject]@{Driver='oem55.inf';Version='1.2.3.4';MajorVersion=1;MinorVersion=2;Build=3;Revision=4;OriginalFileName=($package+'\nv_dispi.inf');CatalogFile='NV_DISP.CAT';ClassName='Display';ClassGuid='{4d36e968-e325-11ce-bfc1-08002be10318}';ProviderName='NVIDIA';DriverSignature=2}}
    function Test-Path {param($LiteralPath,$PathType);if($LiteralPath -eq ($package+'\nv_dispi.inf')){return $true};if($LiteralPath -like '*\CopyToVm*'){return ($Kind -ne 'MissingMaps' -and $LiteralPath -like '*\CopyToVmWhenNewer')};Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath}
    function Get-Item {param($LiteralPath,[switch]$Force);if($LiteralPath -eq ($package+'\nv_dispi.inf')){return [pscustomobject]@{Attributes=[IO.FileAttributes]::Normal}};if($LiteralPath -like '*\CopyToVmWhenNewer'){$k=[pscustomobject]@{};$k|Add-Member ScriptMethod GetValueNames {,@('UMD')};$k|Add-Member ScriptMethod GetValueKind {param($n)'MultiString'};$k|Add-Member ScriptMethod GetValue {param($n),@('umd.dll')};return $k};Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force}
    Get-CgNvidiaActiveState $device $gpu
}
Check 'Provider resolves selected PnP class 0007 without hardcoding 0000' {Equal (Invoke-ProviderFixture 'Valid').ClassLink '{4d36e968-e325-11ce-bfc1-08002be10318}\0007'}
Check 'Provider refuses active signed-driver/class INF conflict' {Refuses {Invoke-ProviderFixture 'InfConflict'} 'INF or version conflict'}
Check 'Provider refuses absent CopyToVm capability mappings' {Refuses {Invoke-ProviderFixture 'MissingMaps'} 'No active CopyToVm'}
Check 'Manifest pre-copy recheck detects actual source content drift' {
    $source=Join-Path $OutputDirectory 'manifest-drift.bin';[IO.File]::WriteAllText($source,'frozen')
    $active=[pscustomobject]@{DeviceID=$device;GpuInstancePath=$gpu;Package='fixture'}
    $manifest=[pscustomobject]@{Active=$active;PackageFiles=@($source);Files=@([pscustomobject]@{Source=$source;SourceIdentity=Get-CgIdentity $source;Length=(Get-Item -LiteralPath $source).Length;SHA256=Get-CgHash $source})}
    function Get-CgNvidiaActiveState {param($DeviceId,$InstancePath);$active}
    function Get-CgPackageFiles {param($Package);[pscustomobject]@{FullName=$source}}
    Assert-CgHostManifestCurrent $manifest;[IO.File]::WriteAllText($source,'changed')
    Refuses {Assert-CgHostManifestCurrent $manifest} 'Host driver file drift'
}
Check 'In-use target fails without deleting/replacing file' {
    $source=Join-Path $OutputDirectory 'inuse-source.bin';$target=Join-Path $OutputDirectory 'inuse-target.bin';[IO.File]::WriteAllText($source,'new');[IO.File]::WriteAllText($target,'old')
    $before=Get-CgFileState $target;$lock=[IO.File]::Open($target,'Open','Read','None')
    try{Refuses {Write-CgDriverBytes $source $target $true $before (Get-CgHash $source)} 'process'}finally{$lock.Dispose()}
    Assert-CgSameState $before (Get-CgFileState $target)
}
Check 'Private ACL creation and native file identity work offline' {$p=Join-Path $OutputDirectory 'acl-fixture';New-CgPrivateDirectory $p;Assert-CgPrivateDirectory $p;$f=Join-Path $p 'data.bin';[IO.File]::WriteAllText($f,'before');$s=Get-CgFileState $f;if(-not $s.Identity -or -not $s.Acl.Owner){throw 'Missing actual native identity/ACL'};Write-CgJsonAtomic @{One=1} (Join-Path $p 'atomic.json') -New;Write-CgJsonAtomic @{Two=2} (Join-Path $p 'atomic.json');Equal ((Get-Content -LiteralPath (Join-Path $p 'atomic.json') -Raw|ConvertFrom-Json).Two) 2}
Check 'Synthetic reparse metadata refuses descent' {
    $target=Join-Path $OutputDirectory 'reparse-fixture';$null=[IO.Directory]::CreateDirectory($target)
    function Get-Item {param([string]$LiteralPath,[switch]$Force);if($LiteralPath -ceq $target){return [pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint}};Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force}
    Refuses {Assert-CgNoReparse (Join-Path $target 'x.bin')} 'Reparse'
}
Check 'Synthetic link-count metadata rejects target' {
    $a=Join-Path $OutputDirectory 'hard-fixture.bin';[IO.File]::WriteAllText($a,'a')
    function Get-CgLinkCount([string]$Path){2}
    Refuses {Get-CgFileState $a} 'Hard-linked';$null=Get-CgFileState $a -AllowHardLinks
}
Check 'Locked source drift refuses target write' {$a=Join-Path $OutputDirectory 'source.bin';$b=Join-Path $OutputDirectory 'target.bin';[IO.File]::WriteAllText($a,'actual');[IO.File]::WriteAllText($b,'preserved');$before=Get-CgFileState $b;Refuses {Write-CgDriverBytes $a $b $true $before ('0'*64)} 'source bytes';Assert-CgSameState $before (Get-CgFileState $b)}
Check 'Locked target identity/hash drift refuses overwrite' {$a=Join-Path $OutputDirectory 'source2.bin';$b=Join-Path $OutputDirectory 'target2.bin';[IO.File]::WriteAllText($a,'new');[IO.File]::WriteAllText($b,'old');$before=Get-CgFileState $b;[IO.File]::WriteAllText($b,'user-change');Refuses {Write-CgDriverBytes $a $b $true $before (Get-CgHash $a)} 'drift';Equal ([IO.File]::ReadAllText($b)) 'user-change'}
# Redirect only guest path/admin/ACL policy boundaries to this disposable local fixture.
# Actual journal, hash, file identity, bytes, metadata, rollback, and state-machine code run unchanged.
$script:originalPrivate=${function:New-CgPrivateDirectory};$script:originalAssertPrivate=${function:Assert-CgPrivateDirectory}
function New-CgPrivateDirectory([string]$Path,[switch]$Guest){& $script:originalPrivate $Path}
function Assert-CgPrivateDirectory([string]$Path,[switch]$Guest){& $script:originalAssertPrivate $Path}
function Assert-CgGuestAdmin {}
function Get-CgGuestRunPath($Plan){Join-Path $OutputDirectory $Plan.RunId}
function Assert-CgTarget([string]$Target,[string]$PackageName){$null=Assert-CgUnder $Target $OutputDirectory}
function New-Fixture([string]$Name){
    $base=Join-Path $OutputDirectory ('targets-'+$Name);$null=[IO.Directory]::CreateDirectory($base)
    $existing=Join-Path $base 'existing.dll';[IO.File]::WriteAllText($existing,'original-byte-content')
    $files=@();foreach($target in @($existing,(Join-Path $base 'new\new.dll'))){$files+=@([pscustomobject]@{Target=$target;Mode='Overwrite';SHA256='';Length=0;NumericVersion='1.0.0.0';LastWriteTimeUtc='2026-01-01T00:00:00Z'})}
    $payloads=@('new-version-one','new-version-two')
    for($i=0;$i -lt 2;$i++){$b=[Text.UTF8Encoding]::new($false).GetBytes($payloads[$i]);$sha=[Security.Cryptography.SHA256]::Create();try{$files[$i].SHA256=([BitConverter]::ToString($sha.ComputeHash($b))).Replace('-','')}finally{$sha.Dispose()};$files[$i].Length=$b.Length}
    $policy=Get-CgTargetPolicy
    $p=[pscustomobject]@{Schema=1;RunId=('run-'+$Name);VM=$vm;PayloadPins=@([pscustomobject]@{Name='Nvidia-TargetPolicy.json';SHA256=$policy.SHA256});Manifest=[pscustomobject]@{TargetPolicy=[pscustomobject]@{Id=$policy.Id;SHA256=$policy.SHA256;NestedTargets=@()};Files=$files;PackageName='fixture';CopyBytes=($files|Measure-Object Length -Sum).Sum}}
    $null=Initialize-CgGuestRun $p
    for($i=0;$i -lt 2;$i++){$dest=Start-CgGuestStageFile $p $i;[IO.File]::WriteAllText($dest,$payloads[$i],[Text.UTF8Encoding]::new($false));$null=Complete-CgGuestStageFile $p $i}
    $p
}
Check 'Real fixture applies, preserves FileID/ACL, then rolls back bytes/times' {
    $p=New-Fixture 'roundtrip';$before=Get-CgFileState $p.Manifest.Files[0].Target
    $r=Invoke-CgGuestApply $p;Equal $r.Status 'Applied';$after=Get-CgFileState $p.Manifest.Files[0].Target;Equal $after.Identity $before.Identity;Equal $after.Acl.Dacl $before.Acl.Dacl
    $null=Test-CgGuestFiles $p;Equal (Invoke-CgGuestApply $p).Status 'AlreadyApplied'
    Equal (Invoke-CgGuestRollback $p).Status 'RolledBack';Assert-CgSameState $before (Get-CgFileState $p.Manifest.Files[0].Target) -IncludeTimes
    if(Test-Path -LiteralPath $p.Manifest.Files[1].Target){throw 'New driver file remains'};Equal (Invoke-CgGuestRollback $p).Status 'AlreadyRolledBack'
}
Check 'Rollback conflicts preserve post-apply external changes' {$p=New-Fixture 'conflict';$null=Invoke-CgGuestApply $p;[IO.File]::WriteAllText($p.Manifest.Files[0].Target,'external-user-change');Refuses {Invoke-CgGuestRollback $p} 'drift';Equal ([IO.File]::ReadAllText($p.Manifest.Files[0].Target)) 'external-user-change'}
Check 'Tampered rollback backup prevents any restore' {$p=New-Fixture 'bad-backup';$null=Invoke-CgGuestApply $p;$j=Read-CgGuestJournal $p;[IO.File]::WriteAllText($j.Entries[0].BackupPath,'corrupt');Refuses {Invoke-CgGuestRollback $p} 'drift';Equal ([IO.File]::ReadAllText($p.Manifest.Files[0].Target)) 'new-version-one'}
Check 'Incomplete transferred payload cannot reach apply' {$p=New-Fixture 'stage-drift';$j=Read-CgGuestJournal $p;[IO.File]::WriteAllText($j.Entries[0].StagedPath,'partial');Refuses {Invoke-CgGuestApply $p} 'drift';Equal ([IO.File]::ReadAllText($p.Manifest.Files[0].Target)) 'original-byte-content'}
Check 'An unobserved external writer exception is not claimed as owned partial state' {
    $p=New-Fixture 'partial';$real=${function:Write-CgDriverBytes}
    try{function Write-CgDriverBytes([string]$Source,[string]$Target,[bool]$Existing,$Expected,[string]$SourceSHA256){[IO.File]::WriteAllText($Target,'partial');throw 'Injected write failure'};Refuses {Invoke-CgGuestApply $p} 'Injected write failure'}finally{${function:Write-CgDriverBytes}=$real}
    $j=Read-CgGuestJournal $p;Equal $j.Stage 'Failed';Equal $j.Entries[0].TargetStatus 'WriteUnobserved';Equal $j.Entries[0].After $null
    Refuses {Invoke-CgGuestRollback $p} 'Non-owned conflict';Equal ([IO.File]::ReadAllText($p.Manifest.Files[0].Target)) 'partial'
}
Check 'Unobserved process-loss WriteIntent cannot auto-restore' {$p=New-Fixture 'power-loss';$j=Read-CgGuestJournal $p;$j.Stage='Applying';$j.Entries[0].TargetStatus='WriteIntent';Save-CgGuestJournal $p $j;Refuses {Invoke-CgGuestRollback $p} 'Unobserved interrupted';Equal ([IO.File]::ReadAllText($p.Manifest.Files[0].Target)) 'original-byte-content'}
Check 'Modified incoming plan cannot reuse another guest transaction' {$p=New-Fixture 'plan-drift';$p.Manifest.Files[0].SHA256='0'*64;Refuses {Read-CgGuestJournal $p} 'Incoming plan differs'}
Check 'D3D probe compiles and native layout matches independent SDK ABI' {
    Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'D3D11Readback.cs') -Raw)
    $layout=[ClaudeGpuProbe.D3D11Readback]::Layout();Equal $layout.PointerBytes 8;Equal $layout.TextureDescBytes 44;Equal $layout.MappedResourceBytes 16;Equal $layout.AdapterDesc1Bytes 312;Equal $layout.AdapterVendorOffset 256;Equal $layout.AdapterLuidOffset 296;Equal $layout.AdapterFlagsOffset 304
}

Check 'Exact selection rejects duplicate paths and unsupported vendors' {
    Refuses {Assert-CgAdapterSelection $driver $gpu @($gpus[1],$gpus[1])} 'ambiguous'
    foreach($vendor in @('1002','8086')){$other=Clone $driver;$other.DeviceID=$device.Replace('10DE',$vendor);Refuses {Assert-CgAdapterSelection $other $gpu $gpus} 'NVIDIA'}
}
Check 'DISM coverage rows resolve one package, not one specific GPU model' {
    $row=[pscustomobject]@{Driver='oem55.inf';OriginalFileName=($package+'\nv_dispi.inf');Version='1.2.3.4';CatalogFile='NV_DISP.CAT';ClassName='Display';ClassGuid='{4d36e968-e325-11ce-bfc1-08002be10318}';ProviderName='NVIDIA';DriverSignature=2;MajorVersion=1;MinorVersion=2;Build=3;Revision=4;HardwareId='PCI\VEN_10DE&DEV_1234'}
    $second=Clone $row;$second.HardwareId='PCI\VEN_10DE&DEV_5678'
    Equal (Resolve-CgDismPackage @($row,$second) 'oem55.inf' '1.2.3.4').DetailRowCount 2
    foreach($kind in @('package','inf','version','signature','provider','catalog','missing')){
        $bad=Clone $second
        switch($kind){
            'package'{$bad.OriginalFileName='C:\Windows\System32\DriverStore\FileRepository\other_amd64_ab12\other.inf'}
            'inf'{$bad.Driver='oem56.inf'}
            'version'{$bad.Revision=5}
            'signature'{$bad.DriverSignature=0}
            'provider'{$bad.ProviderName='AMD'}
            'catalog'{$bad.CatalogFile='..\escape.cat'}
            'missing'{$bad.PSObject.Properties.Remove('CatalogFile')}
        }
        Refuses {Resolve-CgDismPackage @($row,$bad) 'oem55.inf' '1.2.3.4'} ''
    }
}
Check 'Pre-write conflict is never claimed as an owned partial write' {
    $p=New-Fixture 'prewrite-conflict';$real=${function:Write-CgDriverBytes}
    function Write-CgDriverBytes([string]$Source,[string]$Target,[bool]$Existing,$Expected,[string]$SourceSHA256){[IO.File]::WriteAllText($Target,'external-edit-before-lock');& $real $Source $Target $Existing $Expected $SourceSHA256}
    Refuses {Invoke-CgGuestApply $p} 'drift';$j=Read-CgGuestJournal $p
    Equal $j.Entries[0].TargetStatus 'PreWriteConflict';Equal $j.Entries[0].After $null
    Refuses {Invoke-CgGuestRollback $p} 'Non-owned conflict'
    Equal ([IO.File]::ReadAllText($p.Manifest.Files[0].Target)) 'external-edit-before-lock'
}
Check 'Held writer records partial bytes and supports owned rollback' {
    $p=New-Fixture 'owned-partial';$before=Get-CgFileState $p.Manifest.Files[0].Target
    function Copy-CgStreamBytes([IO.Stream]$Source,[IO.Stream]$Destination){$Destination.WriteByte(65);throw 'Injected copy failure'}
    Refuses {Invoke-CgGuestApply $p} 'Injected copy failure';$j=Read-CgGuestJournal $p
    Equal $j.Entries[0].TargetStatus 'PartialObserved';Equal $j.Entries[0].After.Length 1
    function Copy-CgStreamBytes([IO.Stream]$Source,[IO.Stream]$Destination){$Source.CopyTo($Destination)}
    $null=Invoke-CgGuestRollback $p
    Assert-CgSameState $before (Get-CgFileState $p.Manifest.Files[0].Target) -IncludeTimes
}
Check 'Timestamp conflict refuses rollback before removing later targets' {
    $p=New-Fixture 'timestamp-conflict';$null=Invoke-CgGuestApply $p
    [IO.File]::SetLastWriteTimeUtc($p.Manifest.Files[0].Target,[datetime]::UtcNow.AddMinutes(-5))
    Refuses {Invoke-CgGuestRollback $p} 'timestamp drift'
    Equal (Test-Path -LiteralPath $p.Manifest.Files[1].Target) $true
}
$failed=@($checks|Where-Object {-not $_.Passed})
$report=[ordered]@{Status=$(if($failed.Count){'FAILED'}else{'PASSED'});Runtime=$PSVersionTable.PSVersion.ToString();Count=$checks.Count;Passed=$checks.Count-$failed.Count;Checks=$checks.ToArray();LiveVMCalls=0;GuestAccess=0;GPUCalls=0;Limits='File transactions use disposable local files. Guest identity and target roots are redirected; native link cases use synthetic metadata. D3D is compiled and ABI-checked, never executed.'}
Write-CgJsonAtomic $report (Join-Path $OutputDirectory 'report.json') -New
$report|ConvertTo-Json -Depth 8
if($failed.Count){exit 1}
