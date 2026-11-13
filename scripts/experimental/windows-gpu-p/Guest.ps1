# Experimental reference components; see README.md before use.
# Functions only. Live integration hooks intentionally fail closed.
Set-StrictMode -Version Latest
function Read-CgGuestJournal($Plan) {
    Assert-CgPlanTargetPolicy $Plan
    $root=Get-CgGuestRunPath $Plan;Assert-CgPrivateDirectory $root -Guest
    $path=Join-Path $root 'journal.json';Assert-CgNoReparse $path
    $j=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    if($j.PlanSHA256 -cne (Get-CgHash (Join-Path $root 'plan.json')) -or $j.RunId -cne $Plan.RunId){throw 'Guest journal/plan pin changed.'}
    $stored=Get-Content -LiteralPath (Join-Path $root 'plan.json') -Raw|ConvertFrom-Json
    if((Get-CgCanonicalJson $stored) -cne (Get-CgCanonicalJson $Plan)){throw 'Incoming plan differs from this guest transaction.'}
    $j
}
function Save-CgGuestJournal($Plan,$Journal) { Write-CgJsonAtomic $Journal (Join-Path (Get-CgGuestRunPath $Plan) 'journal.json') }
function Initialize-CgGuestRun($Plan) {
    Assert-CgGuestAdmin
    Assert-CgPlanTargetPolicy $Plan
    $root=Get-CgGuestRunPath $Plan
    Assert-CgNoReparse $root
    $base=Split-Path $root -Parent
    if(-not(Test-Path -LiteralPath $base)){New-CgPrivateDirectory $base -Guest}else{Assert-CgPrivateDirectory $base -Guest}
    if(Test-Path -LiteralPath $root){throw 'Run already exists; no blind retry.'}
    # Preflight whole manifest before target mutation; guest storage must cover staged bytes,
    # current replacement backups, and new target bytes. No arbitrary GiB reserve.
    $backupBytes=[long]0;$newBytes=[long]0;$before=@()
    foreach($f in $Plan.Manifest.Files){
        Assert-CgManifestFileTarget $Plan $f
        $old=Get-CgFileState $f.Target;$decision=Get-CgCopyDecision $f $old
        if($decision -eq 'Copy'){if($null -ne $old){$backupBytes+=$old.Length}else{$newBytes+=$f.Length}}
        $before += [ordered]@{Target=$f.Target;Before=$old;Decision=$decision}
    }
    $required=[long]$Plan.Manifest.CopyBytes+$backupBytes+$newBytes
    if([IO.DriveInfo]::new('C:\').AvailableFreeSpace -lt $required){throw 'Insufficient guest free bytes for exact staging/backup/new files.'}
    New-CgPrivateDirectory $root -Guest
    Write-CgJsonAtomic $Plan (Join-Path $root 'plan.json') -New
    $j=[ordered]@{Schema=1;RunId=$Plan.RunId;PlanSHA256=Get-CgHash (Join-Path $root 'plan.json');Stage='Prepared';RequiredGuestBytes=$required;BackupBytes=$backupBytes;Preflight=$before;Entries=@();CreatedDirectories=@();Probes=@();GuiProbes=@();Failure=$null}
    Save-CgGuestJournal $Plan $j
    foreach($leaf in @('stage','backup')){
        $path=Join-Path $root $leaf
        $j.CreatedDirectories+=@([ordered]@{Path=$path;Status='Intent';Identity=$null});Save-CgGuestJournal $Plan $j
        $null=[IO.Directory]::CreateDirectory($path)
        $j.CreatedDirectories[-1].Status='Created';$j.CreatedDirectories[-1].Identity=Get-CgIdentity $path;Save-CgGuestJournal $Plan $j
    }
    [pscustomobject]@{Root=$root;RequiredGuestBytes=$required;BackupBytes=$backupBytes;Stage='Prepared'}
}
function Start-CgGuestStageFile($Plan,[int]$Index) {
    Assert-CgGuestAdmin;$j=Read-CgGuestJournal $Plan
    if($j.Stage -notin @('Prepared','Staging') -or $Index -ne @($j.Entries).Count -or $Index -ge @($Plan.Manifest.Files).Count){throw 'Staging order/state mismatch; no retry.'}
    $path=Join-Path (Get-CgGuestRunPath $Plan) ('stage\{0:D5}.bin' -f $Index)
    Assert-CgNoReparse $path;if(Test-Path -LiteralPath $path){throw 'Unjournaled staging file exists.'}
    $j.Stage='Staging';$j.Entries+=@([pscustomobject]@{Index=$Index;StagedPath=$path;StageStatus='Intent';StageState=$null;TargetStatus='Pending';Before=$j.Preflight[$Index].Before;Decision=$j.Preflight[$Index].Decision;BackupPath=$null;BackupState=$null;After=$null;RollbackStatus='Pending'})
    Save-CgGuestJournal $Plan $j
    $path
}
function Complete-CgGuestStageFile($Plan,[int]$Index) {
    Assert-CgGuestAdmin;$j=Read-CgGuestJournal $Plan;$e=$j.Entries[$Index];$f=$Plan.Manifest.Files[$Index]
    if($j.Stage -ne 'Staging' -or $e.StageStatus -ne 'Intent'){throw 'Unexpected staged-file state.'}
    $s=Get-CgFileState $e.StagedPath
    if($s.Length -ne $f.Length -or $s.SHA256 -cne $f.SHA256){throw 'Transferred driver file hash mismatch.'}
    $e.StageState=$s;$e.StageStatus='Verified'
    if(@($j.Entries).Count -eq @($Plan.Manifest.Files).Count -and @($j.Entries|Where-Object StageStatus -ne 'Verified').Count -eq 0){$j.Stage='Staged'}
    Save-CgGuestJournal $Plan $j
    [pscustomobject]@{Index=$Index;Status=$e.StageStatus}
}
function New-CgTargetParents($Plan,$Journal,[string]$Target) {
    $missing=[Collections.Generic.List[string]]::new();$parent=Split-Path $Target -Parent
    while(-not(Test-Path -LiteralPath $parent)){$missing.Add($parent);$parent=Split-Path $parent -Parent}
    for($i=$missing.Count-1;$i -ge 0;$i--){
        $path=$missing[$i];Assert-CgNoReparse $path
        $Journal.CreatedDirectories+=@([pscustomobject]@{Path=$path;Status='Intent';Identity=$null});Save-CgGuestJournal $Plan $Journal
        $null=[IO.Directory]::CreateDirectory($path)
        $Journal.CreatedDirectories[-1].Identity=Get-CgIdentity $path;$Journal.CreatedDirectories[-1].Status='Created';Save-CgGuestJournal $Plan $Journal
    }
}
function Copy-CgStreamBytes([IO.Stream]$Source,[IO.Stream]$Destination) { $Source.CopyTo($Destination) }
function Write-CgDriverBytes([string]$Source,[string]$Target,[bool]$Existing,$Expected,[string]$SourceSHA256) {
    # Only this writer may declare ownership, while its exclusive target handle is held.
    # Pre-write validation failures never turn subsequently observed external bytes into ours.
    $mode=if($Existing){[IO.FileMode]::Open}else{[IO.FileMode]::CreateNew}
    $outcome=[ordered]@{MutationBegan=$false;After=$null;Succeeded=$false}
    $input=$null;$output=$null;$failure=$null
    try{
        $input=[IO.File]::Open($Source,'Open','Read','Read')
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$sourceHash=([BitConverter]::ToString($sha.ComputeHash($input))).Replace('-','');$input.Position=0
            if($sourceHash -cne $SourceSHA256){throw 'Locked source bytes differ from manifest.'}
            $output=[IO.File]::Open($Target,$mode,'ReadWrite','None')
            if($Existing){Assert-CgSameState $Expected (Get-CgHeldFileState $output) -IncludeTimes}
            # CreateNew has already created a new file; existing targets are marked only
            # after all locked preconditions pass, immediately before truncation.
            $outcome.MutationBegan=$true
            $output.SetLength(0);Copy-CgStreamBytes $input $output;$output.Flush($true)
            [CageGpuFileIdentity]::SetWriteTimeUtc($output.SafeFileHandle)
            $outcome.After=Get-CgHeldFileState $output;$outcome.Succeeded=$true
        }finally{$sha.Dispose()}
    }catch{
        $failure=$_.Exception
        if($outcome.MutationBegan -and $null -ne $output){
            try{$output.Flush($true);[CageGpuFileIdentity]::SetWriteTimeUtc($output.SafeFileHandle);$outcome.After=Get-CgHeldFileState $output}catch{$outcome.After=$null}
        }
    }finally{if($null -ne $output){$output.Dispose()};if($null -ne $input){$input.Dispose()}}
    if($null -ne $failure){$wrapped=[InvalidOperationException]::new($failure.Message,$failure);$wrapped.Data['CageGpuWriteOutcome']=[pscustomobject]$outcome;throw $wrapped}
    [pscustomobject]$outcome
}
function Invoke-CgGuestApply($Plan) {
    Assert-CgGuestAdmin;$root=Get-CgGuestRunPath $Plan
    $lock=[IO.File]::Open((Join-Path $root 'transaction.lock'),'OpenOrCreate','ReadWrite','None')
    try{
        $j=Read-CgGuestJournal $Plan
        if($j.Stage -eq 'Applied'){return [pscustomobject]@{Status='AlreadyApplied';NoWrites=$true}}
        if($j.Stage -ne 'Staged'){throw 'All staging hashes must verify before apply; interrupted writes require review.'}
        foreach($e in $j.Entries){Assert-CgSameState $e.StageState (Get-CgFileState $e.StagedPath);Assert-CgSameState $e.Before (Get-CgFileState $Plan.Manifest.Files[$e.Index].Target) -IncludeTimes}
        $j.Stage='Applying';Save-CgGuestJournal $Plan $j
        foreach($e in $j.Entries){
            $f=$Plan.Manifest.Files[$e.Index];Assert-CgManifestFileTarget $Plan $f
            Assert-CgSameState $e.StageState (Get-CgFileState $e.StagedPath)
            Assert-CgSameState $e.Before (Get-CgFileState $f.Target) -IncludeTimes
            if($e.Decision -ne 'Copy'){$e.After=$e.Before;$e.TargetStatus='Skipped';Save-CgGuestJournal $Plan $j;continue}
            New-CgTargetParents $Plan $j $f.Target
            if($null -ne $e.Before){
                $e.BackupPath=Join-Path $root ('backup\{0:D5}.bin' -f $e.Index);$e.TargetStatus='BackupIntent';Save-CgGuestJournal $Plan $j
                [IO.File]::Copy($f.Target,$e.BackupPath,$false)
                $e.BackupState=Get-CgFileState $e.BackupPath
                if($e.BackupState.SHA256 -cne $e.Before.SHA256 -or $e.BackupState.Length -ne $e.Before.Length){throw 'Old file backup hash mismatch.'}
                $e.TargetStatus='BackedUp';Save-CgGuestJournal $Plan $j
            }
            Assert-CgSameState $e.Before (Get-CgFileState $f.Target) -IncludeTimes
            $e.TargetStatus='WriteIntent';Save-CgGuestJournal $Plan $j
            $writeOutcome=$null
            try{
                $writeOutcome=Write-CgDriverBytes $e.StagedPath $f.Target ($null -ne $e.Before) $e.Before $f.SHA256
                $e.After=$writeOutcome.After
                Assert-CgSameState $e.After (Get-CgFileState $f.Target) -IncludeTimes
                if($e.After.SHA256 -cne $f.SHA256 -or $e.After.Length -ne $f.Length){throw 'Written driver hash mismatch.'}
                if($null -ne $e.Before -and ($e.After.Identity -cne $e.Before.Identity -or $e.After.Acl.Owner -cne $e.Before.Acl.Owner -or $e.After.Acl.Dacl -cne $e.Before.Acl.Dacl)){throw 'Existing driver file identity/ACL changed.'}
                $e.TargetStatus='Written';Save-CgGuestJournal $Plan $j
            }catch{
                if($null -eq $writeOutcome -and $_.Exception.Data.Contains('CageGpuWriteOutcome')){$writeOutcome=$_.Exception.Data['CageGpuWriteOutcome']}
                if($null -ne $writeOutcome -and $writeOutcome.MutationBegan -and $null -ne $writeOutcome.After){$e.After=$writeOutcome.After;$e.TargetStatus='PartialObserved'}
                elseif($null -ne $writeOutcome -and -not $writeOutcome.MutationBegan){$e.After=$null;$e.TargetStatus='PreWriteConflict'}
                else{$e.After=$null;$e.TargetStatus='WriteUnobserved'}
                $j.Stage='Failed';$j.Failure=$_.Exception.Message;Save-CgGuestJournal $Plan $j;throw
            }
        }
        $j.Stage='Applied';Save-CgGuestJournal $Plan $j
        [pscustomobject]@{Status='Applied';Files=@($j.Entries|Where-Object TargetStatus -eq 'Written').Count;Kept=@($j.Entries|Where-Object TargetStatus -eq 'Skipped').Count;JournalSHA256=Get-CgHash (Join-Path $root 'journal.json')}
    }finally{$lock.Dispose()}
}
function Restore-CgFileMetadata([string]$Path,$Before) {
    $acl=Get-CgAclState $Path
    if($acl.Owner -cne $Before.Acl.Owner -or $acl.Dacl -cne $Before.Acl.Dacl){throw 'Owner/DACL drift; preserve it, do not reassign ownership or ACL.'}
    [IO.File]::SetCreationTimeUtc($Path,([datetime]$Before.CreationTimeUtc).ToUniversalTime())
    [IO.File]::SetLastWriteTimeUtc($Path,([datetime]$Before.LastWriteTimeUtc).ToUniversalTime())
    [IO.File]::SetLastAccessTimeUtc($Path,([datetime]$Before.LastAccessTimeUtc).ToUniversalTime())
    [IO.File]::SetAttributes($Path,[IO.FileAttributes]$Before.Attributes)
}
function Invoke-CgGuestRollback($Plan) {
    Assert-CgGuestAdmin;$root=Get-CgGuestRunPath $Plan
    $lock=[IO.File]::Open((Join-Path $root 'transaction.lock'),'OpenOrCreate','ReadWrite','None')
    try{
        $j=Read-CgGuestJournal $Plan
        if($j.Stage -eq 'RolledBack'){return [pscustomobject]@{Status='AlreadyRolledBack';NoWrites=$true}}
        # Validate all affected states and backups before the first restore. Do not overwrite drift.
        foreach($e in $j.Entries){
            if($e.RollbackStatus -eq 'Restored'){continue}
            if($e.TargetStatus -in @('WriteIntent','WriteUnobserved','PreWriteConflict') -or $e.RollbackStatus -eq 'RestoreIntent'){throw 'Non-owned conflict or unobserved interrupted write; preserve disk and seek explicit recovery review.'}
            if($e.TargetStatus -in @('Written','PartialObserved')){
                Assert-CgSameState $e.After (Get-CgFileState $Plan.Manifest.Files[$e.Index].Target) -IncludeTimes
                if($null -ne $e.Before -and ($e.Before.Acl.Owner -cne $e.After.Acl.Owner -or $e.Before.Acl.Dacl -cne $e.After.Acl.Dacl)){throw 'Recorded owner/DACL differs; do not restore bytes before resolving it.'}
                if($null -ne $e.Before){Assert-CgSameState $e.BackupState (Get-CgFileState $e.BackupPath)}
            }
        }
        $j.Stage='RollingBack';Save-CgGuestJournal $Plan $j
        for($i=@($j.Entries).Count-1;$i -ge 0;$i--){$e=$j.Entries[$i];$f=$Plan.Manifest.Files[$e.Index]
            if($e.RollbackStatus -eq 'Restored' -or $e.TargetStatus -notin @('Written','PartialObserved')){continue}
            Assert-CgSameState $e.After (Get-CgFileState $f.Target) -IncludeTimes
            $e.RollbackStatus='RestoreIntent';Save-CgGuestJournal $Plan $j
            if($null -eq $e.Before){
                # Leaf only; no recursive delete, and the observed after-state was checked above.
                [IO.File]::Delete($f.Target)
                if(Test-Path -LiteralPath $f.Target){throw 'New file removal failed.'}
            }else{
                $null=Write-CgDriverBytes $e.BackupPath $f.Target $true $e.After $e.Before.SHA256
                Restore-CgFileMetadata $f.Target $e.Before
                Assert-CgSameState $e.Before (Get-CgFileState $f.Target) -IncludeTimes
            }
            $e.RollbackStatus='Restored';Save-CgGuestJournal $Plan $j
        }
        # Remove only this run's empty driver directories. Retain evidence/stage/backup.
        for($i=@($j.CreatedDirectories).Count-1;$i -ge 0;$i--){$d=$j.CreatedDirectories[$i]
            if($d.Path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){continue}
            if($d.Status -eq 'Removed'){continue}
            if($d.Status -ne 'Created'){throw 'Unobserved directory creation/removal; retain for review.'}
            Assert-CgNoReparse $d.Path
            if(Test-Path -LiteralPath $d.Path){if((Get-CgIdentity $d.Path) -cne $d.Identity){throw 'Created directory identity drift.'};if(@(Get-ChildItem -LiteralPath $d.Path -Force).Count -eq 0){$d.Status='RemoveIntent';Save-CgGuestJournal $Plan $j;[IO.Directory]::Delete($d.Path,$false);$d.Status='Removed';Save-CgGuestJournal $Plan $j}}
        }
        $j.Stage='RolledBack';Save-CgGuestJournal $Plan $j
        [pscustomobject]@{Status='RolledBack';EvidenceRetained=$root;WholeDiskRestore=$false}
    }finally{$lock.Dispose()}
}
function Test-CgGuestFiles($Plan) {
    Assert-CgGuestAdmin;$j=Read-CgGuestJournal $Plan
    if($j.Stage -ne 'Applied'){throw 'Guest file transaction is not applied.'}
    foreach($e in $j.Entries){Assert-CgSameState $e.After (Get-CgFileState $Plan.Manifest.Files[$e.Index].Target)}
    [pscustomobject]@{Status='GuestFilesVerified';Count=@($j.Entries).Count;HardwareFunction='Not established by file verification'}
}
