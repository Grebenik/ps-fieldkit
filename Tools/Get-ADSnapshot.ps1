<#FIELDKIT
Name      : Active Directory Snapshot
Category  : Active Directory
Summary   : Functional levels, FSMO roles, DCs, trusts, password policy, privileged groups, stale and risky accounts.
Requires  : RSAT-AD
Elevation : Recommended
Scope     : Domain
Output    : ADSnapshot
ReadOnly  : Yes
FIELDKIT#>

<#
    Get-ADSnapshot.ps1

    The state of the directory, in one pass. This is the opening move of an AD
    review and it answers most of the questions a first meeting will raise.

    READ-ONLY. Every directory command here is a Get-. Nothing is created,
    modified or deleted, and that claim is part of what makes the run
    authorizable in the first place.

    ---------------------------------------------------------------------------
    ONE THING THAT BITES

    Get-ADGroupMember raises a TERMINATING error when the group does not exist
    in the target domain, and -ErrorAction SilentlyContinue does not suppress
    it. Enterprise Admins and Schema Admins exist only in the forest root, so
    querying a child domain kills the whole loop at the first group.

    Every group is therefore wrapped individually, and a group that is not
    present is recorded as not present rather than as empty. Those two are very
    different answers and only one of them is reassuring.
#>

[CmdletBinding()]
param(
    # Read from a specific domain controller. Useful when you want the answer
    # from one server rather than whichever one the locator picks.
    [string] $Server,

    # A different domain in the forest.
    [string] $DomainName,

    # An account is "stale" after this many days without a logon.
    [int] $StaleDays = 90
)

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Lib\Fieldkit.Common.ps1')

Import-Module ActiveDirectory -ErrorAction Stop

$out   = New-FieldkitOutputFolder -ToolOutputName 'ADSnapshot'
$notes = [System.Collections.Generic.List[string]]::new()

Write-FieldkitHeader -Title 'Active Directory Snapshot' -OutputFolder $out

# Build the common parameter splat once.
$adArgs = @{}
if ($Server)     { $adArgs['Server'] = $Server }
if ($DomainName) { $adArgs['Identity'] = $DomainName }

try {
    $domain = if ($DomainName) { Get-ADDomain -Identity $DomainName -ErrorAction Stop }
              elseif ($Server) { Get-ADDomain -Server $Server -ErrorAction Stop }
              else             { Get-ADDomain -ErrorAction Stop }
}
catch {
    Write-Host ''
    Write-Host '  STOP: could not read the domain.' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    Write-Host '  This machine may not be domain-joined, or this account may have no' -ForegroundColor Yellow
    Write-Host '  rights in the directory. Nothing was collected.'                     -ForegroundColor Yellow
    $notes.Add("NOT READ  Get-ADDomain - $($_.Exception.Message)")
    Write-FieldkitSummary -Title 'Active Directory Snapshot' -OutputFolder $out -Notes $notes
    return
}

$readFrom = if ($Server) { $Server } else { $domain.PDCEmulator }
$dn       = $domain.DistinguishedName
$q        = @{ Server = $readFrom }

Write-Host ("  Domain    : {0}" -f $domain.DNSRoot)
Write-Host ("  Read from : {0}" -f $readFrom)
Write-Host ''
$notes.Add("Domain $($domain.DNSRoot), read from $readFrom.")

# ------------------------------------------------------------ forest and domain
Invoke-FieldkitSection -Name 'Forest and domain functional level' -OutputFolder $out -Notes $notes -Body {
    $forest = Get-ADForest @q -ErrorAction Stop
    [pscustomobject]@{
        Forest                 = $forest.Name
        ForestFunctionalLevel  = $forest.ForestMode
        ForestRootDomain       = $forest.RootDomain
        DomainsInForest        = ($forest.Domains -join ', ')
        SchemaMaster           = $forest.SchemaMaster
        DomainNamingMaster     = $forest.DomainNamingMaster
        Domain                 = $domain.DNSRoot
        DomainFunctionalLevel  = $domain.DomainMode
        NetBIOSName            = $domain.NetBIOSName
        DistinguishedName      = $dn
        PDCEmulator            = $domain.PDCEmulator
        RIDMaster              = $domain.RIDMaster
        InfrastructureMaster   = $domain.InfrastructureMaster
        DomainSID              = $domain.DomainSID
    }
}

