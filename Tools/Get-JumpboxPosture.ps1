<#FIELDKIT
Name      : Jumpbox Posture
Category  : Jumpbox
Summary   : Audits this admin workstation as a privileged access workstation: platform trust, credential protection, execution control, exposure.
Requires  : None
Elevation : Required
Scope     : Local machine
Output    : JumpboxPosture
ReadOnly  : Yes
FIELDKIT#>

<#
    Get-JumpboxPosture.ps1

    The machine you are standing on.

    A jumpbox handles tier-0 credentials. If it is compromised, every
    credential that has ever been typed into it is compromised, and no amount
    of care taken with the servers downstream matters. It is also the one
    machine on an engagement that nobody audits, because it belongs to the
    person doing the auditing.

    This runs the same checks against it that you would run against a client's
    privileged workstation, and it is deliberately unflattering.

    ---------------------------------------------------------------------------
    WHAT IT DOES NOT READ

    Two things are detected and never read:

      * The autologon password value under Winlogon. Its presence is reported;
        the value is not. Putting a cleartext password into a CSV that then
        travels is a worse outcome than the finding.
      * LAPS-managed passwords. The configuration is read, the secrets are not.

    ---------------------------------------------------------------------------
    ELEVATION

    Run it elevated. BitLocker, TPM, Secure Boot, the optional-feature state
    and the audit policy are all unreadable without administrator rights.

    It does not refuse when unelevated, because a partial read still tells you
    something and refusing tells you nothing. What it does instead is report
    every unreadable control as UNKNOWN and say plainly, in the console and at
    the top of SUMMARY.txt, that the run is not an assessment. UNKNOWN is not a
    pass anywhere in this kit, and it is not one here.

    READ-ONLY. Registry and CIM reads, plus dsregcmd /status, which reports
    and changes nothing.
#>

[CmdletBinding()]
param()

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Lib\Fieldkit.Common.ps1')

$out   = New-FieldkitOutputFolder -ToolOutputName 'JumpboxPosture'
$notes = [System.Collections.Generic.List[string]]::new()

Write-FieldkitHeader -Title 'Jumpbox Posture' -OutputFolder $out

$elevated = Test-FieldkitElevation

# --------------------------------------------------------------------------
# The verdict list.
#
# Every control lands here with one of three states. UNKNOWN is a first-class
# answer: a control whose state could not be established is not a control that
# is absent, and it is certainly not one that is present.
# --------------------------------------------------------------------------
$controls = [System.Collections.Generic.List[object]]::new()

function Add-Control {
    param(
        [Parameter(Mandatory)] [string] $Area,
        [Parameter(Mandatory)] [string] $Control,
        [Parameter(Mandatory)] [ValidateSet('OK','WEAK','UNKNOWN','INFO')] [string] $State,
        [string] $Detail,
        [string] $Why
    )
    $controls.Add([pscustomobject]@{
        Area = $Area; Control = $Control; State = $State; Detail = $Detail; Why = $Why
    })
}

if (-not $elevated) {
    Write-Host '  NOT ELEVATED. This will not be a posture assessment.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  BitLocker, TPM, Secure Boot, the optional-feature state and the audit' -ForegroundColor Yellow
    Write-Host '  policy cannot be read without administrator rights. Those controls'    -ForegroundColor Yellow
    Write-Host '  will come back UNKNOWN, which is NOT a pass.'                          -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  It runs anyway, because a partial read is still useful and because'     -ForegroundColor DarkGray
    Write-Host '  refusing outright would tell you less than this does. But do not read'  -ForegroundColor DarkGray
    Write-Host '  the result as an assessment: re-run it elevated.'                       -ForegroundColor DarkGray
    Write-Host ''
    $notes.Add('SESSION WAS NOT ELEVATED. This run is NOT a posture assessment. Controls reported UNKNOWN below were not measured, and several of the most important ones are in that group. Re-run elevated.')
    Add-Control -Area 'Administration' -Control 'Assessment was run with sufficient rights' -State 'UNKNOWN' `
        -Detail 'session was not elevated' `
        -Why 'The platform trust and encryption controls could not be read at all. Treat this whole run as incomplete.'
}

function Get-Reg {
    <# One registry value, or $null, without throwing on a missing key. #>
    param([string] $Path, [string] $Name)
    try {
        $k = Get-ItemProperty -Path $Path -ErrorAction Stop
        if ($k.PSObject.Properties.Name -contains $Name) { return $k.$Name }
        return $null
    }
    catch { return $null }
}

function Test-RegValueExists {
    param([string] $Path, [string] $Name)
    try {
        $k = Get-ItemProperty -Path $Path -ErrorAction Stop
        return ($k.PSObject.Properties.Name -contains $Name)
    }
    catch { return $false }
}

# ============================================================ 1. the machine
Invoke-FieldkitSection -Name 'Windows version and servicing' -OutputFolder $out -Notes $notes -Body {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $build = [int]$cv.CurrentBuild

    # Windows 11 is build 22000 and above. Anything lower on a machine calling
    # itself a jumpbox is a finding before any control is examined.
    $family =
        if ($build -ge 22000) { 'Windows 11' }
        elseif ($build -ge 10240) { 'Windows 10' }
        else { 'earlier than Windows 10' }

    if ($build -lt 22000) {
        Add-Control -Area 'Platform' -Control 'Supported Windows version' -State 'WEAK' `
            -Detail "$family build $build" `
            -Why 'Windows 10 left support on 14 October 2025. Unless ESU is being paid for, an unpatched machine is holding tier-0 credentials.'
    }
    else {
        Add-Control -Area 'Platform' -Control 'Supported Windows version' -State 'OK' `
            -Detail "$family $($cv.DisplayVersion) build $build.$($cv.UBR)" `
            -Why 'Servicing windows differ by edition: 24 months for Pro, 36 for Enterprise and Education. Confirm this release is still serviced.'
    }

    [pscustomobject]@{
        ComputerName   = $env:COMPUTERNAME
        Family         = $family
        Edition        = $cv.EditionID
        ProductName    = $cv.ProductName
        DisplayVersion = $cv.DisplayVersion
        Build          = $cv.CurrentBuild
        UBR            = $cv.UBR
        InstallDate    = $os.InstallDate
        LastBootUpTime = $os.LastBootUpTime
        UptimeDays     = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
        Domain         = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Domain
    }
}

