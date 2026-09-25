<#
    Fieldkit.Prereqs.ps1

    The catalog of things a tool might need, how to detect each one, and how to
    install it on this kind of machine.

    THE POINT OF THIS FILE

    A tool that needs the ActiveDirectory module should not fail with
    "Get-ADDomain is not recognized" halfway through a collection. It should be
    greyed out in the menu with the reason next to it, and the thing it needs
    should be one keystroke away.

    THREE STATES, NOT TWO

    Detection returns Present, Absent or Unknown. Unknown is not a polite way
    of saying Absent. If the check itself failed, offering to install something
    that may already be there is the wrong move, and reporting "not installed"
    when the truth is "could not tell" is how a missing tool becomes a wrong
    finding.
#>

function Get-FieldkitPrereqCatalog {
    <#
        Each entry is data, not code that runs on load.

        Test          - scriptblock returning Present / Absent / Unknown
        InstallServer - what to run on Server or DomainController
        InstallClient - what to run on Workstation
        Elevation     - does the INSTALL need administrator (detection rarely does)
        Internet      - does the install reach out to the network
    #>
    @(
        [pscustomobject]@{
            Id            = 'RSAT-AD'
            Name          = 'Active Directory PowerShell module'
            Why           = 'Get-ADDomain, Get-ADUser, Get-ADGroupMember and the rest of the AD tools.'
            Test          = {
                try {
                    if (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction Stop) { 'Present' }
                    else { 'Absent' }
                } catch { 'Unknown' }
            }
            InstallServer = 'Install-WindowsFeature RSAT-AD-PowerShell'
            InstallClient = 'Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools*'
            Elevation     = $true
            Internet      = $true
            Notes         = 'On a workstation this is a Windows optional feature and may pull from Windows Update. On a domain controller it is usually already present.'
        }
        [pscustomobject]@{
            Id            = 'RSAT-GP'
            Name          = 'Group Policy management module'
            Why           = 'Get-GPO, Get-GPOReport, Get-GPResultantSetOfPolicy.'
            Test          = {
                try {
                    if (Get-Module -ListAvailable -Name GroupPolicy -ErrorAction Stop) { 'Present' }
                    else { 'Absent' }
                } catch { 'Unknown' }
            }
            InstallServer = 'Install-WindowsFeature GPMC'
            InstallClient = 'Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools*'
            Elevation     = $true
            Internet      = $true
            Notes         = 'GPMC on a server installs the console as well as the module.'
        }
        [pscustomobject]@{
            Id            = 'RSAT-DNS'
            Name          = 'DNS Server management module'
            Why           = 'Get-DnsServerZone, Get-DnsServerScavenging and the DNS half of an AD review.'
            Test          = {
                try {
                    if (Get-Module -ListAvailable -Name DnsServer -ErrorAction Stop) { 'Present' }
                    else { 'Absent' }
                } catch { 'Unknown' }
            }
            InstallServer = 'Install-WindowsFeature RSAT-DNS-Server'
            InstallClient = 'Add-WindowsCapability -Online -Name Rsat.Dns.Tools*'
            Elevation     = $true
            Internet      = $true
            Notes         = ''
        }
        [pscustomobject]@{
            Id            = 'RSAT-DHCP'
            Name          = 'DHCP Server management module'
            Why           = 'Scope and reservation inventory during a network review.'
            Test          = {
                try {
                    if (Get-Module -ListAvailable -Name DhcpServer -ErrorAction Stop) { 'Present' }
                    else { 'Absent' }
                } catch { 'Unknown' }
            }
            InstallServer = 'Install-WindowsFeature RSAT-DHCP'
            InstallClient = 'Add-WindowsCapability -Online -Name Rsat.DHCP.Tools*'
            Elevation     = $true
            Internet      = $true
            Notes         = ''
        }
        [pscustomobject]@{
            Id            = 'PS-MODULE-PSWindowsUpdate'
            Name          = 'PSWindowsUpdate module'
            Why           = 'Reads pending and installed updates without a WSUS console.'
            Test          = {
                try {
                    if (Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction Stop) { 'Present' }
                    else { 'Absent' }
                } catch { 'Unknown' }
            }
            InstallServer = 'Install-Module PSWindowsUpdate -Scope CurrentUser -Force'
            InstallClient = 'Install-Module PSWindowsUpdate -Scope CurrentUser -Force'
            Elevation     = $false
            Internet      = $true
            Notes         = 'From the PowerShell Gallery. CurrentUser scope, so it leaves nothing behind for other accounts. Many client networks block the Gallery, and that is a normal answer, not a fault.'
        }
        [pscustomobject]@{
            Id            = 'ELEVATION'
            Name          = 'Administrator rights in this session'
            Why           = 'Reading the Security event log, local policy and SMB configuration.'
            Test          = { if (Test-FieldkitElevation) { 'Present' } else { 'Absent' } }
            InstallServer = ''
            InstallClient = ''
            Elevation     = $false
            Internet      = $false
            Notes         = 'Not installable. Close this window and start PowerShell with Run as administrator.'
        }
    )
}