Invoke-FieldkitSection -Name 'Domain controllers' -OutputFolder $out -Notes $notes -Body {
    Get-ADDomainController -Filter * @q -ErrorAction Stop |
        Select-Object Name, HostName, IPv4Address, Site, OperatingSystem, OperatingSystemVersion,
                      IsGlobalCatalog, IsReadOnly, Enabled,
                      @{n='FSMORoles';e={ ($_.OperationMasterRoles) -join ', ' }} |
        Sort-Object Name
}

Invoke-FieldkitSection -Name 'Trusts' -OutputFolder $out -Notes $notes -Body {
    Get-ADTrust -Filter * @q -ErrorAction Stop |
        Select-Object Name, Direction, TrustType, ForestTransitive, IntraForest,
                      SelectiveAuthentication, SIDFilteringQuarantined,
                      SIDFilteringForestAware, Source, Target
}

Invoke-FieldkitSection -Name 'Default domain password policy' -OutputFolder $out -Notes $notes -Body {
    Get-ADDefaultDomainPasswordPolicy @q -ErrorAction Stop |
        Select-Object ComplexityEnabled, MinPasswordLength, PasswordHistoryCount,
                      MinPasswordAge, MaxPasswordAge, LockoutThreshold,
                      LockoutDuration, LockoutObservationWindow,
                      ReversibleEncryptionEnabled
}

Invoke-FieldkitSection -Name 'Fine-grained password policies' -OutputFolder $out -Notes $notes -Body {
    Get-ADFineGrainedPasswordPolicy -Filter * @q -ErrorAction Stop |
        Select-Object Name, Precedence, MinPasswordLength, ComplexityEnabled,
                      LockoutThreshold, MaxPasswordAge,
                      @{n='AppliesTo';e={ ($_.AppliesTo) -join '; ' }}
}

