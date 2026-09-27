<#
    Fieldkit.Common.ps1

    Shared plumbing for the Fieldkit menu and every tool it runs.

    Dot-source it. It defines functions and one configuration object and does
    nothing else on load, so it is safe to load from anywhere.

    Written for Windows PowerShell 5.1, because that is what a client domain
    controller has. Nothing here requires PowerShell 7.
#>

# --------------------------------------------------------------------------
# One place that decides where everything lives.
#
# C:\work is deliberate. Temp gets cleaned, Scripts is often already in use by
# the client, and a folder called "work" at the root of C: is unambiguous when
# someone asks later what was put on the machine.
# --------------------------------------------------------------------------
$script:FieldkitConfig = [pscustomobject]@{
    WorkRoot   = 'C:\work'
    KitRoot    = 'C:\work\Fieldkit'
    OutputRoot = 'C:\work\Output'
    LogRoot    = 'C:\work\Logs'
    Version    = '1.1.0'
}

function Get-FieldkitConfig { $script:FieldkitConfig }

function Test-FieldkitElevation {
    <# Is this session running as administrator? #>
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal] $id).IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-FieldkitOSRole {
    <#
        Workstation, Server or DomainController.

        This decides which installer a prerequisite uses, and getting it wrong
        means offering Install-WindowsFeature on a laptop, where it does not
        exist. Returns 'Unknown' rather than guessing if the query fails.
    #>
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        switch ($os.ProductType) {
            1 { return 'Workstation' }
            2 { return 'DomainController' }
            3 { return 'Server' }
            default { return 'Unknown' }
        }
    }
    catch { return 'Unknown' }
}

function Initialize-FieldkitWorkspace {
    <#
        Create C:\work and its subfolders, and prove they are writable before
        anything relies on them.

        Returns $true on success. On failure it explains which path failed and
        why, because "access denied" three screens into a collection is a much
        worse place to find out.
    #>
    $cfg = Get-FieldkitConfig
    foreach ($p in @($cfg.WorkRoot, $cfg.OutputRoot, $cfg.LogRoot)) {
        try {
            if (-not (Test-Path -LiteralPath $p)) {
                $null = New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop
            }
            $probe = Join-Path $p '.fieldkit-write-test'
            'ok' | Set-Content -LiteralPath $probe -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host ''
            Write-Host "STOP: cannot use $p" -ForegroundColor Red
            Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ''
            Write-Host '      Either this account cannot write to the root of C:, or the' -ForegroundColor Yellow
            Write-Host '      drive is full or read-only. Nothing has been collected.'   -ForegroundColor Yellow
            return $false
        }
    }
    return $true
}