# ================================================= 2. platform trust
Invoke-FieldkitSection -Name 'Secure Boot, TPM and DMA protection' -OutputFolder $out -Notes $notes -Body {
    $rows = [System.Collections.Generic.List[object]]::new()

    # Secure Boot. On a legacy BIOS machine the cmdlet throws rather than
    # returning false, and those are different answers.
    $sb = 'UNKNOWN'; $sbDetail = ''
    try {
        $sb = if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'enabled' } else { 'DISABLED' }
    }
    catch {
        $sbDetail = $_.Exception.Message
        $sb = if ($sbDetail -match 'not supported') { 'not supported (legacy BIOS)' } else { 'UNKNOWN' }
    }
    $rows.Add([pscustomobject]@{ Check = 'Secure Boot'; Value = $sb; Detail = $sbDetail })
    Add-Control -Area 'Platform' -Control 'Secure Boot' `
        -State $(if ($sb -eq 'enabled') { 'OK' } elseif ($sb -eq 'UNKNOWN') { 'UNKNOWN' } else { 'WEAK' }) `
        -Detail $sb -Why 'Without Secure Boot, the boot chain is unverified and virtualization-based security cannot be trusted.'

    # TPM.
    #
    # Get-Tpm does NOT throw when it lacks rights. It returns an object with
    # every property empty, so a naive check reads "TpmPresent is not true"
    # and reports a machine with a healthy TPM as having none. The empty case
    # is therefore tested explicitly, and it is UNKNOWN rather than WEAK.
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $measured = ($null -ne $tpm -and $null -ne $tpm.TpmPresent -and "$($tpm.TpmPresent)" -ne '')

        if (-not $measured) {
            $rows.Add([pscustomobject]@{
                Check = 'TPM'; Value = 'UNKNOWN'
                Detail = 'Get-Tpm returned an object with empty properties, which is what it does without administrator rights. It does not throw.'
            })
            Add-Control -Area 'Platform' -Control 'TPM present and ready' -State 'UNKNOWN' `
                -Detail 'Get-Tpm returned empty values (needs elevation; it does not throw)' `
                -Why 'Not measured. A TPM may well be present and healthy.'
        }
        else {
            $rows.Add([pscustomobject]@{
                Check = 'TPM'
                Value = "present=$($tpm.TpmPresent) ready=$($tpm.TpmReady) enabled=$($tpm.TpmEnabled)"
                Detail = "ManufacturerVersion=$($tpm.ManufacturerVersion)"
            })
            Add-Control -Area 'Platform' -Control 'TPM present and ready' `
                -State $(if ($tpm.TpmPresent -and $tpm.TpmReady) { 'OK' } else { 'WEAK' }) `
                -Detail "present=$($tpm.TpmPresent) ready=$($tpm.TpmReady)" `
                -Why 'BitLocker without a TPM falls back to a password or a USB key, and Credential Guard key protection depends on it.'
        }
    }
    catch {
        $rows.Add([pscustomobject]@{ Check = 'TPM'; Value = 'UNKNOWN'; Detail = $_.Exception.Message })
        Add-Control -Area 'Platform' -Control 'TPM present and ready' -State 'UNKNOWN' `
            -Detail $_.Exception.Message -Why 'Could not be read. Not the same as absent.'
    }

    # Kernel DMA protection. Thunderbolt and other DMA-capable ports are a
    # physical attack path on a portable admin machine.
    $dma = Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DmaSecurity' 'DeviceEnumerationPolicy'
    $rows.Add([pscustomobject]@{ Check = 'Kernel DMA policy'; Value = $(if ($null -ne $dma) { $dma } else { 'not configured' }); Detail = '0=block all, 1=allow after logon, 2=allow always' })

    $rows
}

