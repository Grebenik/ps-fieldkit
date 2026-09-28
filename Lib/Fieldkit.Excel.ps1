<#
    Fieldkit.Excel.ps1

    Turn an output folder into one formatted Excel workbook.

    ---------------------------------------------------------------------------
    IT POST-PROCESSES. IT DOES NOT REPLACE ANYTHING.

    This reads the CSVs a run has already written and assembles a workbook from
    them. No tool knows it exists and no tool had to change.

    That matters for three reasons:

      * The CSVs remain the source of truth. A workbook is a convenience for
        the person reading it, not the record.
      * It works identically for a local run and a remote sweep, because both
        produce a folder of CSVs.
      * If ImportExcel is missing - and the PowerShell Gallery is blocked on
        plenty of client networks - nothing is lost. The CSVs are already
        written and complete.

    ---------------------------------------------------------------------------
    THE GAPS TRAVEL WITH THE DATA

    The first sheet is "Read me first", built from SUMMARY.txt, and it carries
    the coverage figures and everything that was NOT READ.

    Somebody will open the workbook and never look at the text file. If the
    workbook shows fifteen tidy sheets of findings and says nothing about the
    four sections that failed, it is a more convincing wrong answer than the
    CSVs ever were. Making the output prettier must not make it less honest.

    ---------------------------------------------------------------------------
    DEPENDENCY

    ImportExcel, by Douglas Finke, Apache-2.0, from the PowerShell Gallery. It
    is NOT vendored into this repository and never should be: it is declared as
    an optional prerequisite so no third-party license travels with the kit and
    so Fieldkit's own read-only claim stays a claim about Fieldkit's own code.
#>

function Test-FieldkitExcel {
    <#
        Is ImportExcel usable in THIS PowerShell edition? Three states, as
        everywhere else.

        ---------------------------------------------------------------------
        THE EDITION TRAP

        Windows PowerShell 5.1 and PowerShell 7 have SEPARATE user module
        paths:

          5.1 (Desktop)  Documents\WindowsPowerShell\Modules
          7.x (Core)     Documents\PowerShell\Modules

        This kit runs on 5.1 by design, because that is what a client domain
        controller has. A modern admin workstation also has PowerShell 7, so a
        consultant who runs Install-Module from whichever prompt happens to be
        open can install ImportExcel into a path this kit cannot see.

        The failure is silent and genuinely confusing: the prerequisites menu
        says NOT INSTALLED while a successful install sits in another window.
        So when the module is absent, this says which edition is running and
        names the trap, rather than only reporting absence.
    #>
    $edition = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }
    $otherPath = if ($edition -eq 'Core') { 'Documents\WindowsPowerShell\Modules (5.1)' }
                 else { 'Documents\PowerShell\Modules (7.x)' }

    try {
        if (-not (Get-Module -ListAvailable -Name ImportExcel -ErrorAction Stop)) {
            $reason = "ImportExcel is not installed for PowerShell $($PSVersionTable.PSVersion) ($edition). " +
                      "If you installed it from the other PowerShell, it went to $otherPath, " +
                      'which this session cannot see. Install it from the prerequisites menu (P) ' +
                      'to put it where this session looks.'
            return [pscustomobject]@{ State = 'Absent'; Version = ''; Reason = $reason }
        }
        Import-Module ImportExcel -ErrorAction Stop
        if (-not (Get-Command Export-Excel -ErrorAction SilentlyContinue)) {
            return [pscustomobject]@{ State = 'Unknown'; Version = ''; Reason = 'ImportExcel is installed but Export-Excel did not load.' }
        }
        $v = (Get-Module ImportExcel | Select-Object -First 1).Version
        return [pscustomobject]@{ State = 'Present'; Version = $v; Reason = '' }
    }
    catch {
        return [pscustomobject]@{ State = 'Unknown'; Version = ''; Reason = $_.Exception.Message }
    }
}

function Get-FieldkitSheetName {
    <#
        A legal, unique Excel worksheet name.

        Excel allows 31 characters and forbids : \ / ? * [ ]. Section names in
        this kit routinely exceed that - "Inbound firewall rules allowing any
        remote address" is 49 - so truncation is the normal case, not the edge
        case, and two truncated names can easily collide.

        Collisions are resolved by numbering rather than by overwriting,
        because a silently dropped worksheet is a silently dropped section.
    #>
    param(
        # AllowEmptyString, because a CSV whose basename reduces to nothing
        # would otherwise fail at PARAMETER BINDING, before the fallback below
        # can handle it - killing a worksheet mid-workbook over a filename.
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Name,
        [Parameter(Mandatory)] $Used
    )

    $n = $Name -replace '[:\\/?*\[\]]', '-'
    $n = $n -replace '\s+', ' '
    $n = $n.Trim()
    if (-not $n) { $n = 'Sheet' }
    if ($n.Length -gt 31) { $n = $n.Substring(0, 31).Trim() }

    if (-not $Used.Contains($n)) { $Used.Add($n) | Out-Null; return $n }

    for ($i = 2; $i -lt 1000; $i++) {
        $suffix = " ($i)"
        $trim   = 31 - $suffix.Length
        $try    = ($(if ($n.Length -gt $trim) { $n.Substring(0, $trim).Trim() } else { $n })) + $suffix
        if (-not $Used.Contains($try)) { $Used.Add($try) | Out-Null; return $try }
    }
    $fallback = 'Sheet ' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $Used.Add($fallback) | Out-Null
    return $fallback
}

