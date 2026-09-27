<#FIELDKIT
Name      : Group Policy Inventory
Category  : Group Policy
Summary   : Every GPO, where it is linked, what is unlinked or empty, and optional full HTML reports.
Requires  : RSAT-GP, RSAT-AD
Elevation : Recommended
Scope     : Domain
Output    : GPOInventory
ReadOnly  : Yes
Remote    : Native
FIELDKIT#>

<#
    Get-GPOInventory.ps1

    What Group Policy objects exist, where they apply, and which of them do
    nothing. The inventory is quick; the per-GPO HTML reports are the evidence
    and take longer, so they are optional.

    READ-ONLY. Get-GPO and Get-GPOReport only.

    ---------------------------------------------------------------------------
    WHY LINKS ARE COLLECTED SEPARATELY

    A GPO's own object does not know where it is linked. The links live on the
    OUs, the domain and the sites. Reporting the GPO list alone tells you what
    exists, not what applies, and those differ in every environment that has
    been running for more than a few years.
#>

[CmdletBinding()]
param(
    [string] $DomainName,

    # Export a full settings report per GPO. This is the useful evidence and
    # it is slow: roughly a second per GPO, sometimes more.
    [switch] $WithReports,

    # XML instead of HTML, when the reports are going to be parsed rather
    # than read.
    [ValidateSet('Html','Xml')]
    [string] $ReportFormat = 'Html'
)

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Lib\Fieldkit.Common.ps1')

Import-Module GroupPolicy -ErrorAction Stop
# The link half of this tool reads OUs and sites from the directory, so the AD
# module is needed as well as the Group Policy one.
Import-Module ActiveDirectory -ErrorAction Stop

$out   = New-FieldkitOutputFolder -ToolOutputName 'GPOInventory'
$notes = [System.Collections.Generic.List[string]]::new()

Write-FieldkitHeader -Title 'Group Policy Inventory' -OutputFolder $out

$gpArgs = @{}
if ($DomainName) { $gpArgs['Domain'] = $DomainName }

# Read once, use in several sections, so a large domain is not enumerated
# repeatedly.
$allGpos = $null
try {
    $allGpos = @(Get-GPO -All @gpArgs -ErrorAction Stop)
    Write-Host ("  {0} GPOs in the domain" -f $allGpos.Count)
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Host "  STOP: could not enumerate GPOs. $($_.Exception.Message)" -ForegroundColor Red
    $notes.Add("NOT READ  Get-GPO -All - $($_.Exception.Message)")
    Write-FieldkitSummary -Title 'Group Policy Inventory' -OutputFolder $out -Notes $notes
    return
}

Invoke-FieldkitSection -Name 'All GPOs' -OutputFolder $out -Notes $notes -Body {
    $allGpos | Select-Object DisplayName, Id, GpoStatus, CreationTime, ModificationTime,
                             @{n='UserVersionDS';e={ $_.User.DSVersion }},
                             @{n='UserVersionSysvol';e={ $_.User.SysvolVersion }},
                             @{n='ComputerVersionDS';e={ $_.Computer.DSVersion }},
                             @{n='ComputerVersionSysvol';e={ $_.Computer.SysvolVersion }},
                             Description |
        Sort-Object DisplayName
}

Invoke-FieldkitSection -Name 'GPOs with no settings at all' -OutputFolder $out -Notes $notes -Body {
    # Version 0 on both sides means nothing has ever been configured in it.
    # An empty GPO that is linked looks like a control and is not one.
    $allGpos |
        Where-Object { $_.User.DSVersion -eq 0 -and $_.Computer.DSVersion -eq 0 } |
        Select-Object DisplayName, Id, GpoStatus, CreationTime, ModificationTime |
        Sort-Object DisplayName
}

Invoke-FieldkitSection -Name 'GPOs disabled in whole or in part' -OutputFolder $out -Notes $notes -Body {
    $allGpos |
        Where-Object { $_.GpoStatus -ne 'AllSettingsEnabled' } |
        Select-Object DisplayName, Id, GpoStatus, ModificationTime |
        Sort-Object DisplayName
}

# ------------------------------------------------------------ where they apply
$linkRows = [System.Collections.Generic.List[object]]::new()

