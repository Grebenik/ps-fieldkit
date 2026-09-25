<#FIELDKIT
Name      : Patch Posture
Category  : Host
Summary   : Where this machine gets updates, whether it installs them, and when it last did.
Requires  : None
Elevation : Recommended
Scope     : Local machine
Output    : PatchPosture
ReadOnly  : Yes
FIELDKIT#>

<#
    Get-PatchPosture.ps1

    Three questions, in order:

      1. Where is this machine told to get updates?
      2. Is it allowed to install them, or only to notify?
      3. When did it last actually install one?

    Question 3 is the one that settles arguments. A machine can be pointed at a
    working update source, be configured to install automatically, and still
    not have patched in two years. Only the installed-update history says
    whether the configuration is having any effect.

    READ-ONLY. Registry reads and Get-HotFix. Nothing is scanned, triggered or
    installed, and no update service is contacted.
#>

[CmdletBinding()]
param()

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Lib\Fieldkit.Common.ps1')

$out   = New-FieldkitOutputFolder -ToolOutputName 'PatchPosture'
$notes = [System.Collections.Generic.List[string]]::new()

Write-FieldkitHeader -Title 'Patch Posture' -OutputFolder $out

# --------------------------------------------------------------- 1. the source
Invoke-FieldkitSection -Name 'Update source (WSUS / policy)' -OutputFolder $out -Notes $notes -Body {
    $wuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $auKey = "$wuKey\AU"
    $wu = Get-ItemProperty -Path $wuKey -ErrorAction SilentlyContinue
    $au = Get-ItemProperty -Path $auKey -ErrorAction SilentlyContinue

    # AUOptions is the setting most often misread. 2 means notify only: the
    # machine is managed, is checking in, and installs nothing on its own.
    $auMeaning = switch ($au.AUOptions) {
        2 { '2 = notify before download. NOTHING INSTALLS WITHOUT SOMEONE CLICKING' }
        3 { '3 = download automatically, notify before install. NOTHING INSTALLS ON ITS OWN' }
        4 { '4 = download and install on a schedule' }
        5 { '5 = local administrator chooses' }
        $null { 'not configured by policy' }
        default { "$($au.AUOptions) = unrecognized value" }
    }

    [pscustomobject]@{
        ComputerName           = $env:COMPUTERNAME
        WUServer               = $wu.WUServer
        WUStatusServer         = $wu.WUStatusServer
        UseWUServer            = $au.UseWUServer
        UseWUServerMeaning     = if ($null -eq $au.UseWUServer) { 'not set: uses Microsoft Update' }
                                 elseif ($au.UseWUServer -eq 1) { '1 = use the WUServer above' }
                                 else { '0 = WUServer is IGNORED even if set' }
        AUOptions              = $au.AUOptions
        AUOptionsMeaning       = $auMeaning
        NoAutoUpdate           = $au.NoAutoUpdate
        NoAutoUpdateMeaning    = if ($au.NoAutoUpdate -eq 1) { '1 = automatic updates are TURNED OFF' } else { '' }
        ScheduledInstallDay    = $au.ScheduledInstallDay
        ScheduledInstallTime   = $au.ScheduledInstallTime
        DeferFeatureUpdates    = $wu.DeferFeatureUpdates
        DeferQualityUpdates    = $wu.DeferQualityUpdates
        TargetGroup            = $wu.TargetGroup
        TargetGroupEnabled     = $wu.TargetGroupEnabled
    }
}

Invoke-FieldkitSection -Name 'Is the update source reachable' -OutputFolder $out -Notes $notes -Body {
    <#
        A WSUS pointer to a server that no longer exists is common and it is
        invisible from the registry alone. This resolves the name and tests
        the port. It does not talk to the update service or trigger a scan.

        If no WSUS is configured, this reports that rather than passing.
    #>
    $wu = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
    if (-not $wu.WUServer) {
        return [pscustomobject]@{
            WUServer = '(none configured)'
            Result   = 'No WSUS server is set by policy, so there is nothing to reach.'
        }
    }

    $uri = $null
    try { $uri = [uri]$wu.WUServer } catch { }
    if (-not $uri) {
        return [pscustomobject]@{ WUServer = $wu.WUServer; Result = 'NOT A VALID URL' }
    }

    $port = if ($uri.Port -gt 0) { $uri.Port } else { if ($uri.Scheme -eq 'https') { 443 } else { 80 } }
    $dns  = $null
    try { $dns = (Resolve-DnsName -Name $uri.Host -ErrorAction Stop | Select-Object -First 1).IPAddress }
    catch { $dns = "DNS DOES NOT RESOLVE: $($_.Exception.Message)" }

    $reach = 'not tested'
    if ($dns -notlike 'DNS DOES NOT RESOLVE*') {
        try {
            $t = Test-NetConnection -ComputerName $uri.Host -Port $port -WarningAction SilentlyContinue -ErrorAction Stop
            $reach = if ($t.TcpTestSucceeded) { "port $port open" } else { "PORT $port CLOSED OR FILTERED" }
        }
        catch { $reach = "test failed: $($_.Exception.Message)" }
    }

    [pscustomobject]@{
        WUServer = $wu.WUServer
        Host     = $uri.Host
        Port     = $port
        DNS      = $dns
        Result   = $reach
    }
}

