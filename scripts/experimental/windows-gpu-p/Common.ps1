# Experimental reference components; see README.md before use.
# Functions only. Live integration hooks intentionally fail closed.
Set-StrictMode -Version Latest
function Get-CgCanonicalJson($Value) { $Value|ConvertTo-Json -Depth 40|ConvertFrom-Json|ConvertTo-Json -Depth 40 -Compress }
function Get-CgHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Get-CgFullPath([string]$Path) {
    if($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':') -or $Path -match '(^|\\)\.\.?($|\\)' -or $Path -match '[\. ](\\|$)' -or $Path.Contains('/')){throw 'Noncanonical/UNC/ADS/relative path refused.'}
    [IO.Path]::GetFullPath($Path)
}
function Assert-CgUnder([string]$Path,[string]$Root) {
    $p=Get-CgFullPath $Path;$r=(Get-CgFullPath $Root).TrimEnd('\')
    if(-not $p.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Path leaves its explicit root.'}
    $p
}
function Assert-CgNoReparse([string]$Path) {
    $p=Get-CgFullPath $Path
    for($q=$p;$q;$q=Split-Path $q -Parent){if(Test-Path -LiteralPath $q){if((Get-Item -LiteralPath $q -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse path refused.'}}}
}
function Initialize-CgIdentityType {
    if('CageGpuFileIdentity' -as [type]){return}
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class CageGpuFileIdentity {
 [StructLayout(LayoutKind.Sequential)] struct INFO { public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write; public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow; }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle handle,out INFO info);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFileTime(SafeFileHandle handle,IntPtr creation,IntPtr access,ref long write);
 public sealed class Facts { public string Identity,CreationTimeUtc,LastWriteTimeUtc,LastAccessTimeUtc; public long Length; public uint Attributes,Links; }
 static string Time(System.Runtime.InteropServices.ComTypes.FILETIME t) { return DateTime.FromFileTimeUtc(((long)t.dwHighDateTime<<32)|(uint)t.dwLowDateTime).ToString("o"); }
 public static Facts ReadFacts(SafeFileHandle h) { INFO i; if(h.IsInvalid || !GetFileInformationByHandle(h,out i)) throw new System.ComponentModel.Win32Exception(); return new Facts { Identity=i.Volume.ToString("X8")+":"+(((ulong)i.IndexHigh<<32)|i.IndexLow).ToString("X16"),Length=((long)i.SizeHigh<<32)|i.SizeLow,Attributes=i.Attributes,Links=i.Links,CreationTimeUtc=Time(i.Creation),LastWriteTimeUtc=Time(i.Write),LastAccessTimeUtc=Time(i.Access) }; }
 public static void SetWriteTimeUtc(SafeFileHandle h) { long t=DateTime.UtcNow.ToFileTimeUtc(); if(!SetFileTime(h,IntPtr.Zero,IntPtr.Zero,ref t)) throw new System.ComponentModel.Win32Exception(); }
 public static string Read(string path) { using(var h=CreateFile(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) { return FromHandle(h); } }
 public static uint Links(string path) { using(var h=CreateFile(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) { INFO i; if(h.IsInvalid || !GetFileInformationByHandle(h,out i)) throw new System.ComponentModel.Win32Exception(); return i.Links; } }
 public static string FromHandle(SafeFileHandle h) { INFO i; if(h.IsInvalid || !GetFileInformationByHandle(h,out i)) throw new System.ComponentModel.Win32Exception(); return i.Volume.ToString("X8")+":"+(((ulong)i.IndexHigh<<32)|i.IndexLow).ToString("X16"); }
}
'@
}
function Get-CgIdentity([string]$Path) { Initialize-CgIdentityType; [CageGpuFileIdentity]::Read($Path) }
function Get-CgLinkCount([string]$Path) { Initialize-CgIdentityType; [CageGpuFileIdentity]::Links($Path) }
function Read-CgAccessControl($Item,$Sections) {
    if($PSVersionTable.PSVersion.Major -le 5){return $Item.GetAccessControl($Sections)}
    [IO.FileSystemAclExtensions]::GetAccessControl($Item,$Sections)
}
function Set-CgAccessControl($Item,$Acl) {
    if($PSVersionTable.PSVersion.Major -le 5){$Item.SetAccessControl($Acl);return}
    [IO.FileSystemAclExtensions]::SetAccessControl($Item,$Acl)
}
function Get-CgAclState([string]$Path) {
    # Access+Owner only; never retrieve/apply a SACL or invoke SeSecurityPrivilege.
    $item=Get-Item -LiteralPath $Path -Force
    $acl=Read-CgAccessControl $item ([Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner)
    [ordered]@{Owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value;Dacl=$acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)}
}
function Get-CgHeldFileState([IO.FileStream]$Stream) {
    Initialize-CgIdentityType
    $facts=[CageGpuFileIdentity]::ReadFacts($Stream.SafeFileHandle)
    if($facts.Links -ne 1){throw 'Hard-linked mutation target refused.'}
    # FileStream.GetAccessControl requests owner/group/DACL, never the SACL.
    $acl=if($PSVersionTable.PSVersion.Major -le 5){$Stream.GetAccessControl()}else{[IO.FileSystemAclExtensions]::GetAccessControl($Stream)}
    $position=$Stream.Position;$Stream.Position=0;$sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-','')}finally{$sha.Dispose();$Stream.Position=$position}
    [ordered]@{Identity=$facts.Identity;Length=$facts.Length;SHA256=$hash;Acl=[ordered]@{Owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value;Dacl=$acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)};CreationTimeUtc=$facts.CreationTimeUtc;LastWriteTimeUtc=$facts.LastWriteTimeUtc;LastAccessTimeUtc=$facts.LastAccessTimeUtc;Attributes=[int]$facts.Attributes;NumericVersion=$null}
}
function Get-CgFileState([string]$Path,[switch]$AllowHardLinks) {
    Assert-CgNoReparse $Path
    if(-not(Test-Path -LiteralPath $Path)){return $null}
    $i=Get-Item -LiteralPath $Path -Force
    if($i.PSIsContainer){throw 'File target is a directory.'}
    Initialize-CgIdentityType
    if(-not $AllowHardLinks -and (Get-CgLinkCount $Path) -ne 1){throw 'Hard-linked mutation target refused.'}
    $v=$i.VersionInfo
    [ordered]@{Identity=Get-CgIdentity $Path;Length=$i.Length;SHA256=Get-CgHash $Path;Acl=Get-CgAclState $Path;CreationTimeUtc=$i.CreationTimeUtc.ToString('o');LastWriteTimeUtc=$i.LastWriteTimeUtc.ToString('o');LastAccessTimeUtc=$i.LastAccessTimeUtc.ToString('o');Attributes=[int]$i.Attributes;NumericVersion=(@($v.FileMajorPart,$v.FileMinorPart,$v.FileBuildPart,$v.FilePrivatePart)-join '.')}
}
function Assert-CgSameState($Expected,$Actual,[switch]$IncludeTimes) {
    if($null -eq $Expected -or $null -eq $Actual){if($null -ne $Expected -or $null -ne $Actual){throw 'File existence drift.'};return}
    foreach($key in @('Identity','Length','SHA256','Attributes')){if([string]$Expected.$key -cne [string]$Actual.$key){throw "File $key drift."}}
    if($Expected.Acl.Owner -cne $Actual.Acl.Owner -or $Expected.Acl.Dacl -cne $Actual.Acl.Dacl){throw 'File owner/DACL drift.'}
    if($IncludeTimes){foreach($key in @('CreationTimeUtc','LastWriteTimeUtc')){if(([datetime]$Expected.$key).ToUniversalTime() -ne ([datetime]$Actual.$key).ToUniversalTime()){throw 'File timestamp drift.'}}}
}
function Write-CgJsonAtomic($Value,[string]$Path,[switch]$New) {
    Assert-CgNoReparse $Path
    if($New -and (Test-Path -LiteralPath $Path)){throw 'Immutable receipt already exists.'}
    $tmp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 40))
    $f=[IO.File]::Open($tmp,'CreateNew','Write','None');try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
    if($New){[IO.File]::Move($tmp,$Path)}
    elseif(Test-Path -LiteralPath $Path){[IO.File]::Replace($tmp,$Path,[NullString]::Value)}else{[IO.File]::Move($tmp,$Path)}
}
function New-CgPrivateDirectory([string]$Path,[switch]$Guest) {
    Assert-CgNoReparse $Path
    if(Test-Path -LiteralPath $Path){throw 'Private transaction directory already exists.'}
    $null=[IO.Directory]::CreateDirectory($Path)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner($sid)
    $allowed=if($Guest){@('S-1-5-18','S-1-5-32-544')}else{@($sid.Value,'S-1-5-18','S-1-5-32-544')}
    foreach($s in $allowed|Select-Object -Unique){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($s),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
    # SetAccessControl applies only modified Access/Owner sections.
    Set-CgAccessControl ([IO.DirectoryInfo]::new($Path)) $acl
    Assert-CgPrivateDirectory $Path -Guest:$Guest
}
function Assert-CgPrivateDirectory([string]$Path,[switch]$Guest) {
    Assert-CgNoReparse $Path
    $item=[IO.DirectoryInfo]::new($Path)
    $acl=Read-CgAccessControl $item ([Security.AccessControl.AccessControlSections]::Access)
    $allowed=if($Guest){@('S-1-5-18','S-1-5-32-544')}else{@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')}
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if(-not $acl.AreAccessRulesProtected -or $rules.Count -eq 0 -or @($rules|Where-Object {$_.IdentityReference.Value -notin $allowed -or $_.AccessControlType -ne 'Allow'}).Count){throw 'Transaction directory is not private.'}
}
function Initialize-CgTargetPolicy([byte[]]$Bytes) {
    # This reviewed envelope is pinned in code as well as the runtime bundle.
    # A caller-supplied manifest list cannot grant access to additional targets.
    $expected='313BBD6FE152F70C86F1946057FBC848B263D26447C16A7521001F9544810ED7'
    $sha=[Security.Cryptography.SHA256]::Create();try{$actual=([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')}finally{$sha.Dispose()}
    if($actual -cne $expected){throw 'Reviewed NVIDIA target-policy bytes changed.'}
    $policy=[Text.Encoding]::UTF8.GetString($Bytes)|ConvertFrom-Json
    if($policy.Schema -ne 1 -or $policy.PolicyId -cne 'NVIDIA_SYSTEM32_NESTED_20261112_V1' -or $policy.Provider -cne 'NVIDIA'){throw 'Unexpected reviewed target-policy schema.'}
    $paths=@(foreach($relative in $policy.AllowedNestedRelativePaths){
        if($relative -match '[*?]' -or [IO.Path]::IsPathRooted($relative)){throw 'Policy must contain exact relative names.'}
        $path=Get-CgFullPath ('C:\Windows\'+$relative)
        $null=Assert-CgUnder $path 'C:\Windows\System32'
        $path
    })
    if(-not $paths.Count -or @($paths|Sort-Object -Unique).Count -ne $paths.Count){throw 'Policy target names are empty or duplicated.'}
    $script:CgReviewedTargetPolicy=[pscustomobject]@{Id=$policy.PolicyId;SHA256=$expected;AllowedTargets=$paths}
}
function Get-CgTargetPolicy {
    $variable=Get-Variable -Name CgReviewedTargetPolicy -Scope Script -ErrorAction SilentlyContinue
    if($null -eq $variable -or $null -eq $variable.Value){throw 'Reviewed target policy is missing from the trusted payload.'}
    $variable.Value
}
function Assert-CgTarget([string]$Target,[string]$PackageName,$NestedBinding=$null,[string]$ExpectedDeviceId='',[string]$ExpectedSource='',[string]$ExpectedSHA256='',[string]$ExpectedIdentity='') {
    $p=Get-CgFullPath $Target
    $package='C:\Windows\System32\HostDriverStore\FileRepository\'+$PackageName
    if($PackageName -notmatch '^[A-Za-z0-9_.-]+_amd64_[a-fA-F0-9]+$'){throw 'Invalid active-package basename.'}
    if($p.StartsWith($package+'\',[StringComparison]::OrdinalIgnoreCase)){return}
    if($p -match '^C:\\Windows\\(System32|SysWOW64)\\[^\\]+$'){return}
    $policy=Get-CgTargetPolicy
    if($p -notin @($policy.AllowedTargets)){throw 'Nested target is outside the exact reviewed NVIDIA policy.'}
    if($null -eq $NestedBinding -or $NestedBinding.PolicyId -cne $policy.Id -or $NestedBinding.PolicySHA256 -cne $policy.SHA256){throw 'Nested target lacks its reviewed policy binding.'}
    if(-not $ExpectedDeviceId -or $NestedBinding.AssociationDeviceId -cne $ExpectedDeviceId -or $NestedBinding.AssociationSource -ine $p -or $ExpectedSource -ine $p){throw 'Nested target lacks its exact selected-device association binding.'}
    if($ExpectedSHA256 -notmatch '^[A-F0-9]{64}$' -or -not $ExpectedIdentity -or $NestedBinding.SourceSHA256 -cne $ExpectedSHA256 -or $NestedBinding.SourceIdentity -cne $ExpectedIdentity){throw 'Nested source hash/file-identity binding differs from frozen file record.'}
    $matches=@($NestedBinding.PackageMatches)
    if(-not $matches.Count){throw 'Nested target has no active-package file-object evidence.'}
    foreach($match in $matches){
        $null=Assert-CgUnder $match.Source ('C:\Windows\System32\DriverStore\FileRepository\'+$PackageName)
        if($match.Identity -cne $ExpectedIdentity -or $match.SHA256 -cne $ExpectedSHA256){throw 'Nested source differs from its active-package file object or hash.'}
    }
}
function Assert-CgManifestFileTarget($Plan,$File) {
    $binding=if($File.PSObject.Properties['NestedBinding']){$File.NestedBinding}else{$null}
    if($null -eq $binding){Assert-CgTarget $File.Target $Plan.Manifest.PackageName;return}
    Assert-CgTarget $File.Target $Plan.Manifest.PackageName $binding $Plan.Manifest.Active.DeviceID $File.Source $File.SHA256 $File.SourceIdentity
}
function Assert-CgPlanTargetPolicy($Plan) {
    $policy=Get-CgTargetPolicy
    if(-not $Plan.Manifest.PSObject.Properties['TargetPolicy'] -or $Plan.Manifest.TargetPolicy.Id -cne $policy.Id -or $Plan.Manifest.TargetPolicy.SHA256 -cne $policy.SHA256){throw 'Frozen plan target-policy binding is missing or changed.'}
    $pin=@($Plan.PayloadPins|Where-Object Name -ceq 'Nvidia-TargetPolicy.json')
    if($pin.Count -ne 1 -or $pin[0].SHA256 -cne $policy.SHA256){throw 'Guest/host target-policy payload pin is missing or changed.'}
    foreach($file in $Plan.Manifest.Files){Assert-CgManifestFileTarget $Plan $file}
    foreach($file in $Plan.Manifest.Files|Where-Object {$_.PSObject.Properties['NestedBinding'] -and $null -ne $_.NestedBinding}){
        foreach($match in $file.NestedBinding.PackageMatches){
            $records=@($Plan.Manifest.Files|Where-Object {$_.Reason -ceq 'ActivePackage' -and $_.Source -ieq $match.Source})
            if($records.Count -ne 1 -or $records[0].SourceIdentity -cne $match.Identity -or $records[0].SHA256 -cne $match.SHA256){throw 'Nested binding does not reference a frozen active-package file record.'}
        }
    }
    $nested=@($Plan.Manifest.Files|Where-Object {$_.PSObject.Properties['NestedBinding'] -and $null -ne $_.NestedBinding}|ForEach-Object {$_.Target.ToLowerInvariant()}|Sort-Object)
    $declared=@($Plan.Manifest.TargetPolicy.NestedTargets|ForEach-Object {(Get-CgFullPath $_).ToLowerInvariant()}|Sort-Object)
    if(($nested -join "`n") -cne ($declared -join "`n") -or @($declared|Sort-Object -Unique).Count -ne $declared.Count){throw 'Frozen nested-target subset differs from its bound file records.'}
}
function Get-CgCopyDecision($File,$Before) {
    if($null -eq $Before){return 'Copy'}
    if($Before.SHA256 -ceq $File.SHA256){return 'Identical'}
    if($File.Mode -eq 'WhenNewer'){
        $old=[version]$Before.NumericVersion;$new=[version]$File.NumericVersion
        if($old -gt $new -or ($old -eq $new -and ([datetime]$Before.LastWriteTimeUtc).ToUniversalTime() -ge ([datetime]$File.LastWriteTimeUtc).ToUniversalTime())){return 'KeepNewerOrEqual'}
    }elseif($File.Mode -notin @('Exact','Overwrite')){throw 'Unknown copy mode.'}
    'Copy'
}
function Assert-CgAdapterSelection($Driver,[string]$InstancePath,$Partitionables) {
    if(-not $InstancePath -or $InstancePath -match '^(AUTO|first)$'){throw 'Explicit GPU InstancePath required.'}
    if($Driver.DeviceID -notmatch '^PCI\\VEN_10DE&DEV_[0-9A-F]{4}' -or -not $Driver.IsSigned){throw 'Only a signed active NVIDIA PCI display driver is implemented.'}
    if(@($Partitionables|Where-Object Name -ceq $InstancePath).Count -ne 1){throw 'Selected GPU partition capability is absent or ambiguous.'}
    $prefix='\\?\'+($Driver.DeviceID -replace '\\','#')+'#'
    if(-not $InstancePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not $InstancePath.EndsWith('\GPUPARAV',[StringComparison]::OrdinalIgnoreCase)){throw 'PnP GPU and partition path do not identify the same device.'}
}
