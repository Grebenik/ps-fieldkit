<#FIELDKIT
Name      : Host Snapshot
Category  : Host
Summary   : OS build, patch level, disks, services, local admins, firewall, SMB, and event log retention.
Requires  : None
Elevation : Recommended
Scope     : Local machine
Output    : HostSnapshot
ReadOnly  : Yes
Remote    : Yes
FIELDKIT#>

<#
    Get-HostSnapshot.ps1

    What this machine is, and how it is configured. The first thing to run on
    any server you have just been given access to.

    It needs no modules and no domain rights, so it works on a standalone box,
    a workstation, or a server where RSAT has never been installed.

    Elevation is recommended rather than required. Unelevated it still returns
    most of this; the sections it cannot read are marked NOT READ rather than
    quietly omitted.

    READ-ONLY. Every command is a Get-.
#>

[CmdletBinding()]
param()

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Lib\Fieldkit.Common.ps1')

$out   = New-FieldkitOutputFolder -ToolOutputName 'HostSnapshot'
$notes = [System.Collections.Generic.List[string]]::new()

Write-FieldkitHeader -Title 'Host Snapshot' -OutputFolder $out

if (-not (Test-FieldkitElevation)) {
    $notes.Add('Session was NOT elevated. Local users, firewall and SMB sections may be incomplete.')
    Write-Host '  Not elevated. Some sections will be unavailable and will say so.' -ForegroundColor Yellow
    Write-Host ''
}

# --------------------------------------------------------------- the machine
Invoke-FieldkitSection -Name 'Operating system' -OutputFolder $out -Notes $notes -Body {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    [pscustomobject]@{
        ComputerName   = $env:COMPUTERNAME
        Caption        = $os.Caption
        Version        = $os.Version
        BuildNumber    = $os.BuildNumber
        # UBR is the patch revision. Version alone does not tell you the
        # patch level, and a build with no UBR has usually never been updated.
        UBR            = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR
        DisplayVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
        InstallDate    = $os.InstallDate
        LastBootUpTime = $os.LastBootUpTime
        UptimeDays     = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
        Domain         = $cs.Domain
        PartOfDomain   = $cs.PartOfDomain
        Manufacturer   = $cs.Manufacturer
        Model          = $cs.Model
        MemoryGB       = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        Processors     = $cs.NumberOfLogicalProcessors
    }
}

Invoke-FieldkitSection -Name 'Disks' -OutputFolder $out -Notes $notes -Body {
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
        ForEach-Object {
            [pscustomobject]@{
                Drive      = $_.DeviceID
                Label      = $_.VolumeName
                SizeGB     = [math]::Round($_.Size / 1GB, 1)
                FreeGB     = [math]::Round($_.FreeSpace / 1GB, 1)
                PercentFree = if ($_.Size) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { $null }
            }
        }
}

Invoke-FieldkitSection -Name 'Installed updates (most recent 60)' -OutputFolder $out -Notes $notes -Body {
    Get-HotFix -ErrorAction Stop |
        Sort-Object InstalledOn -Descending |
        Select-Object -First 60 HotFixID, Description, InstalledOn, InstalledBy
}

# --------------------------------------------------------------- what it runs
Invoke-FieldkitSection -Name 'Services set to start automatically' -OutputFolder $out -Notes $notes -Body {
    Get-CimInstance Win32_Service -ErrorAction Stop |
        Where-Object { $_.StartMode -eq 'Auto' } |
        Select-Object Name, DisplayName, State, StartMode, StartName, PathName |
        Sort-Object Name
}

Invoke-FieldkitSection -Name 'Services running as a named account' -OutputFolder $out -Notes $notes -Body {
    # Service accounts are where privilege hides. Anything not running as one
    # of the built-in identities is worth a name and an owner.
    Get-CimInstance Win32_Service -ErrorAction Stop |
        Where-Object {
            $_.StartName -and
            $_.StartName -notin @('LocalSystem','NT AUTHORITY\LocalService','NT AUTHORITY\NetworkService')
        } |
        Select-Object Name, DisplayName, State, StartMode, StartName |
        Sort-Object StartName, Name
}

