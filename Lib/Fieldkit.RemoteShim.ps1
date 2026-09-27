<#
    Fieldkit.RemoteShim.ps1

    The remote half. This file is never dot-sourced locally: its TEXT is read
    and shipped to a target as part of a payload.

    ---------------------------------------------------------------------------
    WHY A SHIM AND NOT THE REAL LIBRARY

    The real library writes CSV files. On a remote target that would mean
    creating folders on a client's server, which then have to be copied back
    and deleted, and which leave a footprint on a machine that is not ours.

    This defines the same function NAMES with object-returning behavior, so an
    existing tool runs unmodified and writes NOTHING to the target. Results
    come back as objects and the console writes the files.

    "We connected, we read, and we wrote nothing to your server" is a much
    better sentence than "we left a folder on each of your domain controllers",
    and it is the one worth being able to say.

    ---------------------------------------------------------------------------
    THE CONTRACT

    A tool calls, in order:

        New-FieldkitOutputFolder   -> returns a path string, creates nothing
        Write-FieldkitHeader       -> discarded
        Invoke-FieldkitSection * N -> collected into $FieldkitSections
        Write-FieldkitSummary      -> EMITS the single result object

    Everything a tool does between those calls is its own business and runs
    unchanged.
#>

$script:FieldkitSections = [System.Collections.Generic.List[object]]::new()
if (-not (Get-Variable -Name FieldkitMaxRows -Scope Script -ErrorAction SilentlyContinue)) {
    $script:FieldkitMaxRows = 5000
}

function Get-FieldkitConfig {
    [pscustomobject]@{
        WorkRoot   = 'C:\work'
        KitRoot    = 'C:\work\Fieldkit'
        OutputRoot = 'C:\work\Output'
        LogRoot    = 'C:\work\Logs'
        Version    = 'remote-shim'
    }
}

function Test-FieldkitElevation {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal] $id).IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-FieldkitOSRole {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        switch ($os.ProductType) {
            1 { return 'Workstation' } 2 { return 'DomainController' } 3 { return 'Server' }
            default { return 'Unknown' }
        }
    }
    catch { return 'Unknown' }
}

function Write-FieldkitLog {
    # No logging on a target. Nothing is written to a machine that is not ours.
    param([string] $Message, [string] $Level = 'INFO')
}

function New-FieldkitOutputFolder {
    # Returns a plausible path and CREATES NOTHING. Tools pass it around; the
    # shim ignores it.
    param([Parameter(Mandatory)] [string] $ToolOutputName)
    return ('C:\work\Output\{0}-{1}-remote' -f $ToolOutputName, $env:COMPUTERNAME)
}

function Write-FieldkitHeader {
    param([string] $Title, [string] $OutputFolder)
    # Discarded. The console prints its own progress.
}

function Invoke-FieldkitSection {
    <#
        Same three outcomes as the local version, carried back as data rather
        than printed and written.

        rows / no rows / NOT READ survives the trip. That distinction is the
        entire point of the kit and it must not be the thing that gets lost in
        remoting.
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $OutputFolder,
        [Parameter(Mandatory)] [scriptblock] $Body,
        $Notes
    )

    $entry = [ordered]@{
        Name       = $Name
        Status     = 'notread'
        RowCount   = 0
        Rows       = @()
        Error      = ''
        Truncated  = $false
    }

    try {
        $rows = @(& $Body)
        if ($rows.Count -eq 0) {
            $entry.Status = 'empty'
            if ($null -ne $Notes) { $Notes.Add("EMPTY     $Name - the query ran and returned nothing.") }
        }
        else {
            $entry.Status   = 'rows'
            $entry.RowCount = $rows.Count
            if ($rows.Count -gt $script:FieldkitMaxRows) {
                # Truncation must be visible. A silently shortened result set is
                # a wrong answer that looks like a right one.
                $entry.Rows      = $rows[0..($script:FieldkitMaxRows - 1)]
                $entry.Truncated = $true
                if ($null -ne $Notes) { $Notes.Add("TRUNCATED $Name - $($rows.Count) rows found, first $($script:FieldkitMaxRows) returned.") }
            }
            else {
                $entry.Rows = $rows
            }
        }
    }
    catch {
        $entry.Status = 'notread'
        $entry.Error  = $_.Exception.Message
        if ($null -ne $Notes) { $Notes.Add("NOT READ  $Name - $($_.Exception.Message)") }
    }

    $script:FieldkitSections.Add([pscustomobject]$entry)
}

function Write-FieldkitSummary {
    <# Emits the one object the console collects. #>
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $OutputFolder,
        [Parameter(Mandatory)] $Notes
    )
    [pscustomobject]@{
        FieldkitResult = $true
        ComputerName   = $env:COMPUTERNAME
        Title          = $Title
        Collected      = (Get-Date)
        Elevated       = (Test-FieldkitElevation)
        OSRole         = (Get-FieldkitOSRole)
        PSVersion      = $PSVersionTable.PSVersion.ToString()
        Sections       = @($script:FieldkitSections)
        Notes          = @($Notes)
    }
}
