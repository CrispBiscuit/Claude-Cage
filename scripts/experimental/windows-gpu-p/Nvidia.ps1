# Experimental reference components; see README.md before use.
# Functions only. Live integration hooks intentionally fail closed.
Set-StrictMode -Version Latest
function Add-CgMapping($Table,$Entry) {
    $key=$Entry.Target.ToLowerInvariant()
    if($Table.ContainsKey($key)){
        $old=$Table[$key]
        if($old.Source -ieq $Entry.Source -and $old.Mode -ceq $Entry.Mode){return}
        # Active CopyToVm mapping supersedes a generic signed-driver association only.
        if($Entry.Reason -eq 'CopyToVm' -and $old.Reason -eq 'Association'){$Table[$key]=$Entry;return}
        throw 'Conflicting active-package target mappings.'
    }
    $Table[$key]=$Entry
}
function ConvertTo-CgRegistryMapping($Map,[string]$Package) {
    if($Map.Key -notin @('CopyToVmOverwrite','CopyToVmWhenNewer','CopyToVmOverwriteWow64','CopyToVmWhenNewerWow64') -or $Map.Kind -notin @('String','MultiString')){throw 'Unsupported CopyToVm mapping/type.'}
    $pair=@($Map.Value)
    if($pair.Count -notin @(1,2) -or -not $pair[0] -or [IO.Path]::IsPathRooted($pair[0])){throw 'Invalid relative CopyToVm source.'}
    $source=Assert-CgUnder (Join-Path $Package $pair[0]) $Package
    $leaf=if($pair.Count -eq 2 -and $pair[1]){[string]$pair[1]}else{Split-Path $source -Leaf}
    if($leaf -cne [IO.Path]::GetFileName($leaf) -or $leaf -match '[:/\\]' -or $leaf -match '[. ]$'){throw 'CopyToVm destination must be a canonical basename.'}
    $directory=if($Map.Key.EndsWith('Wow64')){'C:\Windows\SysWOW64'}else{'C:\Windows\System32'}
    [pscustomobject]@{Source=$source;Target=(Join-Path $directory $leaf);Mode=$(if($Map.Key -like 'CopyToVmWhenNewer*'){'WhenNewer'}else{'Overwrite'});Reason='CopyToVm';MappingKey=$Map.Key;MappingName=$Map.Name}
}
function Resolve-CgDismPackage([object[]]$Rows,[string]$ExpectedInf,[string]$ExpectedVersion) {
    # DISM details contain hardware/model rows, not one row per unique package.
    # Validate every row, then require one complete consistent package identity.
    if($null -eq $Rows -or $Rows.Count -eq 0){throw 'No detailed DISM rows for the selected active INF.'}
    if($ExpectedInf -notmatch '^[A-Za-z0-9_.-]+\.inf$' -or $ExpectedVersion -notmatch '^\d+\.\d+\.\d+\.\d+$' -or ([version]$ExpectedVersion).ToString(4) -cne $ExpectedVersion){throw 'Selected CIM INF/version is not canonical.'}
    $store='C:\Windows\System32\DriverStore\FileRepository'
    $display=[guid]'4d36e968-e325-11ce-bfc1-08002be10318'
    $common=$null;$commonKey=$null
    $required=@('Driver','OriginalFileName','Version','CatalogFile','ClassName','ClassGuid','ProviderName','DriverSignature','MajorVersion','MinorVersion','Build','Revision')
    foreach($row in $Rows){
        if($null -eq $row){throw 'Null detailed DISM row.'}
        $value=@{}
        foreach($name in $required){
            $property=$row.PSObject.Properties[$name]
            if($null -eq $property -or $null -eq $property.Value){throw "Incomplete DISM package identity: $name"}
            $value[$name]=$property.Value
        }
        foreach($name in @('Driver','OriginalFileName','Version','CatalogFile','ClassName','ClassGuid','ProviderName')){
            if($value[$name] -isnot [string] -or [string]::IsNullOrWhiteSpace($value[$name]) -or $value[$name] -cne $value[$name].Trim()){throw "Invalid DISM package text: $name"}
        }
        if($value.Driver -ine $ExpectedInf){throw 'DISM published INF differs from the selected active CIM driver.'}
        if($value.Version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or ([version]$value.Version).ToString(4) -cne $ExpectedVersion){throw 'DISM version differs from the selected active CIM driver.'}
        $parts=@(foreach($name in @('MajorVersion','MinorVersion','Build','Revision')){
            if([string]$value[$name] -notmatch '^\d+$'){throw 'Invalid DISM numeric version component.'}
            [uint32]$value[$name]
        })
        if(($parts -join '.') -cne $value.Version){throw 'DISM Version string and four numeric components disagree.'}
        if($value.ProviderName -ine 'NVIDIA'){throw 'DISM provider is not the selected NVIDIA provider.'}
        if($value.ClassName -ine 'Display' -or [guid]$value.ClassGuid -ne $display){throw 'DISM package is not the expected Display class.'}
        if([string]$value.DriverSignature -notin @('2','Signed') -or [int]$value.DriverSignature -ne 2){throw 'DISM package signature is not Signed (2).'}
        $inf=Get-CgFullPath $value.OriginalFileName;$null=Assert-CgUnder $inf $store
        if([IO.Path]::GetExtension($inf) -ine '.inf'){throw 'DISM original package path is not an INF.'}
        foreach($segment in $inf.Substring($store.Length+1).Split('\')){if(-not $segment -or $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0){throw 'Invalid DISM original INF path segment.'}}
        $catalog=$value.CatalogFile
        if($catalog -cne [IO.Path]::GetFileName($catalog) -or $catalog.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $catalog -notmatch '\.cat$'){throw 'DISM catalog must be a canonical catalog basename.'}
        $identity=[ordered]@{Driver=$value.Driver.ToLowerInvariant();OriginalFileName=$inf.ToLowerInvariant();Version=$ExpectedVersion;CatalogFile=$catalog.ToLowerInvariant();ClassName='display';ClassGuid=$display.ToString('D');ProviderName='nvidia';DriverSignature=2}
        $key=$identity|ConvertTo-Json -Compress
        if($null -eq $commonKey){$commonKey=$key;$common=[pscustomobject]@{Driver=$ExpectedInf;OriginalFileName=$inf;Version=$ExpectedVersion;CatalogFile=$catalog;ClassName='Display';ClassGuid=$display.ToString('D');ProviderName='NVIDIA';DriverSignature=2;DetailRowCount=$Rows.Count}}
        elseif($key -cne $commonKey){throw 'Detailed DISM rows identify multiple or inconsistent driver packages.'}
    }
    # Hardware description/IDs/architecture are coverage metadata, not an all-model match
    # requirement. Exact active PnP/class/INF/GPU binding is enforced by the caller.
    $common
}
function Get-CgNvidiaActiveState([string]$DeviceId,[string]$InstancePath) {
    $drivers=@(Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter "DeviceClass='DISPLAY'" | Where-Object DeviceID -ieq $DeviceId)
    if($drivers.Count -ne 1){throw 'Active signed driver lookup is absent/ambiguous.'}
    $d=$drivers[0]
    Assert-CgAdapterSelection $d $InstancePath @(Get-VMHostPartitionableGpu)
    $link=(Get-ItemProperty -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\'+$d.DeviceID) -Name Driver).Driver
    if($link -notmatch '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\\d{4}$'){throw 'Unexpected PnP-to-display-class linkage.'}
    $class='Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\'+$link
    $p=Get-ItemProperty -LiteralPath $class
    if($p.InfPath -ine $d.InfName -or $p.DriverVersion -cne $d.DriverVersion){throw 'Signed driver/class INF or version conflict.'}
    $diagnosticRoot=Get-CgHostDiagnosticRoot
    Assert-CgNoReparse $diagnosticRoot
    $log=Join-Path $diagnosticRoot ('dism-read-'+[guid]::NewGuid().ToString('N')+'.log')
    $dism=@(Get-WindowsDriver -Online -Driver $d.InfName -LogPath $log -ScratchDirectory $diagnosticRoot)
    $resolved=Resolve-CgDismPackage $dism $d.InfName $d.DriverVersion
    $inf=$resolved.OriginalFileName
    $package=Split-Path $inf -Parent
    $null=Assert-CgUnder $inf 'C:\Windows\System32\DriverStore\FileRepository'
    Assert-CgNoReparse $inf
    if(-not(Test-Path -LiteralPath $inf -PathType Leaf)){throw 'Active INF is absent.'}
    $maps=@(foreach($keyName in @('CopyToVmOverwrite','CopyToVmWhenNewer','CopyToVmOverwriteWow64','CopyToVmWhenNewerWow64')){
        $keyPath=Join-Path $class $keyName
        if(Test-Path -LiteralPath $keyPath){$key=Get-Item -LiteralPath $keyPath;foreach($name in $key.GetValueNames()){
            [pscustomobject]@{Key=$keyName;Name=$name;Kind=$key.GetValueKind($name).ToString();Value=@($key.GetValue($name))}
        }}
    })
    if(-not $maps.Count){throw 'No active CopyToVm mapping: provider capability not established.'}
    $umd=@($p.UserModeDriverName)
    if(-not $umd.Count){throw 'No active UMD paths.'}
    foreach($path in $umd){$null=Assert-CgUnder $path $package;Assert-CgNoReparse $path}
    [pscustomobject]@{DeviceID=$d.DeviceID;DeviceName=$d.DeviceName;DriverVersion=$d.DriverVersion;InfName=$d.InfName;Signer=$d.Signer;IsSigned=$d.IsSigned;ClassLink=$link;Package=$package;InfPath=$inf;Maps=$maps;UserModeDriverPaths=$umd;GpuInstancePath=$InstancePath}
}
function Get-CgPackageFiles([string]$Package) {
    Assert-CgNoReparse $Package
    # Inspect each directory before descent; never recurse through a junction.
    $stack=[Collections.Generic.Stack[string]]::new();$stack.Push($Package)
    $files=[Collections.Generic.List[object]]::new()
    while($stack.Count){$dir=$stack.Pop();foreach($entry in Get-ChildItem -LiteralPath $dir -Force){
        if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Active package contains reparse entry.'}
        if($entry.PSIsContainer){$stack.Push($entry.FullName)}else{$files.Add($entry)}
    }}
    @($files.ToArray()|Sort-Object FullName)
}
function Select-CgNvidiaAssociationFiles([object[]]$Rows,[string]$DeviceId) {
    $selected=[Collections.Generic.List[object]]::new();$seen=@{}
    foreach($row in $Rows){
        if($null -eq $row -or $row.Antecedent -isnot [Microsoft.Management.Infrastructure.CimInstance] -or $row.Antecedent.CimSystemProperties.ClassName -ine 'Win32_PnPSignedDriver' -or -not $row.Antecedent.DeviceID){throw 'Malformed signed-driver association antecedent; no silent drop.'}
        if($row.Antecedent.DeviceID -ine $DeviceId){continue}
        if($row.Dependent -isnot [Microsoft.Management.Infrastructure.CimInstance] -or $row.Dependent.CimSystemProperties.ClassName -ine 'CIM_DataFile' -or -not $row.Dependent.Name){throw 'Malformed selected-driver native file reference.'}
        $path=Get-CgFullPath $row.Dependent.Name;$key=$path.ToLowerInvariant()
        if($seen.ContainsKey($key)){throw 'Duplicate/ambiguous selected-driver file reference.'}
        $seen[$key]=$true;$selected.Add($row.Dependent)
    }
    if(-not $selected.Count){throw 'No exact selected-device associated files; mapping is incomplete.'}
    $selected.ToArray()
}
function Get-CgCachedDriverState($Cache,[string]$Path) {
    $key=$Path.ToLowerInvariant()
    if(-not $Cache.ContainsKey($key)){
        Assert-CgNoReparse $Path;$state=Get-CgFileState $Path -AllowHardLinks
        if($null -eq $state){throw 'Mapped source missing.'};$Cache[$key]=$state
    }
    $Cache[$key]
}
function New-CgNestedBinding($Active,[string]$Source,$SourceState,$PackageStates) {
    $policy=Get-CgTargetPolicy
    if($Source -notin @($policy.AllowedTargets)){throw 'Unreviewed nested NVIDIA target; policy review is required.'}
    $matches=@($PackageStates|Where-Object {$_.Identity -ceq $SourceState.Identity})
    if(-not $matches.Count -or @($matches|Where-Object {$_.SHA256 -cne $SourceState.SHA256}).Count){throw 'Nested association source is not the same file object/hash as its active package.'}
    [pscustomobject]@{PolicyId=$policy.Id;PolicySHA256=$policy.SHA256;AssociationDeviceId=$Active.DeviceID;AssociationSource=$Source;SourceIdentity=$SourceState.Identity;SourceSHA256=$SourceState.SHA256;PackageMatches=@($matches|Sort-Object Source|Select-Object Source,Identity,SHA256)}
}
function New-CgPublishedInfExclusion($Active,[string]$Source,$Published,$Canonical) {
    $expected='C:\Windows\INF\'+$Active.InfName
    if($Source -ine $expected -or $Published.SHA256 -cne $Canonical.SHA256 -or $Published.Length -ne $Canonical.Length){throw 'Published host INF does not match its active canonical INF; do not exclude it.'}
    [pscustomobject]@{Reason='HostPublishedInfRegistrationOnly';Source=$Source;DeviceID=$Active.DeviceID;InfName=$Active.InfName;DriverVersion=$Active.DriverVersion;Length=$Published.Length;SHA256=$Published.SHA256;SourceIdentity=$Published.Identity;CanonicalInf=$Active.InfPath;CanonicalIdentity=$Canonical.Identity;CanonicalSHA256=$Canonical.SHA256;GuestTarget=$null}
}
function Get-CgNvidiaManifest($Active) {
    $package=$Active.Package;$packageName=Split-Path $package -Leaf
    $policy=Get-CgTargetPolicy
    $table=@{};$states=@{};$packageStates=$null;$exclusions=@();$packageFiles=@(Get-CgPackageFiles $package)
    if(-not $packageFiles.Count){throw 'Empty active driver package.'}
    $cats=@($packageFiles|Where-Object Extension -eq '.cat')
    if(-not $cats.Count){throw 'Active package has no signed catalog.'}
    $catalogs=@(foreach($cat in $cats){$sig=Get-AuthenticodeSignature -LiteralPath $cat.FullName;if($sig.Status -ne 'Valid'){throw 'Active package catalog signature is not valid.'};[ordered]@{Path=$cat.FullName;SHA256=Get-CgHash $cat.FullName;Signer=$sig.SignerCertificate.Subject;Thumbprint=$sig.SignerCertificate.Thumbprint}})
    foreach($f in $packageFiles){
        $relative=$f.FullName.Substring($package.Length+1)
        Add-CgMapping $table ([pscustomobject]@{Source=$f.FullName;Target=('C:\Windows\System32\HostDriverStore\FileRepository\'+$packageName+'\'+$relative);Mode='Exact';Reason='ActivePackage'})
    }
    $driver=@(Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter "DeviceClass='DISPLAY'"|Where-Object DeviceID -ieq $Active.DeviceID)
    if($driver.Count -ne 1 -or $driver[0].InfName -ine $Active.InfName -or $driver[0].DriverVersion -cne $Active.DriverVersion){throw 'Active driver identity changed during manifest capture.'}
    # Association-class enumeration also handles providers that reject ASSOCIATORS traversal.
    # Enumerate its association class and validate native refs against the exact DeviceID.
    $associationRows=@(Get-CimInstance -ClassName Win32_PnPSignedDriverCIMDataFile -OperationTimeoutSec 30)
    $associated=@(Select-CgNvidiaAssociationFiles $associationRows $Active.DeviceID)
    foreach($f in $associated){
        $path=Get-CgFullPath $f.Name
        if($path.StartsWith($package+'\',[StringComparison]::OrdinalIgnoreCase)){continue}
        if($path -match '^C:\\Windows\\System32\\DriverStore\\'){throw 'Selected driver associates another package; explicit review required.'}
        if($path -ieq ('C:\Windows\INF\'+$Active.InfName)){
            $exclusions+=@(New-CgPublishedInfExclusion $Active $path (Get-CgCachedDriverState $states $path) (Get-CgCachedDriverState $states $Active.InfPath));continue
        }
        $binding=$null
        if($path -notmatch '^C:\\Windows\\(System32|SysWOW64)\\[^\\]+$'){
            if($path -notin @($policy.AllowedTargets)){throw 'Unreviewed nested/out-of-root association target; no silent exclusion.'}
            if($null -eq $packageStates){$packageStates=@(foreach($file in $packageFiles){$s=Get-CgCachedDriverState $states $file.FullName;[pscustomobject]@{Source=$file.FullName;Identity=$s.Identity;SHA256=$s.SHA256}})}
            $s=Get-CgCachedDriverState $states $path;$binding=New-CgNestedBinding $Active $path $s $packageStates
            Assert-CgTarget $path $packageName $binding $Active.DeviceID $path $s.SHA256 $s.Identity
        }else{Assert-CgTarget $path $packageName}
        Add-CgMapping $table ([pscustomobject]@{Source=$path;Target=$path;Mode='Exact';Reason='Association';NestedBinding=$binding})
    }
    foreach($map in $Active.Maps){Add-CgMapping $table (ConvertTo-CgRegistryMapping $map $package)}
    $entries=@(foreach($e in $table.Values|Sort-Object Target){
        $state=Get-CgCachedDriverState $states $e.Source
        $binding=if($e.PSObject.Properties['NestedBinding']){$e.NestedBinding}else{$null}
        Assert-CgTarget $e.Target $packageName $binding $Active.DeviceID $e.Source $state.SHA256 $state.Identity
        $signature=$null
        if([IO.Path]::GetExtension($e.Source) -in @('.exe','.dll','.sys','.cat')){
            $sig=Get-AuthenticodeSignature -LiteralPath $e.Source
            if($sig.Status -ne 'Valid'){throw "Unexpected unsigned/invalid executable driver file: $($e.Source)"}
            $signature=[ordered]@{Status=$sig.Status.ToString();Signer=$sig.SignerCertificate.Subject;Thumbprint=$sig.SignerCertificate.Thumbprint}
        }
        [pscustomobject][ordered]@{Source=$e.Source;Target=$e.Target;Mode=$e.Mode;Reason=$e.Reason;Length=$state.Length;SHA256=$state.SHA256;SourceIdentity=$state.Identity;NumericVersion=$state.NumericVersion;LastWriteTimeUtc=$state.LastWriteTimeUtc;Signature=$signature;NestedBinding=$binding}
    })
    [pscustomobject]@{Provider='NVIDIA';ProviderSchema=1;Active=$Active;PackageName=$packageName;TargetPolicy=[pscustomobject]@{Id=$policy.Id;SHA256=$policy.SHA256;NestedTargets=@($entries|Where-Object {$null -ne $_.NestedBinding}|ForEach-Object Target|Sort-Object)};ExcludedAssociations=$exclusions;Catalogs=$catalogs;Files=$entries;CopyBytes=[long](($entries|Measure-Object Length -Sum).Sum);PackageFiles=@($packageFiles.FullName);Coverage='Capability-based mapping only; explicit reviewed nested targets; no WSL configuration or capability claim; this reference export has no end-to-end hardware/GUI validation.'}
}
function Assert-CgHostManifestCurrent($Manifest) {
    $now=Get-CgNvidiaActiveState $Manifest.Active.DeviceID $Manifest.Active.GpuInstancePath
    if(($now|ConvertTo-Json -Depth 12 -Compress) -cne ($Manifest.Active|ConvertTo-Json -Depth 12 -Compress)){throw 'Active host driver/version/mapping drift.'}
    $paths=@(Get-CgPackageFiles $now.Package|ForEach-Object FullName)
    if(($paths -join "`n") -cne (@($Manifest.PackageFiles) -join "`n")){throw 'Active package file set drift.'}
    foreach($f in $Manifest.Files){Assert-CgNoReparse $f.Source;if((Get-CgIdentity $f.Source) -cne $f.SourceIdentity -or (Get-Item -LiteralPath $f.Source).Length -ne $f.Length -or (Get-CgHash $f.Source) -cne $f.SHA256){throw 'Host driver file drift before copy.'}}
    if($Manifest.PSObject.Properties['ExcludedAssociations']){foreach($excluded in $Manifest.ExcludedAssociations){
        if($excluded.Reason -cne 'HostPublishedInfRegistrationOnly' -or $excluded.DeviceID -cne $Manifest.Active.DeviceID -or $excluded.InfName -ine $Manifest.Active.InfName -or $excluded.DriverVersion -cne $Manifest.Active.DriverVersion){throw 'Published-INF exclusion active binding changed.'}
        $published=Get-CgFileState $excluded.Source -AllowHardLinks;$canonical=Get-CgFileState $Manifest.Active.InfPath -AllowHardLinks
        $null=New-CgPublishedInfExclusion $Manifest.Active $excluded.Source $published $canonical
        if($published.Identity -cne $excluded.SourceIdentity -or $published.SHA256 -cne $excluded.SHA256 -or $canonical.Identity -cne $excluded.CanonicalIdentity -or $canonical.SHA256 -cne $excluded.CanonicalSHA256){throw 'Published-INF exclusion source drift before copy.'}
    }}
}