Invoke-FieldkitSection -Name 'Virtualization-based security' -OutputFolder $out -Notes $notes -Body {
    <#
        VBS, HVCI (memory integrity) and Credential Guard.

        The raw numbers from Win32_DeviceGuard mean nothing on their own, so
        they are decoded. Credential Guard is the one that matters most here:
        with it running, LSASS secrets are held in a VBS container and the
        usual credential-dumping path does not work.
    #>
    $dg = $null
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' `
                              -ClassName Win32_DeviceGuard -ErrorAction Stop
    }
    catch {
        Add-Control -Area 'Credentials' -Control 'Credential Guard' -State 'UNKNOWN' `
            -Detail $_.Exception.Message -Why 'The DeviceGuard namespace could not be queried, so nothing is known either way.'
        Add-Control -Area 'Platform' -Control 'Memory integrity (HVCI)' -State 'UNKNOWN' `
            -Detail $_.Exception.Message -Why 'Not read.'
        throw
    }

    $vbsStatus = switch ([int]$dg.VirtualizationBasedSecurityStatus) {
        0 { '0 = not enabled' } 1 { '1 = enabled but NOT running' } 2 { '2 = enabled and running' }
        default { "$($dg.VirtualizationBasedSecurityStatus) = unrecognized" }
    }
    $running = @($dg.SecurityServicesRunning)
    $configured = @($dg.SecurityServicesConfigured)
    $svcName = { param($n) switch ([int]$n) {
        1 { 'Credential Guard' } 2 { 'HVCI / memory integrity' } 3 { 'System Guard Secure Launch' }
        4 { 'SMM Firmware Measurement' } 5 { 'Kernel-mode Hardware-enforced Stack Protection' }
        default { "service $n" } } }

    $cgRunning   = $running -contains 1
    $hvciRunning = $running -contains 2

    Add-Control -Area 'Credentials' -Control 'Credential Guard running' `
        -State $(if ($cgRunning) { 'OK' } else { 'WEAK' }) `
        -Detail "VBS: $vbsStatus; running services: $(($running | ForEach-Object { & $svcName $_ }) -join ', ')" `
        -Why 'Without it, LSASS holds secrets in ordinary memory and any administrator on this box can harvest every credential used from it.'

    Add-Control -Area 'Platform' -Control 'Memory integrity (HVCI)' `
        -State $(if ($hvciRunning) { 'OK' } else { 'WEAK' }) `
        -Detail $(if ($hvciRunning) { 'running' } else { 'not running' }) `
        -Why 'HVCI blocks unsigned kernel code, which is the usual route to disabling the rest of these controls.'

    $ci = switch ([int]$dg.CodeIntegrityPolicyEnforcementStatus) {
        0 { '0 = off' } 1 { '1 = audit mode' } 2 { '2 = enforced' }
        default { "$($dg.CodeIntegrityPolicyEnforcementStatus) = unrecognized" }
    }
    Add-Control -Area 'Execution' -Control 'WDAC / code integrity policy' `
        -State $(if ([int]$dg.CodeIntegrityPolicyEnforcementStatus -eq 2) { 'OK' }
                 elseif ([int]$dg.CodeIntegrityPolicyEnforcementStatus -eq 1) { 'WEAK' } else { 'WEAK' }) `
        -Detail $ci -Why 'An admin workstation is the best possible candidate for application control, because its software set is small and known.'

    [pscustomobject]@{
        VirtualizationBasedSecurityStatus = $vbsStatus
        AvailableSecurityProperties       = ($dg.AvailableSecurityProperties -join ', ')
        SecurityServicesConfigured        = (($configured | ForEach-Object { & $svcName $_ }) -join ', ')
        SecurityServicesRunning           = (($running    | ForEach-Object { & $svcName $_ }) -join ', ')
        CodeIntegrityPolicyEnforcement    = $ci
        UsermodeCodeIntegrityPolicyEnforcement = $dg.UsermodeCodeIntegrityPolicyEnforcementStatus
        RequiredSecurityProperties        = ($dg.RequiredSecurityProperties -join ', ')
    }
}

# ================================================= 3. disk encryption
Invoke-FieldkitSection -Name 'BitLocker' -OutputFolder $out -Notes $notes -Body {
    $vols = @(Get-BitLockerVolume -ErrorAction Stop)
    $osVol = $vols | Where-Object { $_.VolumeType -eq 'OperatingSystem' } | Select-Object -First 1

    if ($osVol) {
        $on = ($osVol.ProtectionStatus -eq 'On')
        Add-Control -Area 'Platform' -Control 'BitLocker on the OS volume' `
            -State $(if ($on) { 'OK' } else { 'WEAK' }) `
            -Detail "status=$($osVol.ProtectionStatus) method=$($osVol.EncryptionMethod) protectors=$(($osVol.KeyProtector.KeyProtectorType) -join ',')" `
            -Why 'An unencrypted admin workstation gives up its cached credentials and saved output to anyone who takes the disk.'
    }
    else {
        Add-Control -Area 'Platform' -Control 'BitLocker on the OS volume' -State 'UNKNOWN' `
            -Detail 'no OperatingSystem volume returned' -Why 'Not read.'
    }

    $vols | ForEach-Object {
        [pscustomobject]@{
            MountPoint       = $_.MountPoint
            VolumeType       = $_.VolumeType
            ProtectionStatus = $_.ProtectionStatus
            LockStatus       = $_.LockStatus
            EncryptionMethod = $_.EncryptionMethod
            PercentEncrypted = $_.EncryptionPercentage
            KeyProtectors    = ($_.KeyProtector.KeyProtectorType) -join ', '
        }
    }
}

