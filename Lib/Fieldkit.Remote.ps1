<#
    Fieldkit.Remote.ps1

    Running a tool against systems other than this one.

    ---------------------------------------------------------------------------
    THE RULE THAT SHAPES ALL OF THIS

    With one machine, a failed section is obvious: it says NOT READ on the
    screen in front of you.

    With two hundred machines it is not obvious at all, and the failure mode is
    specific and bad: "we assessed 200 servers and found three problems", when
    in truth 150 were never reached and the three problems are all that exists
    among the 50 that answered.

    So COVERAGE COMES FIRST. Every report leads with how many targets were
    reached, how many were not, and why not. A target that could not be
    contacted is a first-class result, not a gap in a table. An estate where a
    third of the servers cannot be reached by any management transport has
    already told you something more important than anything the other two
    thirds will say.

    ---------------------------------------------------------------------------
    NOTHING IS WRITTEN TO A TARGET

    Tools run on the target through Fieldkit.RemoteShim.ps1, which returns
    objects instead of writing files. No folder is created, nothing is copied
    back, nothing is cleaned up. The console writes every file.

    ---------------------------------------------------------------------------
    CREDENTIALS

    WinRM with Kerberos is the default and it does NOT leave reusable
    credentials on the target. CredSSP does, so it is not offered here at all
    and should not be added. If you find yourself wanting it, the answer is
    almost always a different tool rather than delegated credentials on a
    client's server.
#>

# --------------------------------------------------------------------- targets

function Get-FieldkitTarget {
    <#
        Build the target list.

        Three sources, and the AD one is gated because it is the one that can
        quietly reach a machine nobody meant to touch. On an estate with
        laboratory instrument controllers or other fragile embedded systems,
        "everything in the directory" is the wrong default and there is no
        configuration of it that is right.
    #>
    param(
        [string[]] $ComputerName,
        [string]   $InputFile,
        [switch]   $FromAD,
        [string]   $ADFilter = 'Enabled -eq $true',
        [string]   $ExcludeFile,
        [string[]] $Exclude
    )

    $targets = [System.Collections.Generic.List[object]]::new()
    $source  = ''

    if ($ComputerName) {
        $source = 'explicit -ComputerName'
        # Split on commas and semicolons as well as taking the array as given.
        #
        # Invoked as "powershell.exe -File tool.ps1 -ComputerName A,B,C" - which
        # is how the README tells people to run these - PowerShell does NOT
        # split on the commas. The whole thing arrives as ONE string and
        # silently becomes a single nonexistent hostname, which then reports as
        # "DNS does not resolve" and looks like a network problem. Splitting
        # here costs nothing and removes a confusing failure.
        foreach ($c in $ComputerName) {
            foreach ($piece in ($c -split '[,;]')) {
                $t = $piece.Trim()
                if ($t) { $targets.Add($t) }
            }
        }
    }
    elseif ($InputFile) {
        if (-not (Test-Path -LiteralPath $InputFile)) {
            throw "Target file not found: $InputFile"
        }
        $source = "file $InputFile"
        # Accept a plain list or a CSV with a Name / ComputerName / DNSHostName
        # column, because both are what an export actually looks like.
        $raw = Get-Content -LiteralPath $InputFile -ErrorAction Stop
        if ($raw -and $raw[0] -match ',') {
            $csv = Import-Csv -LiteralPath $InputFile
            $col = @('ComputerName','DNSHostName','Name','HostName','Computer') |
                   Where-Object { $csv[0].PSObject.Properties.Name -contains $_ } |
                   Select-Object -First 1
            if (-not $col) { throw "Could not find a ComputerName, DNSHostName, Name, HostName or Computer column in $InputFile" }
            foreach ($r in $csv) { if ($r.$col) { $targets.Add(([string]$r.$col).Trim()) } }
        }
        else {
            foreach ($l in $raw) {
                $t = $l.Trim()
                if ($t -and $t -notmatch '^\s*#') { $targets.Add($t) }
            }
        }
    }
    elseif ($FromAD) {
        $source = "Active Directory, filter: $ADFilter"
        Import-Module ActiveDirectory -ErrorAction Stop
        $found = @(Get-ADComputer -Filter $ADFilter -Properties DNSHostName, OperatingSystem -ErrorAction Stop)
        foreach ($c in $found) {
            $targets.Add($(if ($c.DNSHostName) { $c.DNSHostName } else { $c.Name }))
        }
    }
    else {
        throw 'No targets given. Supply -ComputerName, -InputFile, or -FromAD.'
    }

    # ------------------------------------------------------------- exclusions
    $excluded = [System.Collections.Generic.List[object]]::new()
    $patterns = [System.Collections.Generic.List[string]]::new()
    if ($Exclude)     { foreach ($e in $Exclude) { $patterns.Add($e.Trim()) } }
    if ($ExcludeFile) {
        if (-not (Test-Path -LiteralPath $ExcludeFile)) {
            throw "Exclusion file not found: $ExcludeFile. Refusing to continue, because an exclusion list that silently does not exist is worse than none."
        }
        foreach ($l in (Get-Content -LiteralPath $ExcludeFile)) {
            $t = $l.Trim()
            if ($t -and $t -notmatch '^\s*#') { $patterns.Add($t) }
        }
    }

    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($t in ($targets | Sort-Object -Unique)) {
        $hit = $null
        foreach ($p in $patterns) {
            # Wildcards are supported, because exclusions are usually a naming
            # convention rather than a list of names.
            if ($t -like $p) { $hit = $p; break }
        }
        if ($hit) { $excluded.Add([pscustomobject]@{ Target = $t; MatchedPattern = $hit }) }
        else      { $kept.Add($t) }
    }

    [pscustomobject]@{
        Source        = $source
        Targets       = @($kept)
        Excluded      = @($excluded)
        Patterns      = @($patterns)
        RequiresGate  = [bool]$FromAD
    }
}