function Test-FieldkitPrereq {
    <#
        Evaluate one prerequisite and return a result object.

        The scriptblock is invoked here rather than at catalog build time so
        the answer is current, not cached from when the menu opened.
    #>
    param(
        [Parameter(Mandatory)] $Prereq
    )
    $state = 'Unknown'
    try { $state = & $Prereq.Test }
    catch { $state = 'Unknown' }
    if ($state -notin @('Present','Absent','Unknown')) { $state = 'Unknown' }

    [pscustomobject]@{
        Id     = $Prereq.Id
        Name   = $Prereq.Name
        State  = $state
        Prereq = $Prereq
    }
}

function Get-FieldkitPrereqState {
    <# Every prerequisite, evaluated, as a hashtable keyed by Id. #>
    $map = @{}
    foreach ($p in (Get-FieldkitPrereqCatalog)) {
        $r = Test-FieldkitPrereq -Prereq $p
        $map[$p.Id] = $r
    }
    return $map
}

function Resolve-FieldkitInstallCommand {
    <#
        The command for THIS machine.

        A workstation has no Install-WindowsFeature and a server has no RSAT
        optional capability, so offering the wrong one produces a confusing
        failure rather than an install.
    #>
    param(
        [Parameter(Mandatory)] $Prereq
    )
    $role = Get-FieldkitOSRole
    switch ($role) {
        'Workstation' { return $Prereq.InstallClient }
        'Server'      { return $Prereq.InstallServer }
        'DomainController' { return $Prereq.InstallServer }
        default {
            # Unknown OS role. Prefer the client form only if it is the only
            # one defined; otherwise say so rather than guessing.
            if ($Prereq.InstallServer) { return $Prereq.InstallServer }
            return $Prereq.InstallClient
        }
    }
}