function Export-FieldkitWorkbook {
    <#
        Build one .xlsx from an output folder.

        Sheet order is deliberate:
          1. Read me first  - coverage and every gap, from SUMMARY.txt
          2. _COVERAGE      - per target, reached or not (remote runs)
          3. _SECTION-MATRIX- which sections failed, and how often
          4. combined\      - one sheet per section, all hosts
          5. everything else at the folder root

        by-host\ is EXCLUDED by default. A 200-machine sweep would produce
        thousands of worksheets, which is not a document anybody can read. Pass
        -IncludeByHost when you are looking at a handful of machines.
    #>
    param(
        [Parameter(Mandatory)] [string] $OutputFolder,
        [string] $WorkbookPath,
        [switch] $IncludeByHost,
        # Autosizing is the slow part of writing a workbook, so it is skipped on
        # very wide sheets rather than being paid for on all of them.
        [int] $AutoSizeRowLimit = 2000
    )

    $excel = Test-FieldkitExcel
    if ($excel.State -ne 'Present') {
        Write-Host ''
        Write-Host '  No workbook was written.' -ForegroundColor Yellow
        Write-Host "  $($excel.Reason)" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  The CSVs in the output folder are complete and unaffected.' -ForegroundColor DarkGray
        Write-Host ''
        return $null
    }

    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        Write-Host "  Output folder not found: $OutputFolder" -ForegroundColor Red
        return $null
    }

    if (-not $WorkbookPath) {
        $leaf = Split-Path $OutputFolder -Leaf
        $WorkbookPath = Join-Path $OutputFolder ($leaf + '.xlsx')
    }
    if (Test-Path -LiteralPath $WorkbookPath) {
        Remove-Item -LiteralPath $WorkbookPath -Force -ErrorAction SilentlyContinue
    }

    # ------------------------------------------------------------ collect CSVs
    $rootCsv     = @(Get-ChildItem -LiteralPath $OutputFolder -Filter '*.csv' -File -ErrorAction SilentlyContinue)
    $combinedDir = Join-Path $OutputFolder 'combined'
    $combinedCsv = @()
    if (Test-Path -LiteralPath $combinedDir) {
        $combinedCsv = @(Get-ChildItem -LiteralPath $combinedDir -Filter '*.csv' -File -ErrorAction SilentlyContinue)
    }
    $byHostCsv = @()
    $byHostDir = Join-Path $OutputFolder 'by-host'
    if ($IncludeByHost -and (Test-Path -LiteralPath $byHostDir)) {
        $byHostCsv = @(Get-ChildItem -LiteralPath $byHostDir -Filter '*.csv' -File -Recurse -ErrorAction SilentlyContinue)
    }

    if (($rootCsv.Count + $combinedCsv.Count + $byHostCsv.Count) -eq 0) {
        Write-Host "  No CSV files found under $OutputFolder. Nothing to build." -ForegroundColor Yellow
        return $null
    }

    # Order: coverage and matrix first, then the rest of the root alphabetically.
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($first in @('_COVERAGE.csv', '_SECTION-MATRIX.csv')) {
        $hit = $rootCsv | Where-Object { $_.Name -eq $first } | Select-Object -First 1
        # The whole chained -replace is parenthesized. Without the outer
        # brackets the comma inside the second -replace is read as a hashtable
        # separator and the line will not parse.
        if ($hit) {
            $label = (($first -replace '\.csv$', '') -replace '^_', '')
            $ordered.Add([pscustomobject]@{ File = $hit; Label = $label })
        }
    }
    foreach ($f in ($combinedCsv | Sort-Object Name)) {
        $ordered.Add([pscustomobject]@{ File = $f; Label = ($f.BaseName -replace '-', ' ') })
    }
    foreach ($f in ($rootCsv | Where-Object { $_.Name -notin @('_COVERAGE.csv','_SECTION-MATRIX.csv') } | Sort-Object Name)) {
        $ordered.Add([pscustomobject]@{ File = $f; Label = ($f.BaseName -replace '-', ' ') })
    }
    foreach ($f in ($byHostCsv | Sort-Object FullName)) {
        $hostName = Split-Path (Split-Path $f.FullName -Parent) -Leaf
        $ordered.Add([pscustomobject]@{ File = $f; Label = ("$hostName $($f.BaseName -replace '-', ' ')") })
    }

    Write-Host ''
    Write-Host ("  Building workbook from {0} CSV file(s)" -f $ordered.Count) -ForegroundColor Cyan
    Write-Host ("  ImportExcel {0}" -f $excel.Version) -ForegroundColor DarkGray

    $used = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $pkg  = $null
    $written = 0
    $failed  = [System.Collections.Generic.List[string]]::new()

    try {
        # ------------------------------------------------ sheet 1: read me first
        $readme = Get-FieldkitWorkbookReadme -OutputFolder $OutputFolder
        $name   = Get-FieldkitSheetName -Name 'Read me first' -Used $used
        $pkg    = $readme | Export-Excel -Path $WorkbookPath -WorksheetName $name `
                              -AutoSize -BoldTopRow -FreezeTopRow -PassThru
        $written++

        # ------------------------------------------------------- the data sheets
        foreach ($item in $ordered) {
            $sheet = Get-FieldkitSheetName -Name $item.Label -Used $used
            try {
                $rows = @(Import-Csv -LiteralPath $item.File.FullName -ErrorAction Stop)

                if ($rows.Count -eq 0) {
                    # An empty section is a real answer and must be visible as a
                    # sheet, not absent from the workbook.
                    $rows = @([pscustomobject]@{
                        Note = 'This section ran and returned no rows. Empty is an answer, not a gap.'
                    })
                }

                $p = @{
                    WorksheetName = $sheet
                    ExcelPackage  = $pkg
                    PassThru      = $true
                    BoldTopRow    = $true
                    FreezeTopRow  = $true
                    AutoFilter    = $true
                }
                if ($rows.Count -le $AutoSizeRowLimit) { $p['AutoSize'] = $true }
                $pkg = $rows | Export-Excel @p
                $written++
            }
            catch {
                $failed.Add("$($item.File.Name): $($_.Exception.Message)")
            }
        }

        Close-ExcelPackage $pkg
    }
    catch {
        Write-Host ''
        Write-Host "  Workbook build FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  The CSVs are unaffected and remain the complete record.' -ForegroundColor DarkGray
        if ($pkg) { try { Close-ExcelPackage $pkg -NoSave } catch { } }
        return $null
    }

    if ($failed.Count) {
        Write-Host ("  {0} sheet(s) could not be written:" -f $failed.Count) -ForegroundColor Yellow
        foreach ($f in $failed) { Write-Host "    $f" -ForegroundColor DarkGray }
        Write-Host '  Those sections are still in their CSVs.' -ForegroundColor DarkGray
    }

    Write-Host ("  {0} worksheet(s) written" -f $written) -ForegroundColor Green
    Write-Host ("  {0}" -f $WorkbookPath) -ForegroundColor Green
    Write-Host ''
    return $WorkbookPath
}

function Get-FieldkitWorkbookReadme {
    <#
        The first sheet, built from SUMMARY.txt.

        This exists so the gaps travel with the data. A workbook that shows
        only the sections that worked is a more convincing wrong answer than a
        folder of CSVs, because it looks finished.
    #>
    param([Parameter(Mandatory)] [string] $OutputFolder)

    $rows = [System.Collections.Generic.List[object]]::new()
    $add  = {
        param($section, $line)
        $rows.Add([pscustomobject]@{ Section = $section; Detail = $line })
    }

    & $add 'Fieldkit' 'This workbook was assembled from the CSV files in the output folder.'
    & $add 'Fieldkit' 'The CSVs are the record. This is a convenience for reading them.'
    & $add 'Fieldkit' ("Folder: " + $OutputFolder)
    & $add 'Fieldkit' ("Workbook built: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
    & $add '' ''

    $summaryPath = Join-Path $OutputFolder 'SUMMARY.txt'
    if (-not (Test-Path -LiteralPath $summaryPath)) {
        & $add 'WARNING' 'SUMMARY.txt was not found in this folder.'
        & $add 'WARNING' 'That file carries the coverage figures and the list of sections that did'
        & $add 'WARNING' 'NOT run. Without it, this workbook cannot tell you what is missing, so do'
        & $add 'WARNING' 'not read the sheets that follow as a complete picture.'
        return $rows
    }

    # Carry SUMMARY.txt across as-is under a heading, so nothing is
    # paraphrased and nothing is dropped.
    $current = 'SUMMARY'
    foreach ($line in (Get-Content -LiteralPath $summaryPath -ErrorAction SilentlyContinue)) {
        $t = $line.TrimEnd()
        # Underlined headings in SUMMARY.txt become the Section column.
        if ($t -match '^[-=]{3,}$') { continue }
        if ($t -match '^[A-Z][A-Z ,\-/]{3,}$') { $current = $t.Trim(); continue }
        if (-not $t) { & $add '' ''; continue }
        & $add $current $t.Trim()
    }

    return $rows
}
