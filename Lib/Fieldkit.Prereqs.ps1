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
            Id            = 'RSAT-ADCS'
            Name          = 'Certificate Services management module'
            Why           = 'Certificate template and CA review. The ADCSAdministration module.'
            Test          = {
                try {
                    if (Get-Module -ListAvailable -Name ADCSAdministration -ErrorAction Stop) { 'Present' }
                    else { 'Absent' }
                } catch { 'Unknown' }
            }
            InstallServer = 'Install-WindowsFeature RSAT-ADCS'
            InstallClient = 'Add-WindowsCapability -Online -Name Rsat.CertificateServices.Tools*'
            Elevation     = $true
            Internet      = $true
            Notes         = ''
        }
        [pscustomobject]@{
            Id            = 'RSAT-SERVERMGR'
            Name          = 'Server Manager tools'
            Why           = 'Reading roles and features on remote servers from a workstation.'
            Test          = {
                try {
                    if (Get-Module -ListAvailable -Name ServerManager -ErrorAction Stop) { 'Present' }
                    else { 'Absent' }
                } catch { 'Unknown' }
            }
            InstallServer = ''   # built in on Server
            InstallClient = 'Add-WindowsCapability -Online -Name Rsat.ServerManager.Tools*'
            Elevation     = $true
            Internet      = $true
            Notes         = 'Built in on Windows Server. Only a workstation needs this.'
        }
        [pscustomobject]@{
            Id            = 'PS7'
            Name          = 'PowerShell 7'
            Why           = 'Not required by anything in this kit, which targets 5.1, but better for ad-hoc work and parallel processing.'
            Test          = {
                try {
                    if (Get-Command pwsh.exe -ErrorAction Stop) { 'Present' } else { 'Absent' }
                } catch { 'Absent' }
            }
            InstallServer = 'winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements'
            InstallClient = 'winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements'
            Elevation     = $true
            Internet      = $true
            Notes         = 'Needs winget, which is present on Windows 11 and on Windows Server 2025 but not on Server 2019 or 2016. Every tool in this kit runs on 5.1, so this is a convenience.'
        }
        [pscustomobject]@{
            Id            = 'PS-MODULE-ImportExcel'
            Name          = 'ImportExcel module'
            Why           = 'Turns an output folder into one formatted Excel workbook. Optional: CSVs are always written regardless.'
            Test          = {
                try {
                    if (Get-Module -ListAvailable -Name ImportExcel -ErrorAction Stop) { 'Present' }
                    else { 'Absent' }
                } catch { 'Unknown' }
            }
            InstallServer = 'Install-Module ImportExcel -Scope CurrentUser -Force'
            InstallClient = 'Install-Module ImportExcel -Scope CurrentUser -Force'
            Elevation     = $false
            Internet      = $true
            Notes         = 'Apache-2.0, by Douglas Finke. Needs no Excel installed. NOTE: 5.1 and 7.x have separate module paths, so installing it from the other PowerShell puts it where this session cannot see it - install it from HERE. Many client networks block the Gallery; that is a normal answer, not a fault, and nothing else stops working without it.'
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

function Test-FieldkitFodSource {
    <#
        Will Add-WindowsCapability actually work on this machine?

        THIS EXISTS BECAUSE OF ONE SPECIFIC HOUR-LONG DEAD END.

        RSAT on a workstation is a Feature on Demand, and Features on Demand
        come from Windows Update. On a machine managed by WSUS, the request is
        sent to WSUS instead, WSUS does not carry them, and the install fails
        with 0x800f0954. The error says nothing about WSUS, so the usual
        response is to re-run it, then check the capability name, then check
        the network, and only much later discover the cause.

        The state is knowable BEFORE trying, from two registry values, so it is
        read and reported instead of discovered.

        The fix is a policy: Computer Configuration, Administrative Templates,
        System, "Specify settings for optional component installation and
        component repair", with "Download repair content and optional features
        directly from Windows Update instead of WSUS" selected. That writes
        RepairContentServerSource = 2.

        Returns Ready, Blocked or Unknown, with the reason.
    #>
    $auKey   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $srvKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing'

    try {
        $au = Get-ItemProperty -Path $auKey  -ErrorAction SilentlyContinue
        $sv = Get-ItemProperty -Path $srvKey -ErrorAction SilentlyContinue
        return Resolve-FieldkitFodState `
                    -UseWUServer              $(if ($au) { $au.UseWUServer } else { $null }) `
                    -RepairContentServerSource $(if ($sv) { $sv.RepairContentServerSource } else { $null }) `
                    -LocalSourcePath           $(if ($sv) { $sv.LocalSourcePath } else { $null })
    }
    catch {
        return [pscustomobject]@{
            State = 'Unknown'; Reason = "Could not read the servicing policy: $($_.Exception.Message)"
            Fix = ''
        }
    }
}

function Resolve-FieldkitFodState {
    <#
        The decision, separated from the registry read so it can be tested.

        Every branch here fires on a client machine and none of them fire on
        mine, which is exactly the shape of code that ships wrong. Keeping the
        logic pure means all four cases can be exercised without touching
        HKLM on a real machine.
    #>
    param(
        $UseWUServer,
        $RepairContentServerSource,
        $LocalSourcePath
    )

    $useWsus   = $UseWUServer
    $repairSrc = $RepairContentServerSource
    $localPath = $LocalSourcePath

    # Not WSUS-managed: Features on Demand come straight from Windows Update.
    if ($useWsus -ne 1) {
        return [pscustomobject]@{
            State  = 'Ready'
            Reason = 'This machine is not pointed at WSUS for updates, so optional features come from Windows Update directly.'
            Fix    = ''
        }
    }

    # WSUS-managed, and told to get repair content and optional features from
    # Windows Update anyway. This is the configuration that works.
    if ($repairSrc -eq 2) {
        return [pscustomobject]@{
            State  = 'Ready'
            Reason = 'WSUS-managed, but RepairContentServerSource is 2, so optional features bypass WSUS and come from Windows Update.'
            Fix    = ''
        }
    }

    if ($localPath) {
        return [pscustomobject]@{
            State  = 'Unknown'
            Reason = "WSUS-managed with a LocalSourcePath set ($localPath). The install may succeed from that source if it holds the RSAT payload, which cannot be determined from here."
            Fix    = 'If it fails with 0x800f0954, set RepairContentServerSource to 2 or point LocalSourcePath at a source that carries the Features on Demand payload.'
        }
    }

    [pscustomobject]@{
        State  = 'Blocked'
        Reason = 'This machine takes updates from WSUS (UseWUServer=1) and has no policy allowing optional features to come from Windows Update. Add-WindowsCapability will almost certainly fail with 0x800f0954.'
        Fix    = 'Group Policy: Computer Configuration, Administrative Templates, System, "Specify settings for optional component installation and component repair". Select "Download repair content and optional features directly from Windows Update instead of Windows Server Update Services (WSUS)". That sets RepairContentServerSource = 2 under HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing. It is a change, so it goes through change control.'
    }
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

    # For a Feature on Demand, say whether it can work BEFORE spending ten
    # minutes finding out that it cannot.
    if ($cmd -like 'Add-WindowsCapability*') {
        $fod = Test-FieldkitFodSource
        Write-Host ''
        switch ($fod.State) {
            'Ready' {
                Write-Host '  Optional feature source: OK' -ForegroundColor Green
                Write-Host ("  $($fod.Reason)") -ForegroundColor DarkGray
            }
            'Blocked' {
                Write-Host '  OPTIONAL FEATURE SOURCE IS BLOCKED' -ForegroundColor Red
                Write-Host ''
                Write-Host "  $($fod.Reason)" -ForegroundColor Yellow
                Write-Host ''
                Write-Host '  THE FIX' -ForegroundColor Cyan
                Write-Host "  $($fod.Fix)" -ForegroundColor Cyan
                Write-Host ''
                Write-Host '  You can still try. It costs a few minutes and it will most likely' -ForegroundColor Yellow
                Write-Host '  fail with 0x800f0954. Carrying the module in from another machine' -ForegroundColor Yellow
                Write-Host '  is often faster than getting the policy changed.'                  -ForegroundColor Yellow
                Write-FieldkitLog -Level 'WARN' -Message "FoD source blocked before installing $($Prereq.Id): WSUS-managed with no Windows Update fallback"
            }
            default {
                Write-Host '  Optional feature source: COULD NOT DETERMINE' -ForegroundColor DarkYellow
                Write-Host ("  $($fod.Reason)") -ForegroundColor DarkGray
                if ($fod.Fix) { Write-Host ("  $($fod.Fix)") -ForegroundColor DarkGray }
            }
        }
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
            <#
                Two things must be true before Install-Module works on a stock
                Windows PowerShell 5.1 machine, and neither is by default. This
                is exactly what a client server looks like.

                  1. TLS. 5.1 does not negotiate TLS 1.2 by default and the
                     PowerShell Gallery refuses anything less. The failure
                     looks like a connection problem, not a protocol one.

                  2. The NuGet provider. Without it, Install-Module fails with
                     "CouldNotInstallNuGetProvider", and interactively it tries
                     to PROMPT to install it - which hangs a non-interactive
                     session rather than failing.

                Both are handled here so the install either works or reports
                the real reason.
            #>
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

            # -ListAvailable, NOT "-Name NuGet".
            #
            # "Get-PackageProvider -Name NuGet" tries to BOOTSTRAP the provider
            # when it is missing, and it PROMPTS for consent to do so.
            # -ErrorAction SilentlyContinue does not suppress that prompt. In a
            # non-interactive session - a scheduled run, or anything with stdin
            # redirected - it hangs forever instead of failing, which is the
            # worst of the available outcomes. -ListAvailable only looks.
            $haveNuGet = $false
            try {
                $haveNuGet = [bool](@(Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue) |
                                    Where-Object { $_.Name -eq 'NuGet' })
            } catch { $haveNuGet = $false }

            if (-not $haveNuGet) {
                Write-Host '  Bootstrapping the NuGet provider first (needed by the Gallery).' -ForegroundColor DarkGray
                try {
                    # -ForceBootstrap answers the consent prompt, for the same
                    # reason as above.
                    $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
                                -Force -ForceBootstrap -Scope CurrentUser `
                                -Confirm:$false -ErrorAction Stop
                }
                catch {
                    throw ("The NuGet provider could not be installed, so the Gallery is unreachable: " +
                           "$($_.Exception.Message). On a locked-down network, copy the module folder in " +
                           "from another machine instead.")
                }
            }

            $modName = ($cmd -split '\s+')[1]
            Install-Module -Name $modName -Scope CurrentUser -Force -AllowClobber `
                           -ErrorAction Stop -Confirm:$false
            $ok = $true
        }
        elseif ($cmd -like 'winget*') {
            # winget is absent on Server 2019 and 2016, and on a machine where
            # App Installer was never provisioned. Say which it is.
            if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
                throw 'winget is not available on this machine. It ships with Windows 11 and Windows Server 2025, but not with Server 2019 or 2016. Install this by hand instead.'
            }
            $args = ($cmd -replace '^winget\s+', '')
            Write-Host ''
            & winget.exe @($args -split '\s+') 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            # winget is a native tool: its exit code is the only reliable
            # signal. 0 is success, and -1978335189 means already installed.
            $ok = ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189)
            if (-not $ok) { throw "winget exited with code $LASTEXITCODE" }
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

    # The command may report failure without throwing. Say so, then check
    # anyway, because the two answers disagree more often than you would hope.
    if (-not $ok) {
        Write-Host ''
        Write-Host '  The install command reported that it did not succeed. Checking' -ForegroundColor Yellow
        Write-Host '  whether it worked regardless.'                                  -ForegroundColor Yellow
        Write-FieldkitLog -Level 'WARN' -Message "$($Prereq.Id) install command reported failure; verifying by detection"
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
