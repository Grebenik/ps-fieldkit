# Adding a tool

Drop a `.ps1` file into `Tools\`. It appears in the menu on the next refresh.
The menu is not edited, and there is no list to keep in step.

---

## The header block

The menu reads this block out of the file. It **reads** it, never runs the file,
because describing a tool must not mean executing it.

```powershell
<#FIELDKIT
Name      : Certificate Services Review
Category  : PKI
Summary   : Templates, enrolment rights, and certificates issued to privileged accounts.
Requires  : RSAT-AD
Elevation : Required
Scope     : Domain
Output    : PKIReview
ReadOnly  : Yes
FIELDKIT#>
```

| Field | Notes |
|---|---|
| `Name` | What appears in the menu. Plain words, not the file name. |
| `Category` | Menu grouping. Reuse an existing one where it fits. |
| `Summary` | One line, under the name. Say what it answers, not what it enumerates. |
| `Requires` | Comma-separated ids from the prerequisite catalog, or `None`. |
| `Elevation` | `Required`, `Recommended` or `Not needed`. **`Required` greys the tool out when the session is not elevated**; `Recommended` does not. |
| `Scope` | `Local machine`, `Domain`, `Forest`. Tells the reader where the answer comes from. |
| `Output` | Prefix for the output folder. |
| `ReadOnly` | `Yes` unless it genuinely is not, and then say so plainly. |

A file with no header block still appears, marked as undocumented, rather than
being silently skipped. A tool that is invisible because of a typo is worse than
one that is visible and unlabeled.

---

## The shape of a tool

```powershell
<#FIELDKIT
... header ...
FIELDKIT#>

[CmdletBinding()]
param(
    [string] $Server
)

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Lib\Fieldkit.Common.ps1')

$out   = New-FieldkitOutputFolder -ToolOutputName 'PKIReview'
$notes = [System.Collections.Generic.List[string]]::new()

Write-FieldkitHeader -Title 'Certificate Services Review' -OutputFolder $out

Invoke-FieldkitSection -Name 'Certificate templates' -OutputFolder $out -Notes $notes -Body {
    Get-ADObject -LDAPFilter '(objectClass=pKICertificateTemplate)' -Properties * -ErrorAction Stop |
        Select-Object Name, whenChanged, msPKI-Certificate-Name-Flag
}

Write-FieldkitSummary -Title 'Certificate Services Review' -OutputFolder $out -Notes $notes
```

Parameters are fine. The menu runs a tool with none, so **every parameter needs
a sensible default**, and anything that genuinely has no default belongs in a
tool that is run directly rather than from the menu.

---

## `Invoke-FieldkitSection` is the point

Wrap every collection step in it. It writes the CSV, counts the rows, and
handles the failure, but the reason it exists is the three-way outcome:

| Outcome | Written | Meaning |
|---|---|---|
| `12 rows` | the CSV | asked and answered |
| `no rows` | nothing | asked, and the answer is empty |
| `NOT READ` | the reason, into `SUMMARY.txt` | **never answered** |

Use `-ErrorAction Stop` inside the body. A command that fails quietly and
returns nothing is recorded as an empty answer, which is the one outcome that
must never be faked.

### Say it in the row, not only in the console

Where a row can be absent for two different reasons, put the reason in the row:

```powershell
catch {
    [pscustomobject]@{
        Group = $label
        Member = ''
        Note = 'GROUP NOT PRESENT IN THIS DOMAIN - not the same as empty'
    }
}
```

Whoever reads the CSV in three weeks will not have the console output, and
"this row is blank" and "this row is blank because the query failed" lead to
different reports.

---

## Things that have already bitten

**Group names are localized.** `Administrators` is `Järjestelmänvalvojat` on a
Finnish machine and `Administratoren` on a German one. Look up anything with a
well-known SID by SID: `Get-LocalGroupMember -SID 'S-1-5-32-544'`,
`Get-ADGroup -Identity "$domainSid-512"`. The English name goes in the report,
never in the query.

**`Get-ADGroupMember` throws a terminating error** for a group that is not in
the target domain, and `-ErrorAction SilentlyContinue` does not suppress it.
Wrap each group separately or one absent group ends the whole loop.

**Native tools do not throw.** `auditpol`, `nltest`, `dsregcmd` and the rest
signal failure through `$LASTEXITCODE`. Searching their output text for a
keyword when the command itself failed means searching an error message, which
is how "auditing appears to be enabled" gets reported from exit code 1314.
Check the exit code first.

**Counting events is not free.** `Get-WinEvent -Path $f | Measure-Object` reads
every record; on a 20 MB file that is twenty seconds, and on a large one it
looks like a hang. Use the log's own record count:

```powershell
$session = New-Object System.Diagnostics.Eventing.Reader.EventLogSession
$session.GetLogInformation($path, [System.Diagnostics.Eventing.Reader.PathType]::FilePath).RecordCount
```

**`$rows += $item` is quadratic.** It rebuilds the array every time. Use
`[System.Collections.Generic.List[object]]::new()` and `.Add()`.

**`[ordered]@{}` with integer keys indexes by position.** In an ordered
dictionary, `$catalog[4624]` asks for the 4624th entry, not the entry keyed
4624. Use a plain `@{}` and sort the keys when you need order.

**`Join-Path` throws on a drive that does not exist**, and its message is
"Cannot bind argument to parameter 'Path' because it is null", which points at
the wrong thing entirely. Keep it inside the `try` that handles the path.

---

## Before it goes in

1. **Run it.** Parse-checking finds syntax errors and nothing else. Every defect
   in the list above survived a clean parse.
2. **Run it unelevated**, and check the sections that need rights say `NOT READ`
   rather than returning empty.
3. **Read `SUMMARY.txt`** as if you had not written the tool.
4. **Confirm it is read-only.** Every AD command a `Get-`, nothing written
   outside `C:\work`, no scan or update triggered. If it is not read-only, the
   header must say so and the tool must ask before it acts.