function Install-FieldkitPrereq {
    <#
        Install one prerequisite, after an explicit typed confirmation.

        This is the only function in the kit that changes the machine. It logs
        what it did, what the command was, and whether it worked.
    #>
    param(
        [Parameter(Mandatory)] $Prereq
    )

    if (-not $Prereq.InstallServer -and -not $Prereq.InstallClient) {
        Write-Host ''
        Write-Host "  $($Prereq.Name) cannot be installed by this kit." -ForegroundColor Yellow
        if ($Prereq.Notes) { Write-Host "  $($Prereq.Notes)" -ForegroundColor Yellow }
        Write-Host ''
        return $false
    }

    $cmd  = Resolve-FieldkitInstallCommand -Prereq $Prereq
    $role = Get-FieldkitOSRole

    if ($role -eq 'Unknown') {
        Write-Host ''
        Write-Host '  Could not determine whether this is a workstation or a server.' -ForegroundColor Yellow
        Write-Host '  The command below is a best guess. Check it before continuing.'  -ForegroundColor Yellow
    }

    if ($Prereq.Elevation -and -not (Test-FieldkitElevation)) {
        Write-Host ''
        Write-Host "  $($Prereq.Name) needs administrator rights to install." -ForegroundColor Yellow
        Write-Host '  This session is not elevated. Nothing was changed.'     -ForegroundColor Yellow
        Write-Host '  Close this window and start PowerShell with Run as administrator.'
        Write-Host ''
        Write-FieldkitLog -Level 'WARN' -Message "Install of $($Prereq.Id) refused: session not elevated"
        return $false
    }

    if ($Prereq.Internet) {
        Write-Host ''
        Write-Host '  Note: this install reaches the network (Windows Update or the' -ForegroundColor DarkYellow
        Write-Host '  PowerShell Gallery). On a restricted client network it may fail,' -ForegroundColor DarkYellow
        Write-Host '  and that failure is a property of the network, not of the kit.'  -ForegroundColor DarkYellow
    }

    if (-not (Confirm-FieldkitChange -What $Prereq.Name -Command $cmd)) {
        Write-Host '  Cancelled. Nothing was changed.' -ForegroundColor Green
        Write-FieldkitLog -Level 'INFO' -Message "Install of $($Prereq.Id) cancelled at prompt"
        return $false
    }

    Write-FieldkitLog -Level 'CHANGE' -Message "INSTALL START $($Prereq.Id) on $role : $cmd"
    Write-Host ''
    Write-Host '  Installing. This can take several minutes and may look stalled.' -ForegroundColor Cyan

    $ok = $false
    try {
        if ($cmd -like 'Add-WindowsCapability*') {
            # Capability names carry a version suffix that changes between
            # Windows builds, so find the real name rather than hardcoding one.
            $pattern = ($cmd -replace '.*-Name\s+', '').Trim()
            $cap = Get-WindowsCapability -Online -Name $pattern -ErrorAction Stop |
                   Select-Object -First 1
            if (-not $cap) { throw "No Windows capability on this machine matches $pattern" }
            if ($cap.State -eq 'Installed') {
                Write-Host "  Already installed: $($cap.Name)" -ForegroundColor Green
                $ok = $true
            }
            else {
                $null = Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop
                $ok = $true
            }
        }
        elseif ($cmd -like 'Install-WindowsFeature*') {
            $feature = ($cmd -replace '^Install-WindowsFeature\s+', '').Trim()
            $r = Install-WindowsFeature -Name $feature -ErrorAction Stop
            $ok = [bool]$r.Success
            if ($r.RestartNeeded -and $r.RestartNeeded -ne 'No') {
                Write-Host ''
                Write-Host '  The feature reports that a restart is needed.' -ForegroundColor Yellow
                Write-Host '  DO NOT restart a client server yourself. Tell the client.' -ForegroundColor Yellow
                Write-FieldkitLog -Level 'WARN' -Message "$($Prereq.Id) install reports RestartNeeded"
            }
        }
        elseif ($cmd -like 'Install-Module*') {
            $modName = ($cmd -split '\s+')[1]
            Install-Module -Name $modName -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            $ok = $true
        }
        else {
            throw "Unrecognized install command form: $cmd"
        }
    }
    catch {
        Write-Host ''
        Write-Host "  INSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-FieldkitLog -Level 'ERROR' -Message "INSTALL FAILED $($Prereq.Id): $($_.Exception.Message)"
        return $false
    }

    # Do not trust the install's own success flag. Re-run the detection.
    $after = Test-FieldkitPrereq -Prereq $Prereq
    if ($after.State -eq 'Present') {
        Write-Host ''
        Write-Host "  Installed and verified: $($Prereq.Name)" -ForegroundColor Green
        Write-FieldkitLog -Level 'CHANGE' -Message "INSTALL OK $($Prereq.Id), verified present"
        return $true
    }

    Write-Host ''
    Write-Host "  The install reported success but $($Prereq.Name) still does not" -ForegroundColor Yellow
    Write-Host '  detect as present. A new PowerShell window often fixes this,'     -ForegroundColor Yellow
    Write-Host '  because the module path is read at session start.'                -ForegroundColor Yellow
    Write-FieldkitLog -Level 'WARN' -Message "INSTALL $($Prereq.Id) reported success but detection says $($after.State)"
    return $false
}
