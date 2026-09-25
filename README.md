# Fieldkit

A portable set of read-only PowerShell tools for the first days of a client
engagement, behind one menu.

Download it onto a client workstation or server, run one script, and work from
the menu. Everything lands in `C:\work`.

---

## Install

From an elevated PowerShell prompt on the target machine:

```powershell
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
iwr https://raw.githubusercontent.com/Grebenik/ps-fieldkit/main/Get-Fieldkit.ps1 -OutFile $env:TEMP\Get-Fieldkit.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\Get-Fieldkit.ps1
```

Then:

```powershell
powershell -ExecutionPolicy Bypass -File C:\work\Fieldkit\Start-Fieldkit.ps1
```

**If the repository is private**, the download returns 404. Either carry the ZIP
in and use `-FromZip C:\path\to\kit.zip`, or pass a read-only `-Token`. Prefer
the ZIP: a token pasted into a console on a client's server stays in that
machine's history.

**On a restricted client network** the download may be blocked by a proxy or a
TLS-inspecting firewall. Carrying the ZIP in is the reliable path and takes less
time than arguing with the firewall.

---

## Why `C:\work`

Temp gets cleaned out, and a folder called `Scripts` is often already in use by
the client for something of their own. A folder called `work` at the root of
`C:` is unambiguous, both while you are using it and six months later when
someone asks what was put on the server.

```
C:\work\
  Fieldkit\     the kit itself
  Output\       one folder per tool run, named tool-host-date-time
  Logs\         what this kit did on this machine, and when
```

`-WorkRoot` moves all of it if the client insists on somewhere else.

---

## What it changes

Nothing, with one exception.

Every tool is read-only. Every directory command is a `Get-`, nothing is
created, modified or deleted, and no update or scan is triggered. That claim is
part of what makes a run authorizable in the first place, so it is worth being
able to make it precisely.

**The one exception is installing a prerequisite** from the prerequisites menu.
That writes to the machine. It asks first, shows the exact command it is about
to run, requires the word `INSTALL` to be typed rather than a keypress, and
records what it did in `C:\work\Logs`. You should be able to tell the client
exactly what you left behind.

---

## The menu

```
 ACTIVE DIRECTORY
  1  [needs Active Directory PowerShell module]  Active Directory Snapshot
  2  [ready]  Group Policy Inventory

 HOST
  3  [ready]  Host Snapshot
  4  [ready]  Patch Posture

  number   run that tool
  P        prerequisites: check what is here, install what is not
  F        force-run a tool, skipping the prerequisite check
  I        information about a tool, without running it
  O        open the output folder
  L        show this machine's Fieldkit log
  R        refresh
  U        update the kit from GitHub
  Q        quit
```

A tool that is missing something is not hidden and does not fail halfway
through. It is marked with what it needs, and choosing it offers to install
that thing, to run it anyway, or to go back.

**`F` runs a tool with no prerequisite check at all.** Use it when you know
better than the check does: a module present under a path the detection does
not look at, a machine where the detection itself is broken, or a tool you only
want the working half of. The failure then comes from the tool rather than from
the check, and it says so before it starts.

---

## Prerequisites

| Id | What | Installed with |
|---|---|---|
| `RSAT-AD` | ActiveDirectory module | `Install-WindowsFeature` on a server, `Add-WindowsCapability` on a workstation |
| `RSAT-GP` | GroupPolicy module | as above |
| `RSAT-DNS` | DnsServer module | as above |
| `RSAT-DHCP` | DhcpServer module | as above |
| `PS-MODULE-PSWindowsUpdate` | PSWindowsUpdate | PowerShell Gallery, CurrentUser scope |
| `ELEVATION` | administrator rights | not installable; restart PowerShell elevated |

The installer picks the right command for the machine it is on. A workstation
has no `Install-WindowsFeature` and a server has no RSAT optional capability,
so offering the wrong one produces a confusing failure rather than an install.

Capability names carry a build-specific version suffix, so the installer
searches for the real name rather than hardcoding one that works on only some
versions of Windows.

### Three states, not two

Detection returns **Present**, **Absent** or **Unknown**, and `Unknown` is not a
polite way of saying `Absent`. If the check itself failed, nothing is known
either way, and reporting "not installed" when the truth is "could not tell" is
how a missing tool turns into a wrong finding.

---

## How the output reads

Every tool writes one folder of CSVs plus a `SUMMARY.txt`, and every section
reports one of three things:

| Console | Means |
|---|---|
| `12 rows` | the question was asked and answered |
| `no rows` | the question was asked and the answer is empty |
| `NOT READ` | **the question was never answered** |

`SUMMARY.txt` ends with every section that did not run, under a heading saying
not to read their absence as a clean result.

This is the whole point of the kit's structure. An audit that cannot tell
"there is no problem" apart from "nobody looked" will eventually report the
second as the first, and it will do it in a document with your name on it.

---

## The tools

| Tool | Needs | Answers |
|---|---|---|
| **Host Snapshot** | nothing | What is this machine, what runs on it, who administers it, how far back could an investigation reach |
| **Patch Posture** | nothing | Where does it get updates, is it allowed to install them, when did it last actually do so |
| **Active Directory Snapshot** | `RSAT-AD` | Functional levels, FSMO roles, trusts, password policy, privileged groups, krbtgt age, stale and risky accounts |
| **Group Policy Inventory** | `RSAT-GP`, `RSAT-AD` | Every GPO, where it is linked, what is unlinked or empty, and optional full settings reports |

Two details worth knowing, because they are the ones that silently produce
wrong answers:

**Group names are localized.** On a Finnish machine the local Administrators
group is `Järjestelmänvalvojat`; on a German one, `Administratoren`. Asking for
the English name returns "group was not found", which reads exactly like a
machine with no local administrators. Everything with a well-known SID is
looked up by SID, and the report shows what the group is actually called.

**`Get-ADGroupMember` throws a terminating error** when the group is not in the
target domain, and `-ErrorAction SilentlyContinue` does not suppress it.
Enterprise Admins and Schema Admins exist only in the forest root, so one query
against a child domain would otherwise end the whole loop at the first group.
Each group is wrapped on its own, and a group that is not present is recorded as
not present rather than as empty.

---

## Adding a tool

Drop a `.ps1` file in `Tools\`. It appears in the menu on the next refresh with
no change to the menu itself. See [Docs/ADDING-A-TOOL.md](Docs/ADDING-A-TOOL.md).

---

## What is not in here

**No client data.** No findings, no exports, no hostnames, no addresses, no
client names. This repository is tooling. Anything collected on an engagement
lives in that engagement's own storage, never here.