# ------------------------------------------------------------ privilege
Invoke-FieldkitSection -Name 'Privileged group membership' -OutputFolder $out -Notes $notes -Body {
    <#
        Groups are resolved by SID wherever a well-known SID exists.

        Built-in group names are LOCALIZED. In a domain created from a Finnish
        or German installation, "Domain Admins" is not called Domain Admins,
        and asking for the English name returns "cannot find an object with
        identity" - which is indistinguishable from a group that is absent.
        An audit that reports "Domain Admins: not present" on a live domain is
        worse than one that fails loudly.

        The English label is kept for the report, because that is what the
        finding needs to say, but the lookup never depends on it.

        Domain-relative SIDs are built from the domain SID. Enterprise Admins
        and Schema Admins exist only in the FOREST ROOT, so they are built from
        the root domain's SID rather than this domain's.
    #>
    $domSid  = $domain.DomainSID.Value
    $rootSid = $null
    try {
        $forest  = Get-ADForest @q -ErrorAction Stop
        $rootSid = (Get-ADDomain -Identity $forest.RootDomain -ErrorAction Stop).DomainSID.Value
    }
    catch {
        $notes.Add("Forest root domain SID could not be read, so Enterprise Admins and Schema Admins were looked up by name instead: $($_.Exception.Message)")
    }

    # Label, and how to find it. Absolute SIDs are the BUILTIN ones, which are
    # identical in every domain on earth.
    $targets = @(
        @{ Label = 'Domain Admins';               Sid = "$domSid-512" }
        @{ Label = 'Enterprise Admins';           Sid = $(if ($rootSid) { "$rootSid-519" } else { $null }); Name = 'Enterprise Admins'; RootOnly = $true }
        @{ Label = 'Schema Admins';               Sid = $(if ($rootSid) { "$rootSid-518" } else { $null }); Name = 'Schema Admins';     RootOnly = $true }
        @{ Label = 'Administrators (builtin)';    Sid = 'S-1-5-32-544' }
        @{ Label = 'Account Operators';           Sid = 'S-1-5-32-548' }
        @{ Label = 'Server Operators';            Sid = 'S-1-5-32-549' }
        @{ Label = 'Print Operators';             Sid = 'S-1-5-32-550' }
        @{ Label = 'Backup Operators';            Sid = 'S-1-5-32-551' }
        @{ Label = 'Group Policy Creator Owners'; Sid = "$domSid-520" }
        @{ Label = 'Cert Publishers';             Sid = "$domSid-517" }
        @{ Label = 'Protected Users';             Sid = "$domSid-525" }
        @{ Label = 'Key Admins';                  Sid = "$domSid-526" }
        # DnsAdmins is created by the DNS server role and has no well-known
        # SID, so this one genuinely has to go by name.
        @{ Label = 'DnsAdmins';                   Sid = $null; Name = 'DnsAdmins' }
    )

    foreach ($t in $targets) {
        $label = $t.Label

        # Resolve the group object first, so "cannot find the group" and
        # "the group is empty" stay separate answers.
        $grp = $null
        $how = ''
        try {
            if ($t.Sid) {
                $grp = Get-ADGroup -Identity $t.Sid @q -ErrorAction Stop
                $how = 'by SID'
            }
            elseif ($t.Name) {
                $grp = Get-ADGroup -Identity $t.Name @q -ErrorAction Stop
                $how = 'by name'
            }
        }
        catch {
            $why = if ($t.RootOnly) {
                       'GROUP NOT PRESENT IN THIS DOMAIN. This group exists only in the forest root, so its absence here is expected and is NOT the same as it being empty.'
                   } else {
                       "GROUP NOT FOUND - not the same as empty ($($_.Exception.Message))"
                   }
            [pscustomobject]@{
                Group = $label; ActualName = ''; Member = ''; ObjectClass = ''
                Enabled = ''; LastLogonDate = ''; PasswordLastSet = ''; Note = $why
            }
            continue
        }

        # Members, per group, because one failure must not end the loop.
        try {
            $members = @(Get-ADGroupMember -Identity $grp -Recursive @q -ErrorAction Stop)
        }
        catch {
            [pscustomobject]@{
                Group = $label; ActualName = $grp.Name; Member = ''; ObjectClass = ''
                Enabled = ''; LastLogonDate = ''; PasswordLastSet = ''
                Note = "MEMBERS NOT READ ($how) - $($_.Exception.Message)"
            }
            continue
        }

        if ($members.Count -eq 0) {
            [pscustomobject]@{
                Group = $label; ActualName = $grp.Name; Member = ''; ObjectClass = ''
                Enabled = ''; LastLogonDate = ''; PasswordLastSet = ''
                Note = "group exists ($how) and is EMPTY"
            }
            continue
        }

        foreach ($m in $members) {
            $detail = $null
            try {
                if ($m.objectClass -eq 'user') {
                    $detail = Get-ADUser -Identity $m.distinguishedName @q -ErrorAction Stop `
                              -Properties Enabled, LastLogonDate, PasswordLastSet, Description
                }
            }
            catch { }
            [pscustomobject]@{
                Group           = $label
                ActualName      = $grp.Name
                Member          = $m.SamAccountName
                ObjectClass     = $m.objectClass
                Enabled         = if ($detail) { $detail.Enabled } else { '' }
                LastLogonDate   = if ($detail) { $detail.LastLogonDate } else { '' }
                PasswordLastSet = if ($detail) { $detail.PasswordLastSet } else { '' }
                Note            = if ($detail) { $detail.Description } else { '' }
            }
        }
    }
}

Invoke-FieldkitSection -Name 'krbtgt password age' -OutputFolder $out -Notes $notes -Body {
    # The krbtgt password is what every Kerberos ticket in the domain is
    # signed with. Its age is the age of the oldest forgeable golden ticket.
    # RID 502, rather than the name, for the same reason the groups above use
    # SIDs.
    Get-ADUser -Identity ("{0}-502" -f $domain.DomainSID.Value) @q `
               -Properties PasswordLastSet, whenCreated -ErrorAction Stop |
        Select-Object SamAccountName, PasswordLastSet, whenCreated,
                      @{n='PasswordAgeDays';e={
                          if ($_.PasswordLastSet) { [math]::Round(((Get-Date) - $_.PasswordLastSet).TotalDays) }
                      }}
}

Invoke-FieldkitSection -Name 'AdminSDHolder residue (adminCount=1)' -OutputFolder $out -Notes $notes -Body {
    # adminCount stays at 1 after an account leaves a privileged group, and
    # the account keeps its broken inheritance. It is a record of who WAS
    # privileged, which is often more interesting than who is.
    Get-ADObject -LDAPFilter '(&(objectCategory=person)(objectClass=user)(adminCount=1))' `
                 -SearchBase $dn @q -Properties SamAccountName, adminCount, whenChanged,
                                                 lastLogonTimestamp, userAccountControl -ErrorAction Stop |
        Select-Object SamAccountName, DistinguishedName, adminCount, whenChanged,
                      @{n='LastLogon';e={ if ($_.lastLogonTimestamp) { [datetime]::FromFileTime($_.lastLogonTimestamp) } }}
}

Invoke-FieldkitSection -Name 'Machine account quota' -OutputFolder $out -Notes $notes -Body {
    # The default of 10 lets any authenticated user create computer accounts,
    # which is the precondition for a resource-based constrained delegation
    # attack. It is a one-value change and it is almost always still 10.
    Get-ADObject -Identity $dn @q -Properties 'ms-DS-MachineAccountQuota' -ErrorAction Stop |
        Select-Object @{n='Domain';e={$dn}},
                      @{n='ms-DS-MachineAccountQuota';e={ $_.'ms-DS-MachineAccountQuota' }}
}

# ------------------------------------------------------------ risky configuration
Invoke-FieldkitSection -Name 'Accounts with a service principal name' -OutputFolder $out -Notes $notes -Body {
    # User accounts with an SPN are Kerberoastable. The ones that matter are
    # enabled, privileged, or have a very old password.
    Get-ADUser -LDAPFilter '(&(servicePrincipalName=*)(!(objectClass=computer)))' @q `
               -Properties servicePrincipalName, PasswordLastSet, LastLogonDate, Enabled,
                           adminCount, 'msDS-SupportedEncryptionTypes' -ErrorAction Stop |
        Select-Object SamAccountName, Enabled, adminCount, PasswordLastSet, LastLogonDate,
                      @{n='PasswordAgeDays';e={ if ($_.PasswordLastSet) { [math]::Round(((Get-Date) - $_.PasswordLastSet).TotalDays) } }},
                      @{n='SPNs';e={ ($_.servicePrincipalName) -join '; ' }},
                      @{n='SupportedEncryptionTypes';e={ $_.'msDS-SupportedEncryptionTypes' }}
}

Invoke-FieldkitSection -Name 'Kerberos encryption and delegation flags' -OutputFolder $out -Notes $notes -Body {
    <#
        Three separate problems, reported together because they come from the
        same attribute pair.

          useDESKeyOnly (UAC 0x200000)  DES only. Breaks on any modern DC.
          TrustedForDelegation           unconstrained delegation.
          msDS-SupportedEncryptionTypes  0 or unset means the default set,
                                         which on an older domain can mean RC4.
    #>
    $filter = '(|(userAccountControl:1.2.840.113556.1.4.803:=2097152)' +
              '(userAccountControl:1.2.840.113556.1.4.803:=524288)' +
              '(msDS-SupportedEncryptionTypes=1)(msDS-SupportedEncryptionTypes=2)(msDS-SupportedEncryptionTypes=3)(msDS-SupportedEncryptionTypes=4))'
    Get-ADObject -LDAPFilter $filter -SearchBase $dn @q `
                 -Properties SamAccountName, userAccountControl, 'msDS-SupportedEncryptionTypes',
                             objectClass, whenChanged -ErrorAction Stop |
        ForEach-Object {
            $uac = [int]$_.userAccountControl
            [pscustomobject]@{
                SamAccountName          = $_.SamAccountName
                ObjectClass             = $_.objectClass
                DistinguishedName       = $_.DistinguishedName
                DESKeyOnly              = [bool]($uac -band 0x200000)
                TrustedForDelegation    = [bool]($uac -band 0x80000)
                SupportedEncryptionTypes = $_.'msDS-SupportedEncryptionTypes'
                WhenChanged             = $_.whenChanged
            }
        }
}

Invoke-FieldkitSection -Name 'Passwords that never expire (enabled accounts)' -OutputFolder $out -Notes $notes -Body {
    Get-ADUser -LDAPFilter '(&(userAccountControl:1.2.840.113556.1.4.803:=65536)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))' @q `
               -Properties PasswordLastSet, LastLogonDate, Description, adminCount -ErrorAction Stop |
        Select-Object SamAccountName, adminCount, PasswordLastSet, LastLogonDate, Description,
                      @{n='PasswordAgeDays';e={ if ($_.PasswordLastSet) { [math]::Round(((Get-Date) - $_.PasswordLastSet).TotalDays) } }} |
        Sort-Object PasswordAgeDays -Descending
}

Invoke-FieldkitSection -Name 'Kerberos pre-authentication not required' -OutputFolder $out -Notes $notes -Body {
    # AS-REP roastable. Usually a handful of accounts set up years ago for a
    # device that could not do pre-auth, and never reverted.
    Get-ADUser -LDAPFilter '(userAccountControl:1.2.840.113556.1.4.803:=4194304)' @q `
               -Properties PasswordLastSet, LastLogonDate, Enabled, Description -ErrorAction Stop |
        Select-Object SamAccountName, Enabled, PasswordLastSet, LastLogonDate, Description
}

Invoke-FieldkitSection -Name "Stale enabled users ($StaleDays days)" -OutputFolder $out -Notes $notes -Body {
    $cut = (Get-Date).AddDays(-$StaleDays)
    Get-ADUser -Filter { Enabled -eq $true } @q `
               -Properties LastLogonDate, PasswordLastSet, whenCreated, Description, adminCount -ErrorAction Stop |
        Where-Object { $_.LastLogonDate -and $_.LastLogonDate -lt $cut } |
        Select-Object SamAccountName, adminCount, LastLogonDate, PasswordLastSet, whenCreated, Description,
                      @{n='DaysSinceLogon';e={ [math]::Round(((Get-Date) - $_.LastLogonDate).TotalDays) }} |
        Sort-Object DaysSinceLogon -Descending
}

Invoke-FieldkitSection -Name "Stale enabled computers ($StaleDays days)" -OutputFolder $out -Notes $notes -Body {
    $cut = (Get-Date).AddDays(-$StaleDays)
    Get-ADComputer -Filter { Enabled -eq $true } @q `
                   -Properties LastLogonDate, OperatingSystem, OperatingSystemVersion, whenCreated -ErrorAction Stop |
        Where-Object { $_.LastLogonDate -and $_.LastLogonDate -lt $cut } |
        Select-Object Name, OperatingSystem, OperatingSystemVersion, LastLogonDate, whenCreated,
                      @{n='DaysSinceLogon';e={ [math]::Round(((Get-Date) - $_.LastLogonDate).TotalDays) }} |
        Sort-Object DaysSinceLogon -Descending
}

Invoke-FieldkitSection -Name 'Operating system census (enabled computers)' -OutputFolder $out -Notes $notes -Body {
    Get-ADComputer -Filter { Enabled -eq $true } @q -Properties OperatingSystem, OperatingSystemVersion -ErrorAction Stop |
        Group-Object OperatingSystem |
        Select-Object @{n='OperatingSystem';e={ if ($_.Name) { $_.Name } else { '(not reported)' } }},
                      @{n='Count';e={ $_.Count }} |
        Sort-Object Count -Descending
}

Invoke-FieldkitSection -Name 'Organizational units' -OutputFolder $out -Notes $notes -Body {
    Get-ADOrganizationalUnit -Filter * @q -Properties whenCreated, ProtectedFromAccidentalDeletion -ErrorAction Stop |
        Select-Object Name, DistinguishedName, whenCreated, ProtectedFromAccidentalDeletion |
        Sort-Object DistinguishedName
}

# ------------------------------------------------------------ summary
$notes.Add("Stale threshold used: $StaleDays days.")
$notes.Add('Privileged groups were resolved by well-known SID, not by name, because built-in group names are localized. The ActualName column shows what each group is really called in this domain.')
$notes.Add('A group row reading GROUP NOT PRESENT IN THIS DOMAIN is not an empty group. Enterprise Admins and Schema Admins exist only in the forest root.')

Write-FieldkitSummary -Title 'Active Directory Snapshot' -OutputFolder $out -Notes $notes