function Confirm-FieldkitTargetList {
    <#
        The gate in front of AD-derived targeting.

        It prints the count, the exclusions that fired, and a sample, then
        requires the word to be typed. An explicit list supplied by hand does
        not need this; a list the tool built for you does.
    #>
    param(
        [Parameter(Mandatory)] $TargetSet,
        [string] $Action = 'contact'
    )

    Write-Host ''
    Write-Host '  TARGET LIST' -ForegroundColor Cyan
    Write-Host "  Source   : $($TargetSet.Source)"
    Write-Host "  Resolved : $($TargetSet.Targets.Count + $TargetSet.Excluded.Count)"
    if ($TargetSet.Excluded.Count) {
        Write-Host "  Excluded : $($TargetSet.Excluded.Count) by $($TargetSet.Patterns.Count) pattern(s)" -ForegroundColor Yellow
        foreach ($e in ($TargetSet.Excluded | Select-Object -First 10)) {
            Write-Host ("             {0}  (matched {1})" -f $e.Target, $e.MatchedPattern) -ForegroundColor DarkGray
        }
        if ($TargetSet.Excluded.Count -gt 10) {
            Write-Host ("             ... and {0} more" -f ($TargetSet.Excluded.Count - 10)) -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host '  Excluded : none' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host ("  WILL {0} {1} SYSTEM(S)" -f $Action.ToUpper(), $TargetSet.Targets.Count) -ForegroundColor Yellow
    Write-Host ''
    $sample = @($TargetSet.Targets | Select-Object -First 8)
    Write-Host ("  Sample: {0}" -f ($sample -join ', '))
    if ($TargetSet.Targets.Count -gt 8) {
        Write-Host ("          (+{0} more)" -f ($TargetSet.Targets.Count - 8))
    }

    if ($TargetSet.Targets.Count -eq 0) {
        Write-Host ''
        Write-Host '  Nothing left to contact after exclusions. Stopping.' -ForegroundColor Yellow
        return $false
    }

    if (-not $TargetSet.RequiresGate) { return $true }

    Write-Host ''
    Write-Host '  This list was built from Active Directory rather than supplied by you.' -ForegroundColor Yellow
    Write-Host '  Check it before continuing. Anything fragile - instrument'              -ForegroundColor Yellow
    Write-Host '  controllers, embedded systems, appliances - belongs in an exclusion'    -ForegroundColor Yellow
    Write-Host '  file, not in this list.'                                                -ForegroundColor Yellow
    Write-Host ''
    $answer = Read-Host "  Type CONTACT to proceed, anything else to cancel"
    if ($answer -ceq 'CONTACT') { return $true }
    Write-Host '  Cancelled. Nothing was contacted.' -ForegroundColor Green
    return $false
}

# ---------------------------------------------------------------- reachability

function Test-FieldkitReachability {
    <#
        Can this target be reached at all, and by what?

        This is worth running before any sweep, and its output is a finding in
        its own right rather than only a prerequisite. A production server that
        answers neither WinRM nor DCOM is a server that nobody is managing with
        anything, and that is usually news.

        Order matters: DNS first, because a name that does not resolve is a
        stale directory entry rather than an unreachable machine, and those are
        very different findings.
    #>
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [pscredential] $Credential,
        [int] $TimeoutSeconds = 5,
        [switch] $SkipPortTest
    )

    $r = [ordered]@{
        Target       = $ComputerName
        DNS          = 'not tested'
        IPAddress    = ''
        Port5985     = 'not tested'
        Port5986     = 'not tested'
        Port135      = 'not tested'
        WinRM        = 'not tested'
        DCOM         = 'not tested'
        Transport    = 'NONE'
        OS           = ''
        Reachable    = $false
        Detail       = ''
    }

    # ---- DNS
    try {
        $dns = @(Resolve-DnsName -Name $ComputerName -ErrorAction Stop |
                 Where-Object { $_.IPAddress } | Select-Object -First 1)
        if ($dns) { $r.DNS = 'resolves'; $r.IPAddress = $dns[0].IPAddress }
        else      { $r.DNS = 'NO ADDRESS RECORD' }
    }
    catch {
        $r.DNS    = 'DOES NOT RESOLVE'
        $r.Detail = "DNS: $($_.Exception.Message)"
        $r.Transport = 'NONE'
        return [pscustomobject]$r
    }

    # ---- ports. A single TCP connect to a named host on a known management
    #      port. Not a scan, but it is still a packet, so it can be skipped for
    #      targets where even that is unwelcome.
    if (-not $SkipPortTest) {
        foreach ($p in @(5985, 5986, 135)) {
            $key = "Port$p"
            try {
                $t = Test-NetConnection -ComputerName $ComputerName -Port $p `
                        -WarningAction SilentlyContinue -ErrorAction Stop
                $r.$key = if ($t.TcpTestSucceeded) { 'open' } else { 'closed/filtered' }
            }
            catch { $r.$key = 'test failed' }
        }
    }

    # ---- WinRM. The port being open is not the same as authentication working.
    if ($SkipPortTest -or $r.Port5985 -eq 'open' -or $r.Port5986 -eq 'open') {
        try {
            $p = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
            if ($Credential) { $p['Credential'] = $Credential }
            $null = Test-WSMan @p
            $r.WinRM = 'responds'
            $r.Transport = 'WinRM'
        }
        catch {
            $r.WinRM = 'NO'
            if (-not $r.Detail) { $r.Detail = "WinRM: $($_.Exception.Message)" }
        }
    }
    else {
        $r.WinRM = 'not tried (ports closed)'
    }

    # ---- DCOM fallback, which often works where WinRM was never enabled.
    if ($r.Transport -eq 'NONE') {
        $sess = $null
        try {
            $p = @{
                ComputerName  = $ComputerName
                SessionOption = (New-CimSessionOption -Protocol Dcom)
                ErrorAction   = 'Stop'
                OperationTimeoutSec = $TimeoutSeconds
            }
            if ($Credential) { $p['Credential'] = $Credential }
            $sess = New-CimSession @p
            $os = Get-CimInstance -CimSession $sess -ClassName Win32_OperatingSystem -ErrorAction Stop
            $r.DCOM = 'responds'
            $r.Transport = 'DCOM'
            $r.OS = $os.Caption
        }
        catch {
            $r.DCOM = 'NO'
            if (-not $r.Detail) { $r.Detail = "DCOM: $($_.Exception.Message)" }
        }
        finally { if ($sess) { Remove-CimSession $sess -ErrorAction SilentlyContinue } }
    }

    # If WinRM worked, get the OS through it so the row is complete either way.
    if ($r.Transport -eq 'WinRM' -and -not $r.OS) {
        try {
            $p = @{ ComputerName = $ComputerName; ErrorAction = 'Stop'
                    ScriptBlock = { (Get-CimInstance Win32_OperatingSystem).Caption } }
            if ($Credential) { $p['Credential'] = $Credential }
            $r.OS = Invoke-Command @p
        }
        catch { }
    }

    $r.Reachable = ($r.Transport -ne 'NONE')
    [pscustomobject]$r
}

# -------------------------------------------------------------------- payload

function New-FieldkitPayload {
    <#
        Compose what gets shipped: the shim, then the tool's own text with its
        local dot-source removed.

        The tool is not modified on disk and not rewritten. Its dot-source line
        is stripped because the real library is not present on the target and
        must not be; the shim has already defined those names.
    #>
    param(
        [Parameter(Mandatory)] [string] $ToolPath,
        [Parameter(Mandatory)] [string] $ShimPath,
        [int] $MaxRows = 5000
    )

    if (-not (Test-Path -LiteralPath $ToolPath)) { throw "Tool not found: $ToolPath" }
    if (-not (Test-Path -LiteralPath $ShimPath)) { throw "Remote shim not found: $ShimPath" }

    $shim = Get-Content -LiteralPath $ShimPath -Raw -ErrorAction Stop
    $tool = Get-Content -LiteralPath $ToolPath -Raw -ErrorAction Stop

    # Remove the dot-source of the local library. Anchored to the known form so
    # it cannot quietly match something else in the file.
    $pattern = '(?m)^\s*\.\s+\(Join-Path\s+\(Split-Path\s+\$PSScriptRoot\s+-Parent\)\s+''Lib\\Fieldkit\.Common\.ps1''\s*\)\s*$'
    $stripped = [regex]::Replace($tool, $pattern, '# (library provided by the remote shim)')
    if ($stripped -eq $tool -and $tool -match 'Fieldkit\.Common\.ps1') {
        throw "Could not strip the local library dot-source from $(Split-Path $ToolPath -Leaf). The line may have been reformatted; New-FieldkitPayload needs updating rather than guessing."
    }

    $preamble = @"
`$ErrorActionPreference = 'Continue'
`$script:FieldkitMaxRows = $MaxRows
"@

    # The tool is wrapped in its own scriptblock rather than concatenated flat.
    #
    # A tool starts with [CmdletBinding()] and param(), and those must be the
    # FIRST statement of whatever contains them. Pasting the shim in front of
    # the tool puts them in the middle of a script, which is a parse error:
    # "Unexpected attribute 'CmdletBinding'".
    #
    # Wrapping in & { } makes the tool's param block first inside that block,
    # which is legal, and it keeps every parameter DEFAULT intact. Invoked with
    # no arguments, a tool therefore behaves exactly as it does locally instead
    # of running with null parameters.
    $text = $preamble + "`r`n" +
            $shim + "`r`n" +
            "& {`r`n" + $stripped + "`r`n}`r`n"

    return [scriptblock]::Create($text)
}

# ------------------------------------------------------------------- the sweep

function Invoke-FieldkitRemoteTool {
    <#
        Run one tool against many targets and bring the results home.

        Returns both the results AND the coverage, because the caller must not
        be able to report the first without the second.
    #>
    param(
        [Parameter(Mandatory)] [string] $ToolPath,
        [Parameter(Mandatory)] [string] $ShimPath,
        [Parameter(Mandatory)] [string[]] $Targets,
        [pscredential] $Credential,
        [int] $ThrottleLimit = 16,
        [int] $MaxRows = 5000
    )

    $payload = New-FieldkitPayload -ToolPath $ToolPath -ShimPath $ShimPath -MaxRows $MaxRows

    $results  = [System.Collections.Generic.List[object]]::new()
    $coverage = [System.Collections.Generic.List[object]]::new()

    $i = 0
    foreach ($t in $Targets) {
        $i++
        Write-Progress -Activity "Running $(Split-Path $ToolPath -Leaf)" -Status $t `
                       -PercentComplete (($i / $Targets.Count) * 100)
        Write-Host ("  {0,-38} " -f $t) -NoNewline

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $sess = $null
        try {
            $sp = @{ ComputerName = $t; ErrorAction = 'Stop' }
            if ($Credential) { $sp['Credential'] = $Credential }
            $sess = New-PSSession @sp

            # 6>$null discards the tool's Write-Host output. Across many targets
            # that would be thousands of lines of someone else's console.
            $res = Invoke-Command -Session $sess -ScriptBlock {
                param($sb)
                & ([scriptblock]::Create($sb)) 6>$null 4>$null 3>$null
            } -ArgumentList $payload.ToString() -ErrorAction Stop

            $sw.Stop()
            $one = @($res | Where-Object { $_.FieldkitResult -eq $true }) | Select-Object -First 1

            if (-not $one) {
                Write-Host 'NO RESULT' -ForegroundColor Red
                $coverage.Add([pscustomobject]@{
                    Target = $t; Transport = 'WinRM'; Status = 'NO RESULT'
                    Reason = 'The tool ran but returned no Fieldkit result object. It may have exited early.'
                    Sections = 0; NotRead = 0; Seconds = [math]::Round($sw.Elapsed.TotalSeconds,1)
                })
                continue
            }

            $notRead = @($one.Sections | Where-Object { $_.Status -eq 'notread' }).Count
            $results.Add($one)
            $coverage.Add([pscustomobject]@{
                Target = $t; Transport = 'WinRM'; Status = 'OK'
                Reason = $(if ($one.Elevated) { '' } else { 'connected but NOT elevated on the target; some sections will be NOT READ' })
                Sections = @($one.Sections).Count; NotRead = $notRead
                Seconds = [math]::Round($sw.Elapsed.TotalSeconds,1)
            })
            Write-Host ("OK   {0} section(s), {1} not read, {2:N1}s" -f
                        @($one.Sections).Count, $notRead, $sw.Elapsed.TotalSeconds) `
                       -ForegroundColor $(if ($notRead) { 'Yellow' } else { 'Green' })
        }
        catch {
            $sw.Stop()
            $msg = $_.Exception.Message
            Write-Host 'UNREACHABLE' -ForegroundColor Red
            Write-Host ("      {0}" -f ($msg -split "`r?`n")[0]) -ForegroundColor DarkGray
            $coverage.Add([pscustomobject]@{
                Target = $t; Transport = 'none'; Status = 'UNREACHABLE'
                Reason = $msg; Sections = 0; NotRead = 0
                Seconds = [math]::Round($sw.Elapsed.TotalSeconds,1)
            })
        }
        finally {
            if ($sess) { Remove-PSSession $sess -ErrorAction SilentlyContinue }
        }
    }
    Write-Progress -Activity 'Running' -Completed

    [pscustomobject]@{
        Results  = @($results)
        Coverage = @($coverage)
    }
}

# -------------------------------------------------------------------- writing

function Write-FieldkitRemoteResult {
    <#
        Write what came back, coverage first.

        Per-target CSVs so one machine can be read on its own, plus a combined
        CSV per section with a ComputerName column, because the interesting
        question across an estate is almost always comparative.
    #>
    param(
        [Parameter(Mandatory)] $Outcome,
        [Parameter(Mandatory)] [string] $OutputFolder,
        [Parameter(Mandatory)] [string] $Title
    )

    # ---- coverage, written first and named so it sorts to the top
    $Outcome.Coverage | Export-Csv -LiteralPath (Join-Path $OutputFolder '_COVERAGE.csv') `
                                   -NoTypeInformation -Encoding UTF8

    $reached     = @($Outcome.Coverage | Where-Object { $_.Status -eq 'OK' })
    $unreachable = @($Outcome.Coverage | Where-Object { $_.Status -ne 'OK' })
    $total       = @($Outcome.Coverage).Count

    # ---- per target
    foreach ($r in $Outcome.Results) {
        $dir = Join-Path $OutputFolder ("by-host\" + $r.ComputerName)
        $null = New-Item -ItemType Directory -Path $dir -Force
        foreach ($s in $r.Sections) {
            if ($s.Status -ne 'rows') { continue }
            $safe = ($s.Name -replace '[^A-Za-z0-9]+', '-').Trim('-')
            $s.Rows | Export-Csv -LiteralPath (Join-Path $dir ($safe + '.csv')) `
                                 -NoTypeInformation -Encoding UTF8
        }
        $hostNotes = [System.Collections.Generic.List[string]]::new()
        $hostNotes.Add("Host      : $($r.ComputerName)")
        $hostNotes.Add("Elevated  : $($r.Elevated)")
        $hostNotes.Add("OS role   : $($r.OSRole)")
        $hostNotes.Add("PowerShell: $($r.PSVersion)")
        $hostNotes.Add('')
        foreach ($s in $r.Sections) {
            $hostNotes.Add(("{0,-10} {1}{2}" -f $s.Status.ToUpper(), $s.Name,
                            $(if ($s.Error) { " - $($s.Error)" } elseif ($s.Truncated) { ' (TRUNCATED)' } else { '' })))
        }
        ($hostNotes -join "`r`n") | Set-Content -LiteralPath (Join-Path $dir 'SECTIONS.txt') -Encoding UTF8
    }

    # ---- combined per section
    $allSections = @($Outcome.Results | ForEach-Object { $_.Sections } |
                     Select-Object -ExpandProperty Name -Unique)
    $combinedDir = Join-Path $OutputFolder 'combined'
    if ($allSections.Count) { $null = New-Item -ItemType Directory -Path $combinedDir -Force }

    foreach ($name in $allSections) {
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $Outcome.Results) {
            $s = @($r.Sections | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
            if (-not $s -or $s.Status -ne 'rows') { continue }
            foreach ($row in $s.Rows) {
                # Prepend the host, so a combined file is still answerable.
                $o = [ordered]@{ ComputerName = $r.ComputerName }
                foreach ($p in $row.PSObject.Properties) {
                    if ($p.Name -in @('PSComputerName','RunspaceId','PSShowComputerName')) { continue }
                    $o[$p.Name] = $p.Value
                }
                $rows.Add([pscustomobject]$o)
            }
        }
        if ($rows.Count) {
            $safe = ($name -replace '[^A-Za-z0-9]+', '-').Trim('-')
            $rows | Export-Csv -LiteralPath (Join-Path $combinedDir ($safe + '.csv')) `
                               -NoTypeInformation -Encoding UTF8
        }
    }

    # ---- the section-by-host matrix: which sections failed, and where
    $matrix = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $allSections) {
        $row = [ordered]@{ Section = $name; Rows = 0; Empty = 0; NotRead = 0; Missing = 0 }
        foreach ($r in $Outcome.Results) {
            $s = @($r.Sections | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
            if (-not $s)                      { $row.Missing++ }
            elseif ($s.Status -eq 'rows')     { $row.Rows++ }
            elseif ($s.Status -eq 'empty')    { $row.Empty++ }
            else                              { $row.NotRead++ }
        }
        $matrix.Add([pscustomobject]$row)
    }
    if ($matrix.Count) {
        $matrix | Sort-Object NotRead -Descending |
            Export-Csv -LiteralPath (Join-Path $OutputFolder '_SECTION-MATRIX.csv') `
                       -NoTypeInformation -Encoding UTF8
    }

    # ---- SUMMARY.txt, coverage first
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($Title)
    $lines.Add('=' * $Title.Length)
    $lines.Add('')
    $lines.Add("Run from    : $env:COMPUTERNAME")
    $lines.Add("Account     : $env:USERDOMAIN\$env:USERNAME")
    $lines.Add("Collected   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
    $lines.Add('')
    $lines.Add('COVERAGE - READ THIS BEFORE ANY FINDING')
    $lines.Add('---------------------------------------')
    $lines.Add("  Targeted    : $total")
    $lines.Add("  Reached     : $($reached.Count)")
    $lines.Add("  UNREACHABLE : $($unreachable.Count)")
    if ($total -gt 0) {
        $pct = [math]::Round(($reached.Count / $total) * 100, 1)
        $lines.Add("  Coverage    : $pct%")
    }
    $lines.Add('')
    if ($unreachable.Count) {
        $lines.Add('  Any conclusion drawn from this run applies ONLY to the machines that')
        $lines.Add('  were reached. It says nothing whatever about the ones that were not,')
        $lines.Add('  and a clean result across a partial estate is not a clean estate.')
        $lines.Add('')
        $lines.Add('  NOT REACHED:')
        foreach ($u in $unreachable) {
            $lines.Add(("    {0,-34} {1}" -f $u.Target, $u.Status))
            $lines.Add(("      {0}" -f (($u.Reason -split "`r?`n")[0])))
        }
        $lines.Add('')
        $lines.Add('  A production system that answers no management transport at all is a')
        $lines.Add('  finding in its own right, separate from whatever this tool was looking')
        $lines.Add('  for. It means nothing is managing it either.')
        $lines.Add('')
    }
    else {
        $lines.Add('  Every target was reached.')
        $lines.Add('')
    }

    $notElevated = @($reached | Where-Object { $_.Reason -like '*NOT elevated*' })
    if ($notElevated.Count) {
        $lines.Add("  CONNECTED BUT NOT ELEVATED on $($notElevated.Count) target(s). Sections needing")
        $lines.Add('  administrator rights came back NOT READ on those, which is not a pass:')
        foreach ($n in $notElevated) { $lines.Add("    $($n.Target)") }
        $lines.Add('')
    }

    $worst = @($matrix | Where-Object { $_.NotRead -gt 0 } | Sort-Object NotRead -Descending | Select-Object -First 10)
    if ($worst.Count) {
        $lines.Add('SECTIONS THAT FAILED MOST OFTEN')
        $lines.Add('-------------------------------')
        foreach ($w in $worst) {
            $lines.Add(("  {0,4} of {1} hosts could not read: {2}" -f $w.NotRead, $reached.Count, $w.Section))
        }
        $lines.Add('')
    }

    $lines.Add('FILES')
    $lines.Add('-----')
    $lines.Add('  _COVERAGE.csv        every target, reached or not, and why')
    $lines.Add('  _SECTION-MATRIX.csv  per section: how many hosts returned rows, empty, or failed')
    $lines.Add('  combined\            one CSV per section, all hosts, with a ComputerName column')
    $lines.Add('  by-host\<HOST>\      the same data split per machine, plus SECTIONS.txt')
    $lines.Add('')
    $lines.Add('Nothing was written to any target. Tools ran through the remote shim, which')
    $lines.Add('returns objects; no folder was created and nothing was copied back.')

    ($lines -join "`r`n") | Set-Content -LiteralPath (Join-Path $OutputFolder 'SUMMARY.txt') -Encoding UTF8

    # ---- console, coverage first
    Write-Host ''
    Write-Host ('  ' + ('-' * 70)) -ForegroundColor Cyan
    Write-Host '   COVERAGE' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 70)) -ForegroundColor Cyan
    Write-Host ("   Targeted    : {0}" -f $total)
    Write-Host -NoNewline '   Reached     : '
    Write-Host $reached.Count -ForegroundColor Green
    Write-Host -NoNewline '   UNREACHABLE : '
    Write-Host $unreachable.Count -ForegroundColor $(if ($unreachable.Count) { 'Red' } else { 'Green' })
    if ($unreachable.Count) {
        Write-Host ''
        Write-Host '   Findings from this run apply only to the machines reached.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host ("   Written to: {0}" -f $OutputFolder) -ForegroundColor Green
}