# ================================================= 4. credential protection
Invoke-FieldkitSection -Name 'Credential protection settings' -OutputFolder $out -Notes $notes -Body {
    $rows = [System.Collections.Generic.List[object]]::new()
    $lsa   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $wdig  = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
    $wlogon= 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

    # LSA protection. RunAsPPL makes LSASS a protected process, which blocks
    # the ordinary handle-open used to read its memory.
    $ppl     = Get-Reg $lsa 'RunAsPPL'
    $pplBoot = Get-Reg $lsa 'RunAsPPLBoot'
    $rows.Add([pscustomobject]@{ Setting = 'RunAsPPL'; Value = $ppl; Meaning = '1 or 2 = LSASS runs as a protected process' })
    $rows.Add([pscustomobject]@{ Setting = 'RunAsPPLBoot'; Value = $pplBoot; Meaning = 'UEFI-locked variant' })
    Add-Control -Area 'Credentials' -Control 'LSA protection (RunAsPPL)' `
        -State $(if ($ppl -ge 1) { 'OK' } else { 'WEAK' }) `
        -Detail "RunAsPPL=$(if ($null -ne $ppl) { $ppl } else { 'not set' })" `
        -Why 'Without it, any process running as administrator can open LSASS and read every credential in it.'

    # WDigest. Setting UseLogonCredential to 1 puts cleartext passwords back
    # into LSASS, and it is still found in the wild on machines that were once
    # troubleshooted and never reverted.
    $ulc = Get-Reg $wdig 'UseLogonCredential'
    $rows.Add([pscustomobject]@{ Setting = 'WDigest UseLogonCredential'; Value = $ulc; Meaning = '1 = CLEARTEXT passwords cached in memory. 0 or absent is correct' })
    Add-Control -Area 'Credentials' -Control 'WDigest cleartext caching off' `
        -State $(if ($ulc -eq 1) { 'WEAK' } else { 'OK' }) `
        -Detail "UseLogonCredential=$(if ($null -ne $ulc) { $ulc } else { 'not set (correct)' })" `
        -Why 'A value of 1 restores cleartext password caching in LSASS.'

    # LM hash storage
    $noLM = Get-Reg $lsa 'NoLmHash'
    $rows.Add([pscustomobject]@{ Setting = 'NoLmHash'; Value = $noLM; Meaning = '1 = LM hashes are not stored' })

    # Cached domain logons. On a jumpbox this should be small; each cached
    # logon is a credential verifier sitting on the disk.
    $cached = Get-Reg $wlogon 'CachedLogonsCount'
    $rows.Add([pscustomobject]@{ Setting = 'CachedLogonsCount'; Value = $cached; Meaning = 'number of domain logons cached locally' })
    Add-Control -Area 'Credentials' -Control 'Cached domain logons limited' `
        -State $(if ($null -eq $cached) { 'WEAK' } elseif ([int]$cached -le 2) { 'OK' } else { 'WEAK' }) `
        -Detail "CachedLogonsCount=$(if ($null -ne $cached) { $cached } else { 'not set, defaults to 10' })" `
        -Why 'Each cached logon is a credential verifier on the disk. On a privileged workstation this should be 0 to 2.'

    # Autologon. The PRESENCE of a stored password is reported; the value is
    # deliberately not read, because a cleartext password written into a CSV
    # that then travels is a worse outcome than the finding.
    $autoAdmin = Get-Reg $wlogon 'AutoAdminLogon'
    $hasPw     = Test-RegValueExists $wlogon 'DefaultPassword'
    $rows.Add([pscustomobject]@{
        Setting = 'AutoAdminLogon'; Value = $autoAdmin
        Meaning = "1 = automatic logon enabled. DefaultPassword value present: $hasPw (value NOT read by design)"
    })
    if ($autoAdmin -eq 1 -or $hasPw) {
        Add-Control -Area 'Credentials' -Control 'No automatic logon' -State 'WEAK' `
            -Detail "AutoAdminLogon=$autoAdmin, DefaultPassword present=$hasPw" `
            -Why 'A stored logon password on a privileged workstation is readable by any local administrator. The value was deliberately not collected.'
    }
    else {
        Add-Control -Area 'Credentials' -Control 'No automatic logon' -State 'OK' -Detail 'not configured' -Why ''
    }

    # Smartcard / Windows Hello enforcement for interactive logon
    $scForce = Get-Reg $lsa 'SCForceOption'
    $rows.Add([pscustomobject]@{ Setting = 'SCForceOption'; Value = $scForce; Meaning = '1 = smartcard required for interactive logon' })

    # Credential delegation. Unconstrained delegation of fresh credentials to
    # arbitrary hosts is how a jumpbox leaks its own credentials outward.
    $credDelKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation'
    foreach ($v in @('AllowDefaultCredentials','AllowFreshCredentials','AllowSavedCredentials',
                     'AllowDefCredentialsWhenNTLMOnly','RestrictedRemoteAdministration')) {
        $rows.Add([pscustomobject]@{ Setting = "CredentialsDelegation\$v"; Value = (Get-Reg $credDelKey $v); Meaning = '' })
    }
    $rra = Get-Reg $credDelKey 'RestrictedRemoteAdministration'
    Add-Control -Area 'Credentials' -Control 'Restricted Admin / Remote Credential Guard for outbound RDP' `
        -State $(if ($rra -eq 1) { 'OK' } else { 'WEAK' }) `
        -Detail "RestrictedRemoteAdministration=$(if ($null -ne $rra) { $rra } else { 'not set' })" `
        -Why 'Without it, an RDP session from this jumpbox leaves reusable credentials on the server you connect to, which is the wrong direction of trust.'

    $rows
}