function Write-FieldkitLog {
    <#
        Append one line to the session log.

        Every tool run and every prerequisite install goes through here. The
        log is the record of what this kit did on a machine that is not yours,
        which is the answer to "what did you put on our server".
    #>
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO','RUN','CHANGE','WARN','ERROR')] [string] $Level = 'INFO'
    )
    $cfg  = Get-FieldkitConfig
    $line = '{0}  {1,-6}  {2}\{3}  {4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
                                           $Level, $env:USERDOMAIN, $env:USERNAME, $Message
    try {
        $file = Join-Path $cfg.LogRoot ('Fieldkit-{0}-{1}.log' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd'))
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # A log that cannot be written must not stop the work, but it must not
        # be silent about it either.
        Write-Host "  (log write failed: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

function New-FieldkitOutputFolder {
    <#
        One folder per tool run, named so that two runs never collide and so
        the folder says what it is without opening it.

        C:\work\Output\ADHealth-DC02-2026-09-25-1412\
    #>
    param(
        [Parameter(Mandatory)] [string] $ToolOutputName
    )
    $cfg   = Get-FieldkitConfig
    $stamp = Get-Date -Format 'yyyy-MM-dd-HHmm'
    $dir   = Join-Path $cfg.OutputRoot ('{0}-{1}-{2}' -f $ToolOutputName, $env:COMPUTERNAME, $stamp)
    $null  = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
    return $dir
}

function Get-FieldkitToolMetadata {
    <#
        Read the FIELDKIT header block out of a tool script.

        This READS the file. It never dot-sources or executes it, because the
        menu must be able to describe a tool without running it.

        A tool with no header block still appears in the menu, marked as
        undocumented, rather than being silently hidden.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $meta = [ordered]@{
        Path       = $Path
        File       = Split-Path $Path -Leaf
        Name       = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        Category   = 'Uncategorized'
        Summary    = '(no description in file)'
        Requires   = @()
        Elevation  = 'Unknown'
        Scope      = 'Unknown'
        Output     = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        ReadOnly   = 'Unknown'
        Documented = $false
    }

    try { $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop }
    catch { return [pscustomobject]$meta }

    $m = [regex]::Match($text, '(?s)<\#FIELDKIT(.*?)FIELDKIT\#>')
    if (-not $m.Success) { return [pscustomobject]$meta }

    $meta.Documented = $true
    foreach ($line in ($m.Groups[1].Value -split "`r?`n")) {
        if ($line -notmatch '^\s*([A-Za-z]+)\s*:\s*(.*?)\s*$') { continue }
        $key = $Matches[1]; $val = $Matches[2]
        switch ($key) {
            'Name'      { $meta.Name      = $val }
            'Category'  { $meta.Category  = $val }
            'Summary'   { $meta.Summary   = $val }
            'Elevation' { $meta.Elevation = $val }
            'Scope'     { $meta.Scope     = $val }
            'Output'    { $meta.Output    = $val }
            'ReadOnly'  { $meta.ReadOnly  = $val }
            'Requires'  {
                if ($val -and $val -ne 'None') {
                    $meta.Requires = @($val -split ',' | ForEach-Object { $_.Trim() } |
                                       Where-Object { $_ })
                }
            }
        }
    }
    return [pscustomobject]$meta
}

function Get-FieldkitTool {
    <# Every tool in Tools\, read from disk each time so a new file appears
       in the menu without editing the menu. #>
    param(
        [string] $ToolsPath
    )
    if (-not $ToolsPath) { $ToolsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Tools' }
    if (-not (Test-Path -LiteralPath $ToolsPath)) { return @() }

    $files = @(Get-ChildItem -LiteralPath $ToolsPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
               Sort-Object Name)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) { $out.Add((Get-FieldkitToolMetadata -Path $f.FullName)) }
    return $out
}

function Confirm-FieldkitChange {
    <#
        Anything that changes the machine stops here first.

        This kit is read-only apart from installing prerequisites, and an
        install on a client's server is a real change to a machine that is not
        yours. It requires typing the word, not pressing Y, because Y is what
        fingers do on their own.
    #>
    param(
        [Parameter(Mandatory)] [string] $What,
        [Parameter(Mandatory)] [string] $Command
    )
    Write-Host ''
    Write-Host '  THIS CHANGES THE MACHINE' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  Change  : $What"
    Write-Host "  Command : $Command"
    Write-Host "  Host    : $env:COMPUTERNAME"
    Write-Host "  Account : $env:USERDOMAIN\$env:USERNAME"
    Write-Host ''
    Write-Host '  Everything else in this kit is read-only. This is not. It will be' -ForegroundColor Yellow
    Write-Host '  written to the session log so you can tell the client what you did.' -ForegroundColor Yellow
    Write-Host ''
    $answer = Read-Host '  Type INSTALL to proceed, anything else to cancel'
    return ($answer -ceq 'INSTALL')
}

function Invoke-FieldkitSection {
    <#
        Run one collection step, write its CSV, and report honestly.

        THIS IS THE MOST IMPORTANT FUNCTION IN THE KIT.

        There are three outcomes, and a collection script that reports only two
        of them produces wrong findings:

          rows      the question was asked and answered
          no rows   the question was asked and the answer is empty
          NOT READ  the question was never answered, because the query failed

        An absent result read as a clean result is the classic way an audit
        reports that something is fine when in truth nobody looked. Every
        NOT READ is carried into the summary file so it cannot be missed by
        someone reading only the output folder.
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $OutputFolder,
        [Parameter(Mandatory)] [scriptblock] $Body,
        $Notes
    )

    Write-Host ("  {0,-44} " -f $Name) -NoNewline
    try {
        $rows = @(& $Body)
        if ($rows.Count -eq 0) {
            Write-Host 'no rows' -ForegroundColor DarkYellow
            if ($Notes) { $Notes.Add("EMPTY     $Name - the query ran and returned nothing.") }
            return
        }
        $safe = ($Name -replace '[^A-Za-z0-9]+', '-').Trim('-')
        $file = Join-Path $OutputFolder ($safe + '.csv')
        $rows | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Write-Host ("{0} rows" -f $rows.Count) -ForegroundColor Green
    }
    catch {
        Write-Host 'NOT READ' -ForegroundColor Red
        Write-Host ("      {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
        if ($Notes) { $Notes.Add("NOT READ  $Name - $($_.Exception.Message)") }
    }
}

function Write-FieldkitSummary {
    <#
        Write SUMMARY.txt, ending with anything that was NOT READ.

        The summary is what gets read first and sometimes only, so the gaps
        belong in it, not just in the console scrollback of a session that
        closed two days ago.
    #>
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $OutputFolder,
        [Parameter(Mandatory)] $Notes
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($Title)
    $lines.Add(('=' * $Title.Length))
    $lines.Add('')
    $lines.Add("Host        : $env:COMPUTERNAME")
    $lines.Add("Account     : $env:USERDOMAIN\$env:USERNAME")
    $lines.Add("Elevated    : $(if (Test-FieldkitElevation) { 'yes' } else { 'no' })")
    $lines.Add("Collected   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
    $lines.Add("Output      : $OutputFolder")
    $lines.Add('')

    $failed = @($Notes | Where-Object { $_ -like 'NOT READ*' })
    $empty  = @($Notes | Where-Object { $_ -like 'EMPTY*' })
    $other  = @($Notes | Where-Object { $_ -notlike 'NOT READ*' -and $_ -notlike 'EMPTY*' })

    if ($other.Count) {
        $lines.Add('NOTES')
        $lines.Add('-----')
        foreach ($n in $other) { $lines.Add("  $n") }
        $lines.Add('')
    }

    if ($empty.Count) {
        $lines.Add('RAN, RETURNED NOTHING')
        $lines.Add('---------------------')
        $lines.Add('These are real answers. Empty means empty.')
        $lines.Add('')
        foreach ($n in $empty) { $lines.Add("  $n") }
        $lines.Add('')
    }

    if ($failed.Count) {
        $lines.Add('NOT MEASURED')
        $lines.Add('------------')
        $lines.Add('These did NOT run. Do not read their absence as a clean result.')
        $lines.Add('The usual causes are missing rights, a missing module, or a')
        $lines.Add('service that is not present on this machine.')
        $lines.Add('')
        foreach ($n in $failed) { $lines.Add("  $n") }
        $lines.Add('')
    }
    else {
        $lines.Add('Every section ran. Nothing was skipped.')
        $lines.Add('')
    }

    $path = Join-Path $OutputFolder 'SUMMARY.txt'
    ($lines -join "`r`n") | Set-Content -LiteralPath $path -Encoding UTF8

    Write-Host ''
    if ($failed.Count) {
        Write-Host ("  {0} section(s) did NOT run. See SUMMARY.txt." -f $failed.Count) -ForegroundColor Red
    }
    Write-Host ("  Written to: {0}" -f $OutputFolder) -ForegroundColor Green
}

function Write-FieldkitHeader {
    <# The banner every tool prints, so its output identifies itself. #>
    param(
        [Parameter(Mandatory)] [string] $Title,
        [string] $OutputFolder
    )
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor Cyan
    Write-Host ("  Host    : {0}" -f $env:COMPUTERNAME)
    Write-Host ("  Account : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
    Write-Host ("  Time    : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
    if ($OutputFolder) { Write-Host ("  Output  : {0}" -f $OutputFolder) }
    Write-Host ''
}