Invoke-FieldkitSection -Name 'Scheduled tasks not from Microsoft' -OutputFolder $out -Notes $notes -Body {
    Get-ScheduledTask -ErrorAction Stop |
        Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
        ForEach-Object {
            [pscustomobject]@{
                TaskName = $_.TaskName
                TaskPath = $_.TaskPath
                State    = $_.State
                RunAs    = $_.Principal.UserId
                RunLevel = $_.Principal.RunLevel
                Author   = $_.Author
                Actions  = ($_.Actions | ForEach-Object { $_.Execute } ) -join ' ; '
            }
        } | Sort-Object TaskPath, TaskName
}

# --------------------------------------------------------------- who can get in
Invoke-FieldkitSection -Name 'Local Administrators group' -OutputFolder $out -Notes $notes -Body {
    <#
        Queried by SID, not by name.

        "Administrators" is localized. On a Finnish machine the group is called
        Jarjestelmanvalvojat, on a German one Administratoren, and asking for
        the English name returns "group was not found" - which reads exactly
        like a machine with no local administrators. The SID S-1-5-32-544 is
        the same everywhere.
    #>
    $sid  = 'S-1-5-32-544'
    $name = $sid
    try { $name = ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value }
    catch { }

    try {
        Get-LocalGroupMember -SID $sid -ErrorAction Stop |
            Select-Object @{n='Group';e={$name}}, @{n='Member';e={$_.Name}}, ObjectClass, PrincipalSource
    }
    catch {
        # Get-LocalGroupMember also fails outright when a member SID no longer
        # resolves, which is common on a machine removed from a domain. ADSI
        # shows the raw entries instead of refusing the whole group.
        $local = ($name -split '\\')[-1]
        $grp = [ADSI]"WinNT://$env:COMPUTERNAME/$local,group"
        @($grp.Invoke('Members')) | ForEach-Object {
            [pscustomobject]@{
                Group           = $name
                Member          = $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null)
                ObjectClass     = $_.GetType().InvokeMember('Class', 'GetProperty', $null, $_, $null)
                PrincipalSource = 'read via ADSI fallback'
            }
        }
    }
}

Invoke-FieldkitSection -Name 'Local user accounts' -OutputFolder $out -Notes $notes -Body {
    Get-LocalUser -ErrorAction Stop |
        Select-Object Name, Enabled, LastLogon, PasswordLastSet, PasswordExpires,
                      PasswordRequired, UserMayChangePassword, Description
}

# --------------------------------------------------------------- network posture
Invoke-FieldkitSection -Name 'Firewall profiles' -OutputFolder $out -Notes $notes -Body {
    Get-NetFirewallProfile -ErrorAction Stop |
        Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction,
                      LogAllowed, LogBlocked, LogFileName
}

Invoke-FieldkitSection -Name 'SMB server configuration' -OutputFolder $out -Notes $notes -Body {
    Get-SmbServerConfiguration -ErrorAction Stop |
        Select-Object EnableSMB1Protocol, EnableSMB2Protocol,
                      RequireSecuritySignature, EnableSecuritySignature,
                      EncryptData, RejectUnencryptedAccess
}

Invoke-FieldkitSection -Name 'SMB shares' -OutputFolder $out -Notes $notes -Body {
    Get-SmbShare -ErrorAction Stop | Select-Object Name, Path, Description, ShareState, FolderEnumerationMode
}

Invoke-FieldkitSection -Name 'Listening TCP ports' -OutputFolder $out -Notes $notes -Body {
    $procs = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procs[$_.Id] = $_.ProcessName }
    Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Select-Object LocalAddress, LocalPort,
                      @{n='Process';e={ $procs[[int]$_.OwningProcess] }},
                      OwningProcess |
        Sort-Object LocalPort
}