Invoke-FieldkitSection -Name 'This session and this account' -OutputFolder $out -Notes $notes -Body {
    <#
        Is the account being used here a privileged domain account?

        A jumpbox used with a tier-0 account for general work is the single
        most common way a well-built privileged workstation stops being one.
    #>
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $groups = @()
    foreach ($g in $id.Groups) {
        $name = $null
        try { $name = $g.Translate([Security.Principal.NTAccount]).Value } catch { $name = $g.Value }
        $groups += [pscustomobject]@{ Sid = $g.Value; Name = $name }
    }

    # Domain Admins (-512), Enterprise Admins (-519), Schema Admins (-518),
    # local Administrators (S-1-5-32-544).
    $privSids = @($groups | Where-Object {
        $_.Sid -match '-(512|518|519|520|521|526|527)$' -or $_.Sid -eq 'S-1-5-32-544'
    })
    $tier0 = @($groups | Where-Object { $_.Sid -match '-(512|518|519)$' })

    if ($tier0.Count) {
        Add-Control -Area 'Administration' -Control 'Token does not hold forest-level privilege' -State 'WEAK' `
            -Detail "this token holds: $(($tier0.Name) -join ', ')" `
            -Why 'A session holding Domain, Enterprise or Schema Admin puts those credentials in this machine memory. Use a scoped account and elevate only where needed.'
    }
    else {
        Add-Control -Area 'Administration' -Control 'Token does not hold forest-level privilege' -State 'OK' `
            -Detail 'no Domain/Enterprise/Schema Admin SID in this token' -Why ''
    }

    # Entra / hybrid join state. dsregcmd is a native tool, so the exit code
    # is the only trustworthy signal that it ran.
    $dsreg = & dsregcmd.exe /status 2>&1
    $code = $LASTEXITCODE
    $joinState = if ($code -ne 0) { "NOT READ: dsregcmd exit $code" }
                 else {
                     $az = ($dsreg | Select-String 'AzureAdJoined\s*:\s*(\S+)').Matches.Groups[1].Value
                     $dj = ($dsreg | Select-String 'DomainJoined\s*:\s*(\S+)').Matches.Groups[1].Value
                     "AzureAdJoined=$az DomainJoined=$dj"
                 }

    [pscustomobject]@{
        Account          = "$($env:USERDOMAIN)\$($env:USERNAME)"
        Sid              = $id.User.Value
        AuthenticationType = $id.AuthenticationType
        IsSystem         = $id.IsSystem
        Elevated         = Test-FieldkitElevation
        PrivilegedGroups = ($privSids.Name) -join '; '
        JoinState        = $joinState
        GroupCount       = $groups.Count
    }
}

Invoke-FieldkitSection -Name 'Token group membership' -OutputFolder $out -Notes $notes -Body {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    foreach ($g in $id.Groups) {
        $name = $null
        try { $name = $g.Translate([Security.Principal.NTAccount]).Value } catch { $name = '(SID does not resolve)' }
        [pscustomobject]@{ Sid = $g.Value; Name = $name }
    }
}

# ================================================= 5. endpoint protection
Invoke-FieldkitSection -Name 'Registered antivirus products' -OutputFolder $out -Notes $notes -Body {
    # SecurityCenter2 lists every registered product, which is how you see a
    # third-party EDR alongside Defender in passive mode. productState is a
    # bit field that Microsoft does not document, so it is reported raw rather
    # than decoded into a claim that might be wrong.
    Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop |
        Select-Object displayName, pathToSignedProductExe, timestamp,
                      @{n='productState_raw';e={ $_.productState }},
                      @{n='productState_hex';e={ '0x{0:X6}' -f $_.productState }}
}

Invoke-FieldkitSection -Name 'Microsoft Defender state' -OutputFolder $out -Notes $notes -Body {
    $st = Get-MpComputerStatus -ErrorAction Stop
    $pf = Get-MpPreference -ErrorAction SilentlyContinue

    # AMRunningMode tells you whether Defender is the active AV, is passive
    # behind a third-party EDR, or is disabled. Reporting "real-time
    # protection off" without that context produces a false finding on any
    # machine running a third-party EDR.
    Add-Control -Area 'Endpoint' -Control 'Anti-malware engine running' `
        -State $(if ($st.AMRunningMode -eq 'Normal' -or $st.AMRunningMode -like 'Passive*') { 'OK' } else { 'WEAK' }) `
        -Detail "AMRunningMode=$($st.AMRunningMode)" `
        -Why 'Passive mode is correct when a third-party EDR is the active product. Note that ASR rules do NOT function in passive mode.'

    Add-Control -Area 'Endpoint' -Control 'Tamper protection' `
        -State $(if ($st.IsTamperProtected) { 'OK' } else { 'WEAK' }) `
        -Detail "IsTamperProtected=$($st.IsTamperProtected)" `
        -Why 'Without it, a local administrator can turn the protection off before doing anything else.'

    [pscustomobject]@{
        AMRunningMode             = $st.AMRunningMode
        AMServiceEnabled          = $st.AMServiceEnabled
        RealTimeProtectionEnabled = $st.RealTimeProtectionEnabled
        BehaviorMonitorEnabled    = $st.BehaviorMonitorEnabled
        IsTamperProtected         = $st.IsTamperProtected
        AntivirusSignatureAge     = $st.AntivirusSignatureAge
        AntivirusSignatureLastUpdated = $st.AntivirusSignatureLastUpdated
        MAPSReporting             = $pf.MAPSReporting
        SubmitSamplesConsent      = $pf.SubmitSamplesConsent
        PUAProtection             = $pf.PUAProtection
        EnableControlledFolderAccess = $pf.EnableControlledFolderAccess
        EnableNetworkProtection   = $pf.EnableNetworkProtection
        ASRRulesConfigured        = @($pf.AttackSurfaceReductionRules_Ids).Count
    }
}

Invoke-FieldkitSection -Name 'Attack surface reduction rules' -OutputFolder $out -Notes $notes -Body {
    $pf = Get-MpPreference -ErrorAction Stop
    $ids = @($pf.AttackSurfaceReductionRules_Ids)
    $acts = @($pf.AttackSurfaceReductionRules_Actions)

    if ($ids.Count -eq 0) {
        Add-Control -Area 'Endpoint' -Control 'ASR rules configured' -State 'WEAK' `
            -Detail 'none configured' `
            -Why 'ASR is free with the OS. Note it does not function while Defender is in passive mode behind a third-party EDR.'
        return
    }

    Add-Control -Area 'Endpoint' -Control 'ASR rules configured' -State 'INFO' `
        -Detail "$($ids.Count) rule(s) configured" `
        -Why 'Check the action per rule: audit mode records and blocks nothing.'

    for ($i = 0; $i -lt $ids.Count; $i++) {
        $action = switch ([int]$acts[$i]) {
            0 { 'disabled' } 1 { 'block' } 2 { 'audit only' } 6 { 'warn' }
            default { "action $($acts[$i])" }
        }
        [pscustomobject]@{ RuleId = $ids[$i]; Action = $action }
    }
}

# ================================================= 6. exposure
Invoke-FieldkitSection -Name 'Inbound remote access' -OutputFolder $out -Notes $notes -Body {
    $rows = [System.Collections.Generic.List[object]]::new()
    $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'

    $deny = Get-Reg $ts 'fDenyTSConnections'
    $nla  = Get-Reg "$ts\WinStations\RDP-Tcp" 'UserAuthentication'
    $sl   = Get-Reg "$ts\WinStations\RDP-Tcp" 'SecurityLayer'
    $rdpOn = ($deny -eq 0)

    $rows.Add([pscustomobject]@{ Check = 'RDP enabled'; Value = $rdpOn; Detail = "fDenyTSConnections=$deny" })
    $rows.Add([pscustomobject]@{ Check = 'NLA required';  Value = ($nla -eq 1); Detail = "UserAuthentication=$nla" })
    $rows.Add([pscustomobject]@{ Check = 'Security layer'; Value = $sl; Detail = '0=RDP, 1=negotiate, 2=TLS' })

    if ($rdpOn) {
        Add-Control -Area 'Exposure' -Control 'Inbound RDP requires NLA' `
            -State $(if ($nla -eq 1) { 'OK' } else { 'WEAK' }) `
            -Detail "RDP enabled, UserAuthentication=$nla" `
            -Why 'A jumpbox reachable by RDP without network level authentication can be attacked before authentication.'
    }
    else {
        Add-Control -Area 'Exposure' -Control 'Inbound RDP requires NLA' -State 'OK' `
            -Detail 'inbound RDP is disabled' -Why ''
    }

    # WinRM listeners
    try {
        $listeners = @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop)
        foreach ($l in $listeners) {
            $cfg = Get-ChildItem "WSMan:\localhost\Listener\$($l.Name)" -ErrorAction SilentlyContinue
            $rows.Add([pscustomobject]@{
                Check = 'WinRM listener'; Value = $l.Name
                Detail = (($cfg | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ')
            })
        }
        if ($listeners.Count -eq 0) {
            $rows.Add([pscustomobject]@{ Check = 'WinRM listener'; Value = 'none'; Detail = 'WinRM is not listening' })
        }
    }
    catch {
        $rows.Add([pscustomobject]@{ Check = 'WinRM listener'; Value = 'NOT READ'; Detail = $_.Exception.Message })
    }

    # SMB server. A jumpbox has no business serving files.
    try {
        $smb = Get-SmbServerConfiguration -ErrorAction Stop
        $rows.Add([pscustomobject]@{ Check = 'SMB1 enabled'; Value = $smb.EnableSMB1Protocol; Detail = '' })
        $rows.Add([pscustomobject]@{ Check = 'SMB signing required'; Value = $smb.RequireSecuritySignature; Detail = '' })
        Add-Control -Area 'Exposure' -Control 'SMBv1 disabled' `
            -State $(if ($smb.EnableSMB1Protocol) { 'WEAK' } else { 'OK' }) `
            -Detail "EnableSMB1Protocol=$($smb.EnableSMB1Protocol)" `
            -Why 'There is no configuration that makes SMBv1 safe.'
    }
    catch {
        $rows.Add([pscustomobject]@{ Check = 'SMB server config'; Value = 'NOT READ'; Detail = $_.Exception.Message })
    }

    $rows
}

