<#FIELDKIT
Name      : Remote Readiness
Category  : Remote
Summary   : Which targets can be reached, by WinRM or DCOM, and which answer nothing at all.
Requires  : None
Elevation : Not needed
Scope     : Remote targets
Output    : RemoteReadiness
ReadOnly   : Yes
Remote    : Console
FIELDKIT#>

<#
    Test-RemoteReadiness.ps1

    Run this before any remote sweep. It answers the only question that
    determines whether the sweep is worth running: what can actually be
    reached.

    ---------------------------------------------------------------------------
    IT IS ALSO A FINDING ON ITS OWN

    A production server that answers neither WinRM nor DCOM is a server that
    nothing is managing. No configuration tool, no inventory agent and no
    remote administration reaches it either. That is usually news to the client
    and it is worth reporting whether or not the sweep ever happens.

    A name in Active Directory that does not resolve in DNS is a different
    finding again: a stale directory object rather than an unreachable machine.
    The two are separated deliberately, because counting stale objects as
    unreachable servers inflates a problem that is really housekeeping.

    ---------------------------------------------------------------------------
    HOW TO RUN IT

      .\Test-RemoteReadiness.ps1 -ComputerName SRV01,SRV02
      .\Test-RemoteReadiness.ps1 -InputFile C:\work\targets.txt
      .\Test-RemoteReadiness.ps1 -FromAD -ADFilter "OperatingSystem -like '*Server*'" `
                                 -ExcludeFile C:\work\exclude.txt

    -FromAD requires typed confirmation and shows the list first. Anything
    fragile belongs in the exclusion file.

    -SkipPortTest omits the TCP connects and relies on Test-WSMan and CIM
    alone. Slower to fail, but it sends less.

    READ-ONLY, and it writes nothing to any target.
#>

[CmdletBinding()]
param(
    [string[]] $ComputerName,
    [string]   $InputFile,
    [switch]   $FromAD,
    [string]   $ADFilter = "Enabled -eq 'True'",
    [string]   $ExcludeFile,
    [string[]] $Exclude,
    [pscredential] $Credential,
    [switch]   $SkipPortTest,
    [int]      $TimeoutSeconds = 5
)

$libDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'Lib'
. (Join-Path $libDir 'Fieldkit.Common.ps1')
. (Join-Path $libDir 'Fieldkit.Remote.ps1')

$out   = New-FieldkitOutputFolder -ToolOutputName 'RemoteReadiness'
$notes = [System.Collections.Generic.List[string]]::new()

Write-FieldkitHeader -Title 'Remote Readiness' -OutputFolder $out

# ------------------------------------------------------------------- targets
if (-not $ComputerName -and -not $InputFile -and -not $FromAD) {
    Write-Host '  No targets given.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Supply one of:'
    Write-Host '    -ComputerName SRV01,SRV02'
    Write-Host '    -InputFile C:\work\targets.txt      (one name per line, or a CSV)'
    Write-Host '    -FromAD                             (asks for confirmation first)'
    Write-Host ''
    Write-Host '  A target list is deliberately never implied. Nothing is contacted' -ForegroundColor DarkGray
    Write-Host '  unless you said what to contact.'                                   -ForegroundColor DarkGray
    Write-Host ''
    $notes.Add('NOT READ  Entire run - no targets were supplied, so nothing was contacted.')
    Write-FieldkitSummary -Title 'Remote Readiness' -OutputFolder $out -Notes $notes
    return
}

try {
    $set = Get-FieldkitTarget -ComputerName $ComputerName -InputFile $InputFile `
                              -FromAD:$FromAD -ADFilter $ADFilter `
                              -ExcludeFile $ExcludeFile -Exclude $Exclude
}
catch {
    Write-Host ''
    Write-Host "  STOP: could not build the target list." -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    $notes.Add("NOT READ  Target list - $($_.Exception.Message)")
    Write-FieldkitSummary -Title 'Remote Readiness' -OutputFolder $out -Notes $notes
    return
}

if (-not (Confirm-FieldkitTargetList -TargetSet $set -Action 'probe')) {
    $notes.Add('Run cancelled at the target list confirmation. Nothing was contacted.')
    Write-FieldkitSummary -Title 'Remote Readiness' -OutputFolder $out -Notes $notes
    return
}

if ($set.Excluded.Count) {
    $set.Excluded | Export-Csv -LiteralPath (Join-Path $out 'EXCLUDED.csv') -NoTypeInformation -Encoding UTF8
    $notes.Add("$($set.Excluded.Count) target(s) were EXCLUDED and never contacted. See EXCLUDED.csv.")
}

Write-FieldkitLog -Level 'RUN' -Message "Remote readiness probe of $($set.Targets.Count) target(s) from $($set.Source)"

# --------------------------------------------------------------------- probe
Write-Host ''
Write-Host ("  Probing {0} target(s)" -f $set.Targets.Count) -ForegroundColor Cyan
if ($SkipPortTest) { Write-Host '  Port tests skipped.' -ForegroundColor DarkGray }
Write-Host ''

$rows = [System.Collections.Generic.List[object]]::new()
$i = 0
foreach ($t in $set.Targets) {
    $i++
    Write-Progress -Activity 'Probing targets' -Status $t -PercentComplete (($i / $set.Targets.Count) * 100)
    Write-Host ("  {0,-38} " -f $t) -NoNewline

    $r = Test-FieldkitReachability -ComputerName $t -Credential $Credential `
                                   -TimeoutSeconds $TimeoutSeconds -SkipPortTest:$SkipPortTest
    $rows.Add($r)

    switch ($r.Transport) {
        'WinRM' { Write-Host 'WinRM' -ForegroundColor Green }
        'DCOM'  { Write-Host 'DCOM only' -ForegroundColor Yellow }
        default {
            if ($r.DNS -ne 'resolves') { Write-Host ("DNS: {0}" -f $r.DNS) -ForegroundColor DarkYellow }
            else { Write-Host 'NOTHING ANSWERS' -ForegroundColor Red }
        }
    }
}
Write-Progress -Activity 'Probing targets' -Completed