Invoke-FieldkitSection -Name 'IP configuration' -OutputFolder $out -Notes $notes -Body {
    Get-NetIPConfiguration -ErrorAction Stop |
        ForEach-Object {
            [pscustomobject]@{
                InterfaceAlias = $_.InterfaceAlias
                IPv4Address    = ($_.IPv4Address.IPAddress -join ', ')
                IPv4Gateway    = ($_.IPv4DefaultGateway.NextHop -join ', ')
                DNSServers     = ($_.DNSServer | Where-Object { $_.AddressFamily -eq 2 } |
                                  ForEach-Object { $_.ServerAddresses }) -join ', '
                NetProfile     = $_.NetProfile.NetworkCategory
            }
        }
}

# --------------------------------------------------------------- can you investigate
Invoke-FieldkitSection -Name 'Event log size and retention' -OutputFolder $out -Notes $notes -Body {
    <#
        How far back an investigation could reach on this machine.

        This is worth collecting on every engagement. A Security log holding a
        few hours means that anything discovered later cannot be investigated
        here, and that is a finding in its own right rather than a detail of
        whatever you came to look at.
    #>
    $session = New-Object System.Diagnostics.Eventing.Reader.EventLogSession
    foreach ($name in @('Security','System','Application','Directory Service')) {
        $row = [ordered]@{
            LogName     = $name
            MaxSizeMB   = $null
            CurrentMB   = $null
            Records     = $null
            OldestEvent = $null
            NewestEvent = $null
            WindowDays  = $null
            Mode        = $null
            Status      = 'not read'
        }
        try {
            $cfg  = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration $name, $session
            $info = $session.GetLogInformation($name, [System.Diagnostics.Eventing.Reader.PathType]::LogName)
            $row.MaxSizeMB = [math]::Round($cfg.MaximumSizeInBytes / 1MB, 1)
            $row.CurrentMB = if ($null -ne $info.FileSize) { [math]::Round($info.FileSize / 1MB, 1) } else { $null }
            $row.Records   = $info.RecordCount
            $row.Mode      = $cfg.LogMode
            if ($info.RecordCount -gt 0) {
                $first = Get-WinEvent -LogName $name -MaxEvents 1 -Oldest -ErrorAction Stop
                $last  = Get-WinEvent -LogName $name -MaxEvents 1 -ErrorAction Stop
                $row.OldestEvent = $first.TimeCreated
                $row.NewestEvent = $last.TimeCreated
                $row.WindowDays  = [math]::Round((New-TimeSpan -Start $first.TimeCreated -End $last.TimeCreated).TotalDays, 2)
            }
            $row.Status = 'read'
        }
        catch {
            $row.Status = "NOT READ: $($_.Exception.Message)"
        }
        [pscustomobject]$row
    }
}

Invoke-FieldkitSection -Name 'Audit policy' -OutputFolder $out -Notes $notes -Body {
    # auditpol is a native tool, so its exit code is the only reliable signal.
    # Searching its output text for "No Auditing" when the command itself
    # failed reports "auditing is on" from an error message.
    $raw = & auditpol.exe /get /category:* 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -or -not ($raw -match 'Subcategory')) {
        throw "auditpol returned exit code $code. Usually this means the session is not elevated."
    }
    $raw | Where-Object { $_ -match '^\s{2,}\S' } | ForEach-Object {
        if ($_ -match '^\s+(.+?)\s{2,}(.+?)\s*$') {
            [pscustomobject]@{ Subcategory = $Matches[1].Trim(); Setting = $Matches[2].Trim() }
        }
    }
}

# --------------------------------------------------------------- summary
if (-not (Test-FieldkitElevation)) {
    $notes.Add('Re-run this elevated before treating the result as complete.')
}

Write-FieldkitSummary -Title 'Host Snapshot' -OutputFolder $out -Notes $notes
