<#
    Start-Fieldkit.ps1

    The menu. This is the only file you need to remember.

    ---------------------------------------------------------------------------
    HOW TO RUN IT

        powershell -ExecutionPolicy Bypass -File .\Start-Fieldkit.ps1

    Run it elevated if you can. Some tools work unelevated and say so; the ones
    that need administrator rights are marked in the menu rather than failing
    once you have already started them.

    ---------------------------------------------------------------------------
    WHERE THINGS GO

        C:\work\Fieldkit    the kit itself
        C:\work\Output      one folder per tool run
        C:\work\Logs        what this kit did on this machine, and when

    C:\work is used deliberately. Temp gets cleaned out and Scripts is often
    already in use by the client. A folder called work at the root of C: is
    unambiguous when someone asks six months later what was put on the server.

    ---------------------------------------------------------------------------
    WHAT IT CHANGES

    Nothing, with one exception. Every tool is read-only. The only thing that
    writes to the machine is installing a prerequisite from the prerequisites
    menu, which asks first, shows the exact command, and records it in the log.
#>

[CmdletBinding()]
param(
    # Override only if C:\work is unavailable or the client insists on another
    # location. The default is the point of this kit.
    [string] $WorkRoot
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------- load
$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
try {
    . (Join-Path $here 'Lib\Fieldkit.Common.ps1')
    . (Join-Path $here 'Lib\Fieldkit.Prereqs.ps1')
}
catch {
    Write-Host ''
    Write-Host 'STOP: could not load the Fieldkit library files.' -ForegroundColor Red
    Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    Write-Host '      Start-Fieldkit.ps1 expects Lib\ and Tools\ next to it. If you'  -ForegroundColor Yellow
    Write-Host '      copied only this one file, copy the whole folder instead.'      -ForegroundColor Yellow
    exit 1
}

if ($WorkRoot) {
    $cfg = Get-FieldkitConfig
    $cfg.WorkRoot   = $WorkRoot
    $cfg.KitRoot    = Join-Path $WorkRoot 'Fieldkit'
    $cfg.OutputRoot = Join-Path $WorkRoot 'Output'
    $cfg.LogRoot    = Join-Path $WorkRoot 'Logs'
}

if (-not (Initialize-FieldkitWorkspace)) { exit 1 }

$ErrorActionPreference = 'Continue'
$cfg = Get-FieldkitConfig
Write-FieldkitLog -Level 'INFO' -Message "Fieldkit $($cfg.Version) started from $here"

# --------------------------------------------------------------------------- display
function Get-ToolStatus {
    <#
        Ready, or the name of the first thing it is missing.

        Unknown is kept distinct from missing. A tool whose prerequisite could
        not be checked is not the same as a tool whose prerequisite is absent,
        and the menu should not claim otherwise.
    #>
    param($Tool, $PrereqState)

    $missing = @()
    $unknown = @()
    foreach ($id in $Tool.Requires) {
        if (-not $PrereqState.ContainsKey($id)) { $unknown += $id; continue }
        switch ($PrereqState[$id].State) {
            'Absent'  { $missing += $PrereqState[$id].Name }
            'Unknown' { $unknown += $PrereqState[$id].Name }
        }
    }
    if ($Tool.Elevation -eq 'Required' -and -not (Test-FieldkitElevation)) {
        $missing += 'administrator rights'
    }

    if ($missing.Count) { return [pscustomobject]@{ Ready = $false; Text = 'needs ' + ($missing -join ', '); Color = 'Yellow' } }
    if ($unknown.Count) { return [pscustomobject]@{ Ready = $false; Text = 'cannot check ' + ($unknown -join ', '); Color = 'DarkYellow' } }
    return [pscustomobject]@{ Ready = $true; Text = 'ready'; Color = 'Green' }
}

function Show-MainMenu {
    param($Tools, $PrereqState)

    Clear-Host
    $elev = if (Test-FieldkitElevation) { 'yes' } else { 'NO' }
    $role = Get-FieldkitOSRole

    Write-Host ''
    Write-Host ('  ' + ('=' * 72)) -ForegroundColor Cyan
    Write-Host ("   FIELDKIT {0}" -f $cfg.Version) -ForegroundColor Cyan
    Write-Host ('  ' + ('=' * 72)) -ForegroundColor Cyan
    Write-Host ("   Host      : {0}  ({1})" -f $env:COMPUTERNAME, $role)
    Write-Host ("   Account   : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
    Write-Host -NoNewline '   Elevated  : '
    Write-Host $elev -ForegroundColor $(if ($elev -eq 'yes') { 'Green' } else { 'Yellow' })
    Write-Host ("   Work root : {0}" -f $cfg.WorkRoot)
    Write-Host ''

    if (-not $Tools -or $Tools.Count -eq 0) {
        Write-Host '   No tools found in Tools\.' -ForegroundColor Yellow
        Write-Host '   Drop a .ps1 file in there and it appears here on the next refresh.'
        Write-Host ''
        return @{}
    }

    $index = @{}
    $n = 0
    foreach ($cat in ($Tools | Select-Object -ExpandProperty Category -Unique | Sort-Object)) {
        Write-Host ("   {0}" -f $cat.ToUpper()) -ForegroundColor White
        foreach ($t in ($Tools | Where-Object { $_.Category -eq $cat } | Sort-Object Name)) {
            $n++
            $index[$n] = $t
            $st = Get-ToolStatus -Tool $t -PrereqState $PrereqState
            Write-Host ("    {0,2}  " -f $n) -NoNewline
            Write-Host ("[{0}]" -f $st.Text) -ForegroundColor $st.Color -NoNewline
            Write-Host ("  {0}" -f $t.Name)
            if ($t.Summary -and $t.Summary -ne '(no description in file)') {
                Write-Host ("         {0}" -f $t.Summary) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
    }

    Write-Host '   ---------------------------------------------------------------------'
    Write-Host '    number   run that tool'
    Write-Host '    P        prerequisites: check what is here, install what is not'
    Write-Host '    F        force-run a tool, skipping the prerequisite check'
    Write-Host '    I        information about a tool, without running it'
    Write-Host '    O        open the output folder'
    Write-Host '    L        show this machine''s Fieldkit log'
    Write-Host '    R        refresh (re-read Tools\ and re-check prerequisites)'
    Write-Host '    U        update the kit from GitHub'
    Write-Host '    Q        quit'
    Write-Host ''
    return $index
}

# --------------------------------------------------------------------------- actions
function Invoke-FieldkitTool {
    param($Tool, [switch] $SkipPrereqCheck)

    Write-Host ''
    if ($SkipPrereqCheck) {
        Write-Host '  Running WITHOUT the prerequisite check.' -ForegroundColor Yellow
        Write-Host '  If something it depends on is missing, the failure will come from' -ForegroundColor Yellow
        Write-Host '  the tool itself and may be less clear than the check would be.'    -ForegroundColor Yellow
        Write-Host ''
        Write-FieldkitLog -Level 'RUN' -Message "FORCED (no prereq check) $($Tool.File)"
    }
    else {
        Write-FieldkitLog -Level 'RUN' -Message "START $($Tool.File)"
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Tool.Path
        $sw.Stop()
        Write-Host ''
        Write-Host ("  Finished in {0:N1} seconds." -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
        Write-FieldkitLog -Level 'RUN' -Message ("END   {0}  {1:N1}s" -f $Tool.File, $sw.Elapsed.TotalSeconds)
    }
    catch {
        $sw.Stop()
        Write-Host ''
        Write-Host "  The tool stopped with an error:" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        Write-Host '  Whatever it wrote before stopping is still in the output folder.' -ForegroundColor Yellow
        Write-Host '  A partial result is evidence of how far it got, so keep it.'      -ForegroundColor Yellow
        Write-FieldkitLog -Level 'ERROR' -Message "FAIL  $($Tool.File): $($_.Exception.Message)"
    }
    Write-Host ''
    Read-Host '  Press Enter to return to the menu' | Out-Null
}

function Invoke-ToolWithPrereqGate {
    param($Tool, $PrereqState)

    $st = Get-ToolStatus -Tool $Tool -PrereqState $PrereqState
    if ($st.Ready) { Invoke-FieldkitTool -Tool $Tool; return $true }

    Write-Host ''
    Write-Host ("  {0} is not ready: {1}" -f $Tool.Name, $st.Text) -ForegroundColor Yellow
    Write-Host ''

    # Offer the partner installer for each missing prerequisite, in order.
    $installable = @()
    foreach ($id in $Tool.Requires) {
        if ($PrereqState.ContainsKey($id) -and $PrereqState[$id].State -ne 'Present') {
            $installable += $PrereqState[$id]
        }
    }

    foreach ($p in $installable) {
        Write-Host ("   {0}  ({1})" -f $p.Name, $p.State)
        if ($p.Prereq.Why) { Write-Host ("     needed for: {0}" -f $p.Prereq.Why) -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-Host '    I   install what is missing, then come back here'
    Write-Host '    R   run it anyway, without the check'
    Write-Host '    B   back to the menu'
    Write-Host ''
    $choice = (Read-Host '  Choice').Trim().ToUpper()

    switch ($choice) {
        'I' {
            foreach ($p in $installable) { $null = Install-FieldkitPrereq -Prereq $p.Prereq }
            Write-Host ''
            Read-Host '  Press Enter to return to the menu' | Out-Null
            return $true   # caller refreshes state
        }
        'R' { Invoke-FieldkitTool -Tool $Tool -SkipPrereqCheck; return $true }
        default { return $false }
    }
}

function Show-PrereqMenu {
    while ($true) {
        $state = Get-FieldkitPrereqState
        Clear-Host
        Write-Host ''
        Write-Host '   PREREQUISITES' -ForegroundColor Cyan
        Write-Host ("   Machine role: {0}" -f (Get-FieldkitOSRole))
        Write-Host ''

        $ids = @($state.Keys | Sort-Object)
        $i = 0; $map = @{}
        foreach ($id in $ids) {
            $i++; $map[$i] = $state[$id]
            $color = switch ($state[$id].State) {
                'Present' { 'Green' }
                'Absent'  { 'Yellow' }
                default   { 'DarkYellow' }
            }
            # Not everything in the catalog is installable. Elevation is a
            # property of the session, and calling it "not installed" sends
            # someone looking for a package that does not exist.
            $canInstall = [bool]($state[$id].Prereq.InstallServer -or $state[$id].Prereq.InstallClient)
            $label = switch ($state[$id].State) {
                'Present' { 'present' }
                'Absent'  { if ($canInstall) { 'NOT INSTALLED' } else { 'NOT PRESENT' } }
                default   { 'COULD NOT CHECK' }
            }
            Write-Host ("    {0,2}  " -f $i) -NoNewline
            Write-Host ("{0,-16}" -f $label) -ForegroundColor $color -NoNewline
            Write-Host ("  {0}" -f $state[$id].Name)
            if ($state[$id].Prereq.Notes) {
                Write-Host ("        {0}" -f $state[$id].Prereq.Notes) -ForegroundColor DarkGray
            }
        }

        # On a workstation, RSAT comes from Windows Update as a Feature on
        # Demand. Whether that can work is knowable in advance, and finding out
        # here is much cheaper than finding out from 0x800f0954.
        if ((Get-FieldkitOSRole) -eq 'Workstation') {
            $fod = Test-FieldkitFodSource
            Write-Host ''
            Write-Host -NoNewline '   RSAT / optional feature source: '
            switch ($fod.State) {
                'Ready'   { Write-Host 'OK' -ForegroundColor Green }
                'Blocked' { Write-Host 'BLOCKED' -ForegroundColor Red }
                default   { Write-Host 'COULD NOT DETERMINE' -ForegroundColor DarkYellow }
            }
            Write-Host ("   $($fod.Reason)") -ForegroundColor DarkGray
            if ($fod.State -eq 'Blocked') {
                Write-Host ''
                Write-Host '   Installing RSAT here will fail with 0x800f0954 until that policy' -ForegroundColor Yellow
                Write-Host '   is changed. Carrying the module in from another machine is often'  -ForegroundColor Yellow
                Write-Host '   faster than getting the change approved.'                          -ForegroundColor Yellow
            }
        }

        Write-Host ''
        Write-Host '   COULD NOT CHECK is not the same as NOT INSTALLED. It means the' -ForegroundColor DarkGray
        Write-Host '   detection itself failed, so nothing is known either way.'       -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    number  install that prerequisite (asks first, shows the command)'
        Write-Host '    B       back'
        Write-Host ''
        $c = (Read-Host '  Choice').Trim()
        if ($c -match '^[Bb]$' -or $c -eq '') { return }
        $num = 0
        if ([int]::TryParse($c, [ref]$num) -and $map.ContainsKey($num)) {
            $null = Install-FieldkitPrereq -Prereq $map[$num].Prereq
            Write-Host ''
            Read-Host '  Press Enter to continue' | Out-Null
        }
    }
}

function Show-ToolInfo {
    param($Tool)
    Clear-Host
    Write-Host ''
    Write-Host ("   {0}" -f $Tool.Name) -ForegroundColor Cyan
    Write-Host ''
    Write-Host ("   File       : {0}" -f $Tool.File)
    Write-Host ("   Category   : {0}" -f $Tool.Category)
    Write-Host ("   Scope      : {0}" -f $Tool.Scope)
    Write-Host ("   Elevation  : {0}" -f $Tool.Elevation)
    Write-Host ("   Read-only  : {0}" -f $Tool.ReadOnly)
    Write-Host ("   Requires   : {0}" -f $(if ($Tool.Requires.Count) { $Tool.Requires -join ', ' } else { 'nothing' }))
    Write-Host ("   Output to  : {0}\{1}-..." -f $cfg.OutputRoot, $Tool.Output)
    Write-Host ''
    Write-Host ("   {0}" -f $Tool.Summary)
    Write-Host ''
    if (-not $Tool.Documented) {
        Write-Host '   This tool has no FIELDKIT header block, so most of the above is a' -ForegroundColor Yellow
        Write-Host '   guess from the file name. See Docs\ADDING-A-TOOL.md.'             -ForegroundColor Yellow
        Write-Host ''
    }
    Read-Host '  Press Enter to return to the menu' | Out-Null
}

function Update-Fieldkit {
    $boot = Join-Path $here 'Get-Fieldkit.ps1'
    Write-Host ''
    if (Test-Path -LiteralPath $boot) {
        Write-Host '  Re-downloading the kit over the top of this copy.' -ForegroundColor Cyan
        Write-Host '  Output in C:\work\Output is not touched.'          -ForegroundColor Cyan
        Write-Host ''
        & $boot -Update
    }
    else {
        Write-Host '  Get-Fieldkit.ps1 is not next to this script, so there is nothing' -ForegroundColor Yellow
        Write-Host '  to update from. Download the kit again by hand.'                   -ForegroundColor Yellow
    }
    Write-Host ''
    Read-Host '  Press Enter to continue' | Out-Null
}

# --------------------------------------------------------------------------- loop
$tools  = Get-FieldkitTool -ToolsPath (Join-Path $here 'Tools')
$pstate = Get-FieldkitPrereqState

while ($true) {
    $index = Show-MainMenu -Tools $tools -PrereqState $pstate
    $choice = (Read-Host '  Choice').Trim()

    if ($choice -eq '') { continue }

    switch -Regex ($choice) {
        '^[Qq]$' {
            Write-FieldkitLog -Level 'INFO' -Message 'Fieldkit closed'
            Write-Host ''
            Write-Host ("  Output is in {0}" -f $cfg.OutputRoot) -ForegroundColor Green
            Write-Host ("  Log is in    {0}" -f $cfg.LogRoot)    -ForegroundColor Green
            Write-Host ''
            return
        }
        '^[Pp]$' { Show-PrereqMenu; $pstate = Get-FieldkitPrereqState; continue }
        '^[Rr]$' {
            $tools  = Get-FieldkitTool -ToolsPath (Join-Path $here 'Tools')
            $pstate = Get-FieldkitPrereqState
            continue
        }
        '^[Uu]$' {
            Update-Fieldkit
            $tools  = Get-FieldkitTool -ToolsPath (Join-Path $here 'Tools')
            $pstate = Get-FieldkitPrereqState
            continue
        }
        '^[Oo]$' {
            Start-Process explorer.exe $cfg.OutputRoot
            continue
        }
        '^[Ll]$' {
            $f = Join-Path $cfg.LogRoot ('Fieldkit-{0}-{1}.log' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd'))
            Clear-Host
            Write-Host ''
            if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f | ForEach-Object { Write-Host "   $_" } }
            else { Write-Host '   No log entries for today on this machine.' -ForegroundColor Yellow }
            Write-Host ''
            Read-Host '  Press Enter to return to the menu' | Out-Null
            continue
        }
        '^[FfIi]$' {
            $verb = if ($choice -match '^[Ff]$') { 'force-run' } else { 'describe' }
            Write-Host ''
            $t = (Read-Host "  Which tool number to $verb").Trim()
            $num = 0
            if ([int]::TryParse($t, [ref]$num) -and $index.ContainsKey($num)) {
                if ($verb -eq 'force-run') { Invoke-FieldkitTool -Tool $index[$num] -SkipPrereqCheck }
                else { Show-ToolInfo -Tool $index[$num] }
            }
            continue
        }
        '^\d+$' {
            $num = [int]$choice
            if ($index.ContainsKey($num)) {
                $null = Invoke-ToolWithPrereqGate -Tool $index[$num] -PrereqState $pstate
                $pstate = Get-FieldkitPrereqState
            }
            continue
        }
        default { continue }
    }
}