$rows | Export-Csv -LiteralPath (Join-Path $out 'READINESS.csv') -NoTypeInformation -Encoding UTF8

# -------------------------------------------------------------------- verdict
$winrm    = @($rows | Where-Object { $_.Transport -eq 'WinRM' })
$dcom     = @($rows | Where-Object { $_.Transport -eq 'DCOM' })
$none     = @($rows | Where-Object { $_.Transport -eq 'NONE' -and $_.DNS -eq 'resolves' })
$noDns    = @($rows | Where-Object { $_.DNS -ne 'resolves' })

Write-Host ''
Write-Host ('  ' + ('-' * 70)) -ForegroundColor Cyan
Write-Host '   READINESS' -ForegroundColor Cyan
Write-Host ('  ' + ('-' * 70)) -ForegroundColor Cyan
Write-Host ("   Probed                  : {0}" -f $rows.Count)
Write-Host -NoNewline '   WinRM (full sweep OK)   : '; Write-Host $winrm.Count -ForegroundColor Green
Write-Host -NoNewline '   DCOM only               : '; Write-Host $dcom.Count  -ForegroundColor Yellow
Write-Host -NoNewline '   Nothing answers         : '; Write-Host $none.Count  -ForegroundColor Red
Write-Host -NoNewline '   Name does not resolve   : '; Write-Host $noDns.Count -ForegroundColor DarkYellow
Write-Host ''

$notes.Add("Probed $($rows.Count) target(s): $($winrm.Count) WinRM, $($dcom.Count) DCOM only, $($none.Count) answering nothing, $($noDns.Count) not resolving in DNS.")

if ($winrm.Count -eq 0 -and $rows.Count -gt 0) {
    Write-Host '   NO TARGET ANSWERS WinRM.' -ForegroundColor Red
    Write-Host ''
    Write-Host '   The remote tool sweep needs WinRM and cannot run against any of these.' -ForegroundColor Yellow
    Write-Host '   Either WinRM is not enabled in this estate, or it is blocked between'   -ForegroundColor Yellow
    Write-Host '   this machine and the targets. Enabling it is a change and goes through' -ForegroundColor Yellow
    Write-Host '   change control; it is commonly already set by policy on servers and'    -ForegroundColor Yellow
    Write-Host '   commonly not on workstations.'                                          -ForegroundColor Yellow
    Write-Host ''
    $notes.Add('NO target answered WinRM, so the remote sweep cannot run at all here. DCOM-only targets can still be read by CIM but not by the tool sweep.')
}

if ($none.Count) {
    Write-Host ("   {0} target(s) resolve in DNS and answer NO management transport." -f $none.Count) -ForegroundColor Red
    Write-Host '   That is a finding on its own: nothing is managing those machines.' -ForegroundColor Yellow
    Write-Host ''
    $notes.Add("$($none.Count) target(s) resolve but answer neither WinRM nor DCOM. Report these separately: a machine no management transport reaches is a machine nothing is managing.")
}

if ($noDns.Count) {
    $notes.Add("$($noDns.Count) name(s) do not resolve in DNS. If these came from Active Directory they are most likely STALE COMPUTER OBJECTS rather than unreachable servers, which is housekeeping and not an exposure. Confirm before counting them as either.")
}

Write-FieldkitSummary -Title 'Remote Readiness' -OutputFolder $out -Notes $notes
