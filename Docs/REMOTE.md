# Targeting remote systems

Running a tool against other machines from the console, rather than walking to
each one.

---

## Coverage comes before findings

This is the rule the whole design is built around.

With one machine, a failed section is obvious: it says `NOT READ` on the screen
in front of you. With two hundred machines it is not obvious at all, and the
failure mode is specific:

> *"We assessed 200 servers and found three problems."*

when in truth 150 were never reached, and the three problems are all that exists
among the 50 that answered. The report is worse than no report, because it reads
as reassurance.

So every remote run leads with coverage:

```text
COVERAGE - READ THIS BEFORE ANY FINDING
---------------------------------------
  Targeted    : 203
  Reached     : 189
  UNREACHABLE : 14
  Coverage    : 93.1%

  Any conclusion drawn from this run applies ONLY to the machines that
  were reached.
```

Every unreachable target is named, with the reason. **A production system that
answers no management transport at all is a finding in its own right**, separate
from whatever the tool was looking for. It means nothing else is managing it
either.

---

## Nothing is written to a target

Tools run on the target through `Fieldkit.RemoteShim.ps1`, which defines the same
function names as the real library but **returns objects instead of writing
files**. No folder is created on the target, nothing is copied back, nothing
needs cleaning up. The console writes every file.

*"We connected, we read, and we wrote nothing to your server"* is a much better
sentence than *"we left a folder on each of your domain controllers"*, and it is
the one worth being able to say.

---

## Targets are never implied

Nothing is contacted unless you said what to contact. Three sources:

| Source | How |
|---|---|
| Typed list | `-ComputerName SRV01,SRV02` |
| A file you have read | `-InputFile C:\work\targets.txt` — one name per line, or a CSV with a `Name` / `ComputerName` / `DNSHostName` column |
| Active Directory | `-FromAD` — **shows the list and requires typed confirmation** |

`-FromAD` is gated because it is the source that can quietly reach a machine
nobody meant to touch:

```text
  TARGET LIST
  Source   : Active Directory, filter: OperatingSystem -like '*Server*'
  Resolved : 203
  Excluded : 14 by 3 pattern(s)
             LAB-HPLC-01  (matched LAB-*)
             ...

  WILL CONTACT 189 SYSTEM(S)

  Type CONTACT to proceed, anything else to cancel:
```

### Exclusions

`-ExcludeFile` takes one pattern per line, wildcards allowed, `#` for comments.
Use it for anything fragile: instrument controllers, embedded systems,
appliances.

```text
# Laboratory instrument control PCs - do not contact
LAB-*
*-HPLC-*
GCMS0*
```

**A missing exclusion file is an error, not an empty list.** An exclusion file
that silently does not exist is worse than having none at all, so the run stops
rather than proceeding unprotected.

---

## Transports

| Transport | Used for | Note |
|---|---|---|
| **WinRM** | the tool sweep | Kerberos in-domain. TCP 5985/5986. |
| **DCOM/CIM** | reachability probing only | TCP 135 plus dynamic ports. Often works where WinRM was never enabled. |

**CredSSP is deliberately not offered.** WinRM with Kerberos does not leave
reusable credentials on the target; CredSSP does. If you find yourself wanting
it, the answer is almost always a different approach rather than delegated
credentials on a client's server.

The credential in the menu is held in memory for the session and never written
anywhere. Leave it unset to use the account the session is already running as.

---

## Run the readiness probe first

```powershell
.\Test-RemoteReadiness.ps1 -InputFile C:\work\targets.txt
```

It tells you what a sweep could even reach, and it separates two findings that
are easy to conflate:

| Result | Means |
|---|---|
| **WinRM** | the full tool sweep will work |
| **DCOM only** | reachable by CIM, but the tool sweep cannot run against it |
| **Nothing answers** | resolves in DNS and answers no management transport. **A finding.** |
| **Name does not resolve** | most likely a **stale AD computer object**, which is housekeeping, not an exposure |

Counting stale directory objects as unreachable servers inflates a problem that
is really cleanup. The probe keeps them apart on purpose.

---

## What each tool can do

The `Remote` field in a tool's `FIELDKIT` header says how it reaches other
machines:

| Value | Meaning | Tools |
|---|---|---|
| `Yes` | shipped to the target through the shim | Host Snapshot, Patch Posture, Jumpbox Posture |
| `Native` | reaches other machines itself, via `-Server` / `-DomainName` | AD Snapshot, GPO Inventory |
| `Console` | runs here, targets remote machines itself | Remote Readiness |
| `No` | local only | — |

A `Native` tool is not shipped anywhere. It already queries the directory over
LDAP from wherever it runs, so a target list would be meaningless to it.

---

## Output layout

```text
C:\work\Output\HostSnapshot-REMOTE-<console>-<timestamp>\
  SUMMARY.txt            coverage first, then what failed and where
  _COVERAGE.csv          every target, reached or not, and why
  _SECTION-MATRIX.csv    per section: how many hosts returned rows, empty, failed
  combined\              one CSV per section, all hosts, ComputerName column first
  by-host\<HOST>\        the same data per machine, plus SECTIONS.txt
```

`combined\` is usually what you want: the interesting question across an estate
is comparative. `by-host\` is for when one machine turns out to matter.

**Large sections are capped** at 5,000 rows per host per section, because a
sweep of 200 machines returning every firewall rule is a lot of data to carry
over the wire. Truncation is visible: `RowCount` keeps the true total, and the
notes say what was cut. A silently shortened result is a wrong answer that looks
like a right one.

---

## What is not yet proven

**The WinRM success path has not been exercised against a live server.** The
payload composition, the shim, the row capping, the coverage reporting and the
unreachable path are all tested. The leg that has never run is a tool completing
successfully over WinRM on a real remote machine, because the development
machine has WinRM disabled and enabling it there would prove nothing about a
client's estate.

Validate it once, on one server, before pointing it at two hundred:

```powershell
.\Test-RemoteReadiness.ps1 -ComputerName ONE-SERVER
# then, from the menu: T to set that one target, pick Host Snapshot, R
```

Compare that result against running Host Snapshot locally on the same server. If
the two agree, the transport is good.