Invoke-FieldkitSection -Name 'Firewall profiles' -OutputFolder $out -Notes $notes -Body {
    <#
        Read from the ActiveStore, which is the EFFECTIVE merged value.

        The default store returns "NotConfigured" for anything no policy has
        explicitly set, and Windows blocks inbound by default. Treating
        NotConfigured as a failure reports a correctly firewalled machine as
        wide open, which is a false finding of exactly the kind this kit exists
        to avoid. Both values are reported, because "no policy sets this" and
        "policy sets this to block" are genuinely different situations even
        when the effective result is the same.
    #>
    $configured = @(Get-NetFirewallProfile -ErrorAction Stop)
    $effective  = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)

    $allOn    = @($effective | Where-Object { -not $_.Enabled }).Count -eq 0
    $notBlock = @($effective | Where-Object { $_.DefaultInboundAction -ne 'Block' })
    $unknown  = @($notBlock | Where-Object { $_.DefaultInboundAction -eq 'NotConfigured' })

    $state =
        if ($allOn -and $notBlock.Count -eq 0) { 'OK' }
        elseif ($unknown.Count -eq $notBlock.Count -and $notBlock.Count -gt 0) { 'UNKNOWN' }
        else { 'WEAK' }

    Add-Control -Area 'Exposure' -Control 'Firewall enabled on all profiles, inbound blocked by default' `
        -State $state `
        -Detail ("enabled on all profiles=$allOn; effective inbound action: " +
                 (($effective | ForEach-Object { "$($_.Name)=$($_.DefaultInboundAction)" }) -join ', ')) `
        -Why 'A privileged workstation should accept nothing it did not ask for. Read from the ActiveStore, so this is the effective value, not the policy value.'

    foreach ($e in $effective) {
        $c = $configured | Where-Object { $_.Name -eq $e.Name } | Select-Object -First 1
        [pscustomobject]@{
            Name                    = $e.Name
            Enabled                 = $e.Enabled
            InboundAction_Effective = $e.DefaultInboundAction
            InboundAction_Configured = $c.DefaultInboundAction
            OutboundAction_Effective = $e.DefaultOutboundAction
            AllowInboundRules       = $e.AllowInboundRules
            LogBlocked              = $e.LogBlocked
            LogFileName             = $e.LogFileName
        }
    }
}

Invoke-FieldkitSection -Name 'Inbound firewall rules allowing any remote address' -OutputFolder $out -Notes $notes -Body {
    # The rules that actually create exposure, rather than all several hundred.
    Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction Stop |
        ForEach-Object {
            $af = $_ | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
            $pf = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            if ($af.RemoteAddress -contains 'Any') {
                [pscustomobject]@{
                    DisplayName = $_.DisplayName
                    Profile     = $_.Profile
                    Protocol    = $pf.Protocol
                    LocalPort   = ($pf.LocalPort -join ',')
                    Program     = ($_ | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
                    Group       = $_.DisplayGroup
                }
            }
        } | Sort-Object DisplayName
}

# ================================================= 7. execution and logging
Invoke-FieldkitSection -Name 'PowerShell logging and execution policy' -OutputFolder $out -Notes $notes -Body {
    $rows = [System.Collections.Generic.List[object]]::new()
    $base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'

    $sbl = Get-Reg "$base\ScriptBlockLogging" 'EnableScriptBlockLogging'
    $ml  = Get-Reg "$base\ModuleLogging" 'EnableModuleLogging'
    $tr  = Get-Reg "$base\Transcription" 'EnableTranscripting'
    $trDir = Get-Reg "$base\Transcription" 'OutputDirectory'

    $rows.Add([pscustomobject]@{ Setting = 'ScriptBlockLogging'; Value = $sbl; Detail = 'events 4104 in Microsoft-Windows-PowerShell/Operational' })
    $rows.Add([pscustomobject]@{ Setting = 'ModuleLogging';      Value = $ml;  Detail = '' })
    $rows.Add([pscustomobject]@{ Setting = 'Transcription';      Value = $tr;  Detail = "OutputDirectory=$trDir" })

    Add-Control -Area 'Logging' -Control 'PowerShell script block logging' `
        -State $(if ($sbl -eq 1) { 'OK' } else { 'WEAK' }) `
        -Detail "EnableScriptBlockLogging=$(if ($null -ne $sbl) { $sbl } else { 'not set' })" `
        -Why 'On the machine all administration is run from, this is the highest-value log there is. It also records YOUR work, which is a feature: it is the evidence of what was run during an engagement.'

    Add-Control -Area 'Logging' -Control 'PowerShell transcription' `
        -State $(if ($tr -eq 1) { 'OK' } else { 'WEAK' }) `
        -Detail "EnableTranscripting=$(if ($null -ne $tr) { $tr } else { 'not set' }), dir=$trDir" `
        -Why 'A transcript of an engagement session is the cheapest possible run record. Point it somewhere outside C:\work.'

    foreach ($scope in @('MachinePolicy','UserPolicy','Process','CurrentUser','LocalMachine')) {
        $rows.Add([pscustomobject]@{
            Setting = "ExecutionPolicy ($scope)"
            Value = (Get-ExecutionPolicy -Scope $scope -ErrorAction SilentlyContinue)
            Detail = ''
        })
    }

    $rows.Add([pscustomobject]@{ Setting = 'PSVersion'; Value = $PSVersionTable.PSVersion.ToString(); Detail = "Edition=$($PSVersionTable.PSEdition)" })
    $rows
}

Invoke-FieldkitSection -Name 'PowerShell v2 engine' -OutputFolder $out -Notes $notes -Body {
    # The v2 engine bypasses script block logging, AMSI and constrained
    # language entirely. On an admin workstation it should not be installed.
    $f = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop |
           Where-Object { $_.FeatureName -like 'MicrosoftWindowsPowerShellV2*' })
    $enabled = @($f | Where-Object { $_.State -eq 'Enabled' })

    Add-Control -Area 'Execution' -Control 'PowerShell v2 engine removed' `
        -State $(if ($enabled.Count -eq 0) { 'OK' } else { 'WEAK' }) `
        -Detail (($f | ForEach-Object { "$($_.FeatureName)=$($_.State)" }) -join '; ') `
        -Why 'The v2 engine bypasses script block logging, AMSI and constrained language. It is a one-line downgrade attack.'

    $f | Select-Object FeatureName, State
}