# --------------------------------------------------------------- 2. the service
Invoke-FieldkitSection -Name 'Update-related services' -OutputFolder $out -Notes $notes -Body {
    foreach ($svc in @('wuauserv','UsoSvc','BITS','TrustedInstaller','DoSvc')) {
        try {
            $s = Get-CimInstance Win32_Service -Filter "Name='$svc'" -ErrorAction Stop
            if (-not $s) {
                [pscustomobject]@{ Name = $svc; DisplayName = ''; State = ''; StartMode = ''
                                   Note = 'service not present on this machine' }
                continue
            }
            [pscustomobject]@{
                Name = $s.Name; DisplayName = $s.DisplayName; State = $s.State
                StartMode = $s.StartMode
                Note = if ($s.StartMode -eq 'Disabled') { 'DISABLED. Updates cannot run.' } else { '' }
            }
        }
        catch {
            [pscustomobject]@{ Name = $svc; DisplayName = ''; State = ''; StartMode = ''
                               Note = "NOT READ: $($_.Exception.Message)" }
        }
    }
}

# --------------------------------------------------------------- 3. the evidence
Invoke-FieldkitSection -Name 'Installed update history' -OutputFolder $out -Notes $notes -Body {
    Get-HotFix -ErrorAction Stop |
        Sort-Object InstalledOn -Descending |
        Select-Object HotFixID, Description, InstalledOn, InstalledBy,
                      @{n='DaysAgo';e={ if ($_.InstalledOn) { [math]::Round(((Get-Date) - $_.InstalledOn).TotalDays) } }}
}

Invoke-FieldkitSection -Name 'Patch age verdict' -OutputFolder $out -Notes $notes -Body {
    <#
        The one row that matters.

        Get-HotFix does not see everything: on current Windows, cumulative
        updates delivered through the component store may not appear. The OS
        build and revision are therefore reported alongside, because the UBR
        is authoritative where Get-HotFix is not.
    #>
    $hf = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn })
    $newest = $hf | Sort-Object InstalledOn -Descending | Select-Object -First 1
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

    $days = if ($newest) { [math]::Round(((Get-Date) - $newest.InstalledOn).TotalDays) } else { $null }
    $verdict =
        if (-not $newest) { 'NO DATED UPDATE HISTORY. Either nothing has been installed, or this Windows version reports updates only through the build revision below. Check the UBR before concluding.' }
        elseif ($days -le 45)  { "Last update $days days ago. Within a normal monthly cycle." }
        elseif ($days -le 120) { "Last update $days days ago. Behind, but not abandoned." }
        else                   { "LAST UPDATE $days DAYS AGO. This machine is not being patched." }

    [pscustomobject]@{
        ComputerName       = $env:COMPUTERNAME
        LastUpdateId       = if ($newest) { $newest.HotFixID } else { '' }
        LastUpdateInstalled = if ($newest) { $newest.InstalledOn } else { '' }
        DaysSinceLastUpdate = $days
        DatedUpdatesFound  = $hf.Count
        OSBuild            = $cv.CurrentBuild
        UBR                = $cv.UBR
        DisplayVersion     = $cv.DisplayVersion
        Verdict            = $verdict
    }
}

Invoke-FieldkitSection -Name 'Recent Windows Update errors' -OutputFolder $out -Notes $notes -Body {
    # Repeated failures here explain a machine that is configured correctly and
    # still not patching. An empty result is genuinely good news.
    Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        ProviderName = 'Microsoft-Windows-WindowsUpdateClient'
        Level     = 2, 3
        StartTime = (Get-Date).AddDays(-90)
    } -ErrorAction Stop |
        Select-Object TimeCreated, Id, LevelDisplayName,
                      @{n='Message';e={ ($_.Message -split "`r?`n")[0] }} |
        Sort-Object TimeCreated -Descending
}

$notes.Add('Get-HotFix does not list every cumulative update on current Windows builds. Where the update history looks empty, the build revision (UBR) is the reliable figure.')
$notes.Add('Nothing was scanned, triggered or installed. No update service was contacted beyond a TCP port test of any configured WSUS host.')

Write-FieldkitSummary -Title 'Patch Posture' -OutputFolder $out -Notes $notes
