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

**On a restricted client network** the download may be blocked by a proxy or a
TLS-inspecting firewall, and on an isolated segment there is no route at all.
Download the ZIP on your own machine, carry it in, and use:

```powershell
powershell -ExecutionPolicy Bypass -File .\Get-Fieldkit.ps1 -FromZip C:\path\to\kit.zip
```

That is the reliable path and it takes less time than arguing with the firewall.

**`-Update` replaces an existing copy.** Output and logs are never touched,
because they live outside the kit folder. Without `-Update`, installing over an
existing copy is refused rather than done silently.

---

## Why `C:\work`

Temp gets cleaned out, and a folder called `Scripts` is often already in use by
the client for something of their own. A folder called `work` at the root of
`C:` is unambiguous, both while you are using it and six months later when
someone asks what was put on the server.

```text
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

```text
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

`T` sets a list of remote systems; with one set, choosing a tool asks whether you
meant this machine or the targets. See [Docs/REMOTE.md](Docs/REMOTE.md).

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
| `RSAT-ADCS` | ADCSAdministration module | as above |
| `RSAT-SERVERMGR` | ServerManager module | workstation only; built in on Server |
| `PS7` | PowerShell 7 | `winget`. A convenience: every tool here runs on 5.1 |
| `PS-MODULE-PSWindowsUpdate` | PSWindowsUpdate | PowerShell Gallery, CurrentUser scope |
| `ELEVATION` | administrator rights | not installable; restart PowerShell elevated |

The installer picks the right command for the machine it is on. A workstation
has no `Install-WindowsFeature` and a server has no RSAT optional capability,
so offering the wrong one produces a confusing failure rather than an install.

Capability names carry a build-specific version suffix, so the installer
searches for the real name rather than hardcoding one that works on only some
versions of Windows.

### The RSAT install that fails on a managed workstation

RSAT is a Feature on Demand and comes from Windows Update. **On a machine
managed by WSUS the install fails with `0x800f0954`**, because the request goes
to WSUS, which does not carry the payload. The error message says nothing about
WSUS, so the usual response is to re-run it, check the capability name, check
the network, and find the cause an hour later.

That state is knowable in advance from two registry values, so the prerequisites
menu reads them and reports the optional feature source as `OK`, `BLOCKED` or
`COULD NOT DETERMINE` **before** you try. On `BLOCKED` it prints the policy that
fixes it, and notes that carrying the module in from another machine is often
faster than getting the change approved.

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
| **Remote Readiness** | nothing | Which targets can be reached, by WinRM or DCOM, which answer nothing at all, and which names are stale AD objects rather than unreachable machines |
| **Jumpbox Posture** | nothing | **Audits the admin workstation you are standing on**: Credential Guard, LSA protection, BitLocker, cached logons, RDP delegation, PowerShell logging, application control, LAPS, and what privilege your own token holds |

**Jumpbox Posture is the one that audits you.** Every credential you use on an
engagement passes through that machine, and it is the only one nobody else is
checking. It produces a control summary with `OK` / `WEAK` / `UNKNOWN` per
control, and it is deliberately unflattering. See
[Docs/JUMPBOX-BUILD.md](Docs/JUMPBOX-BUILD.md) for what each finding means and
how to fix it.

Two things it detects and never reads: the Winlogon autologon password value,
and any LAPS-managed password. Presence and configuration are reported; a
cleartext secret written into a CSV that then travels is a worse outcome than
the finding.

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

## Excel output

`X` builds one formatted `.xlsx` from an output folder, and a run builds one
automatically when ImportExcel is installed. Sheets get a bold frozen header row
and an autofilter; `combined\` becomes one sheet per section.

**It post-processes the CSVs.** No tool knows it exists and no tool changed. The
CSVs stay the record — a workbook is a convenience for whoever reads it — and if
ImportExcel is missing, nothing is lost.

**Sheet 1 is "Read me first", built from `SUMMARY.txt`.** It carries the coverage
figures and everything that was `NOT READ`. Somebody will open the workbook and
never look at the text file, and fifteen tidy sheets that say nothing about the
four sections which failed is a more convincing wrong answer than the CSVs ever
were. Making output prettier must not make it less honest.

Per-host sheets are excluded by default (`H<n>` in the menu includes them). A
200-machine sweep would otherwise produce thousands of worksheets.

**ImportExcel is not vendored** — Apache-2.0, by Douglas Finke, declared as an
optional prerequisite and installed from the Gallery. No third-party license
travels with this repo, and Fieldkit's read-only claim stays a claim about
Fieldkit's own code.

> **Install it from the same PowerShell you run the kit in.** Windows PowerShell
> 5.1 and PowerShell 7 have **separate user module paths**
> (`Documents\WindowsPowerShell\Modules` vs `Documents\PowerShell\Modules`). This
> kit targets 5.1 because that is what a domain controller has, so installing
> from a 7.x prompt puts the module where the kit cannot see it. The prerequisites
> menu reports that case by name rather than just saying "not installed".

---

## Remote targeting

`T` in the menu sets a list of remote systems. Tools marked `Remote: Yes` are
then shipped to each target and **write nothing to it** — they run through a shim
that returns objects, so no folder is created and nothing is copied back.

**Coverage is reported before any finding.** With 200 targets, "we assessed the
estate and found three problems" is a dangerous sentence if 150 were never
reached, so every run leads with reached, unreachable, and why.

**Targets are never implied.** Explicit lists, a file you have read, or
`-FromAD` — and the AD path shows the resolved list, honors an exclusion file,
and requires typed confirmation before contacting anything.

Run `Test-RemoteReadiness` first. Full detail in [Docs/REMOTE.md](Docs/REMOTE.md).

---

## Adding a tool

Drop a `.ps1` file in `Tools\`. It appears in the menu on the next refresh with
no change to the menu itself. See [Docs/ADDING-A-TOOL.md](Docs/ADDING-A-TOOL.md).

---

## What is not in here

**No client data.** No findings, no exports, no hostnames, no addresses, no
client names. This repository is tooling. Anything collected on an engagement
lives in that engagement's own storage, never here.

**This repository is public**, which is what makes the one-line install work
without a credential on a client machine. That is also why the rule above is
absolute rather than a preference: there is no private corner of this repo to
put something in by mistake. Output is written to `C:\work` on the machine being
examined and is `.gitignore`d here, but the real safeguard is not committing it
in the first place.