Invoke-FieldkitSection -Name 'AppLocker policy' -OutputFolder $out -Notes $notes -Body {
    $p = Get-AppLockerPolicy -Effective -ErrorAction Stop
    $collections = @($p.RuleCollections)
    if ($collections.Count -eq 0) {
        Add-Control -Area 'Execution' -Control 'AppLocker or WDAC in place' -State 'WEAK' `
            -Detail 'no effective AppLocker rule collections' `
            -Why 'An admin workstation runs a small, known set of software, which makes it the easiest machine in the estate to put under application control.'
        return
    }
    Add-Control -Area 'Execution' -Control 'AppLocker or WDAC in place' -State 'INFO' `
        -Detail "$($collections.Count) rule collection(s). Check enforcement mode per collection." -Why ''

    $collections | ForEach-Object {
        [pscustomobject]@{
            RuleCollectionType = $_.RuleCollectionType
            EnforcementMode    = $_.EnforcementMode
            RuleCount          = @($_).Count
        }
    }
}

Invoke-FieldkitSection -Name 'Audit policy' -OutputFolder $out -Notes $notes -Body {
    $raw = & auditpol.exe /get /category:* 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -or -not ($raw -match 'Subcategory')) {
        throw "auditpol returned exit code $code"
    }
    $raw | ForEach-Object {
        if ($_ -match '^\s+(.+?)\s{2,}(.+?)\s*$') {
            [pscustomobject]@{ Subcategory = $Matches[1].Trim(); Setting = $Matches[2].Trim() }
        }
    }
}

# ================================================= 8. administration hygiene
Invoke-FieldkitSection -Name 'Local Administrators group' -OutputFolder $out -Notes $notes -Body {
    # By SID. "Administrators" is localized and asking for the English name
    # returns "group was not found", which reads exactly like an empty group.
    $sid = 'S-1-5-32-544'
    $name = $sid
    try { $name = ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value } catch { }

    $members = @(Get-LocalGroupMember -SID $sid -ErrorAction Stop)
    Add-Control -Area 'Administration' -Control 'Local Administrators membership is small' `
        -State $(if ($members.Count -le 3) { 'OK' } else { 'WEAK' }) `
        -Detail "$($members.Count) member(s) of $name" `
        -Why 'Every local administrator on a jumpbox can read every credential that passes through it.'

    $members | Select-Object @{n='Group';e={$name}}, @{n='Member';e={$_.Name}}, ObjectClass, PrincipalSource
}