Invoke-FieldkitSection -Name 'GPO links by container' -OutputFolder $out -Notes $notes -Body {
    <#
        Links are read from the containers, not from the GPOs. gPLink on the
        domain head, on every OU and on every site.
    #>
    $domain = Get-ADDomain -ErrorAction Stop
    $containers = [System.Collections.Generic.List[object]]::new()
    $containers.Add([pscustomobject]@{ Type = 'Domain'; DN = $domain.DistinguishedName; Name = $domain.DNSRoot })

    foreach ($ou in (Get-ADOrganizationalUnit -Filter * -ErrorAction Stop)) {
        $containers.Add([pscustomobject]@{ Type = 'OU'; DN = $ou.DistinguishedName; Name = $ou.Name })
    }

    try {
        $cfgNC = (Get-ADRootDSE -ErrorAction Stop).configurationNamingContext
        foreach ($site in (Get-ADObject -SearchBase "CN=Sites,$cfgNC" -LDAPFilter '(objectClass=site)' -ErrorAction Stop)) {
            $containers.Add([pscustomobject]@{ Type = 'Site'; DN = $site.DistinguishedName; Name = $site.Name })
        }
    }
    catch {
        $notes.Add("Sites were not enumerated: $($_.Exception.Message)")
    }

    foreach ($c in $containers) {
        try {
            $inh = Get-GPInheritance -Target $c.DN @gpArgs -ErrorAction Stop
            if ($inh.GpoLinks.Count -eq 0) {
                $row = [pscustomobject]@{
                    ContainerType = $c.Type; Container = $c.Name; ContainerDN = $c.DN
                    GPO = ''; Enabled = ''; Enforced = ''; Order = ''
                    InheritanceBlocked = $inh.GpoInheritanceBlocked
                    Note = 'no GPOs linked here'
                }
                $linkRows.Add($row); $row
                continue
            }
            foreach ($l in $inh.GpoLinks) {
                $row = [pscustomobject]@{
                    ContainerType = $c.Type; Container = $c.Name; ContainerDN = $c.DN
                    GPO = $l.DisplayName; Enabled = $l.Enabled; Enforced = $l.Enforced
                    Order = $l.Order
                    InheritanceBlocked = $inh.GpoInheritanceBlocked
                    Note = ''
                }
                $linkRows.Add($row); $row
            }
        }
        catch {
            $row = [pscustomobject]@{
                ContainerType = $c.Type; Container = $c.Name; ContainerDN = $c.DN
                GPO = ''; Enabled = ''; Enforced = ''; Order = ''; InheritanceBlocked = ''
                Note = "NOT READ: $($_.Exception.Message)"
            }
            $linkRows.Add($row); $row
        }
    }
}

Invoke-FieldkitSection -Name 'GPOs that are linked nowhere' -OutputFolder $out -Notes $notes -Body {
    # An unlinked GPO does nothing. It is usually either abandoned work or a
    # control someone believes is in force. Both are worth saying out loud.
    $linked = @($linkRows | Where-Object { $_.GPO } | Select-Object -ExpandProperty GPO -Unique)
    $allGpos |
        Where-Object { $_.DisplayName -notin $linked } |
        Select-Object DisplayName, Id, GpoStatus, CreationTime, ModificationTime |
        Sort-Object DisplayName
}

Invoke-FieldkitSection -Name 'Enforced links and blocked inheritance' -OutputFolder $out -Notes $notes -Body {
    # The two things that make resultant policy hard to predict.
    $linkRows | Where-Object { $_.Enforced -eq $true -or $_.InheritanceBlocked -eq $true } |
        Select-Object ContainerType, Container, GPO, Enforced, InheritanceBlocked, Order
}

Invoke-FieldkitSection -Name 'Links that exist but are disabled' -OutputFolder $out -Notes $notes -Body {
    $linkRows | Where-Object { $_.GPO -and $_.Enabled -eq $false } |
        Select-Object ContainerType, Container, GPO, Order
}

# ------------------------------------------------------------ the evidence
if ($WithReports) {
    $reportDir = Join-Path $out ('Reports-' + $ReportFormat)
    $null = New-Item -ItemType Directory -Path $reportDir -Force
    Write-Host ''
    Write-Host ("  Exporting {0} settings reports to {1}" -f $allGpos.Count, $reportDir) -ForegroundColor Cyan
    Write-Host '  This is the slow part. Roughly a second per GPO.' -ForegroundColor DarkGray

    $failed = 0
    $i = 0
    foreach ($g in ($allGpos | Sort-Object DisplayName)) {
        $i++
        Write-Progress -Activity 'Exporting GPO reports' -Status $g.DisplayName `
                       -PercentComplete (($i / $allGpos.Count) * 100)
        $safe = ($g.DisplayName -replace '[\\/:*?"<>|]', '_').Trim()
        $ext  = if ($ReportFormat -eq 'Xml') { 'xml' } else { 'html' }
        try {
            Get-GPOReport -Guid $g.Id -ReportType $ReportFormat @gpArgs `
                          -Path (Join-Path $reportDir "$safe.$ext") -ErrorAction Stop
        }
        catch {
            $failed++
            $notes.Add("NOT READ  GPO report for '$($g.DisplayName)' - $($_.Exception.Message)")
        }
    }
    Write-Progress -Activity 'Exporting GPO reports' -Completed
    Write-Host ("  {0} exported, {1} failed" -f ($allGpos.Count - $failed), $failed) `
               -ForegroundColor $(if ($failed) { 'Yellow' } else { 'Green' })
}
else {
    $notes.Add('Per-GPO settings reports were NOT exported. Re-run with -WithReports for the full evidence.')
    Write-Host ''
    Write-Host '  Settings reports were not exported. Add -WithReports for those.' -ForegroundColor DarkYellow
}

Write-FieldkitSummary -Title 'Group Policy Inventory' -OutputFolder $out -Notes $notes