Invoke-FieldkitSection -Name 'LAPS configuration' -OutputFolder $out -Notes $notes -Body {
    <#
        Configuration only. No password is read, by either the Windows LAPS or
        the legacy path, and none is written to the output.
    #>
    $rows = [System.Collections.Generic.List[object]]::new()
    $winLaps = 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS'
    $winLapsState = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\State'
    $legacy = 'HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd'

    foreach ($v in @('BackupDirectory','PasswordAgeDays','PasswordLength','PasswordComplexity',
                     'AdministratorAccountName','PostAuthenticationActions')) {
        $rows.Add([pscustomobject]@{ Source = 'Windows LAPS'; Setting = $v; Value = (Get-Reg $winLaps $v) })
    }
    $rows.Add([pscustomobject]@{ Source = 'Windows LAPS'; Setting = 'LastPasswordUpdate (state)'; Value = (Get-Reg $winLapsState 'LastPasswordUpdateTime') })
    foreach ($v in @('AdmPwdEnabled','PasswordAgeDays','PasswordLength','AdminAccountName')) {
        $rows.Add([pscustomobject]@{ Source = 'Legacy LAPS (AdmPwd)'; Setting = $v; Value = (Get-Reg $legacy $v) })
    }

    $bd = Get-Reg $winLaps 'BackupDirectory'
    $legacyOn = (Get-Reg $legacy 'AdmPwdEnabled')
    $state = if ($bd -in 1,2) { 'OK' } elseif ($legacyOn -eq 1) { 'INFO' } else { 'WEAK' }
    Add-Control -Area 'Administration' -Control 'Local administrator password managed (LAPS)' -State $state `
        -Detail "Windows LAPS BackupDirectory=$(if ($null -ne $bd) { $bd } else { 'not set' }), legacy AdmPwdEnabled=$(if ($null -ne $legacyOn) { $legacyOn } else { 'not set' })" `
        -Why 'BackupDirectory 1 = Entra ID, 2 = Active Directory. Legacy AdmPwd still works but is superseded. Without either, the local administrator password is shared and static.'

    $rows
}

Invoke-FieldkitSection -Name 'Administrative tooling installed' -OutputFolder $out -Notes $notes -Body {
    # What this jumpbox can actually do, and what it would need installing.
    $mods = @('ActiveDirectory','GroupPolicy','DnsServer','DhcpServer','ADCSAdministration',
              'ServerManager','Defender','BitLocker','LAPS','ExchangeOnlineManagement',
              'Microsoft.Graph','Az','MSOnline','AzureAD','PSWindowsUpdate','ConfigurationManager')
    foreach ($m in $mods) {
        $found = @(Get-Module -ListAvailable -Name $m -ErrorAction SilentlyContinue)
        [pscustomobject]@{
            Module    = $m
            Installed = ($found.Count -gt 0)
            Versions  = (($found | Select-Object -ExpandProperty Version -Unique) -join ', ')
        }
    }
}

Invoke-FieldkitSection -Name 'Software that widens the attack surface' -OutputFolder $out -Notes $notes -Body {
    <#
        A privileged access workstation should not browse the web or read
        email. This looks for the software that would let it.

        Reported as INFO rather than as a fault, because a consultant's own
        machine is rarely a true PAW and pretending otherwise is not useful.
        What matters is knowing, and deciding.
    #>
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $interesting = 'chrome|firefox|edge|brave|opera|outlook|thunderbird|office|teams|zoom|slack|acrobat|java|python|node'
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $keys) {
        Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.DisplayName -match $interesting } |
            ForEach-Object {
                $found.Add([pscustomobject]@{
                    Name = $_.DisplayName; Version = $_.DisplayVersion
                    Publisher = $_.Publisher; InstallDate = $_.InstallDate
                })
            }
    }
    $unique = @($found | Sort-Object Name, Version -Unique)
    Add-Control -Area 'Exposure' -Control 'Browsing and mail software present' -State 'INFO' `
        -Detail "$($unique.Count) item(s) matched" `
        -Why 'A true privileged access workstation has no browser and no mail client. Most consultant machines do. The point is to know, and to decide, rather than to assume.'
    $unique
}

# ================================================= the verdict
Invoke-FieldkitSection -Name 'VERDICT: control summary' -OutputFolder $out -Notes $notes -Body {
    $controls | Sort-Object @{e={ switch ($_.State) { 'WEAK' {0} 'UNKNOWN' {1} 'INFO' {2} 'OK' {3} } }}, Area, Control
}

$weak    = @($controls | Where-Object { $_.State -eq 'WEAK' })
$unknown = @($controls | Where-Object { $_.State -eq 'UNKNOWN' })

Write-Host ''
Write-Host ('  ' + ('-' * 70)) -ForegroundColor Cyan
Write-Host '   VERDICT' -ForegroundColor Cyan
Write-Host ('  ' + ('-' * 70)) -ForegroundColor Cyan
Write-Host ("   {0} control(s) in place, {1} weak, {2} could not be determined" -f
            @($controls | Where-Object { $_.State -eq 'OK' }).Count, $weak.Count, $unknown.Count)
Write-Host ''

foreach ($c in ($weak | Sort-Object Area, Control)) {
    Write-Host ("   WEAK     {0}" -f $c.Control) -ForegroundColor Yellow
    Write-Host ("            {0}" -f $c.Detail) -ForegroundColor DarkGray
}
foreach ($c in ($unknown | Sort-Object Area, Control)) {
    Write-Host ("   UNKNOWN  {0}" -f $c.Control) -ForegroundColor DarkYellow
    Write-Host ("            {0}" -f $c.Detail) -ForegroundColor DarkGray
}

$notes.Add("Controls: $(@($controls | Where-Object { $_.State -eq 'OK' }).Count) OK, $($weak.Count) WEAK, $($unknown.Count) UNKNOWN, $(@($controls | Where-Object { $_.State -eq 'INFO' }).Count) INFO. Full list in VERDICT-control-summary.csv.")
$notes.Add('UNKNOWN is not a pass. A control whose state could not be established is not a control that is present.')
$notes.Add('Two things were deliberately NOT read: the Winlogon autologon password value, and any LAPS-managed password. Presence and configuration are reported; secrets are not collected.')
if ($weak.Count) {
    $notes.Add("Weakest areas first: $((($weak | Group-Object Area | Sort-Object Count -Descending | Select-Object -First 3).Name) -join ', ').")
}

Write-FieldkitSummary -Title 'Jumpbox Posture' -OutputFolder $out -Notes $notes
