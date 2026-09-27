# Building the Windows 11 jumpbox

What `Get-JumpboxPosture` is measuring against, and how to fix what it flags.

This is not a full privileged access workstation standard. It is the set of
controls that are free, that fit on a consultant's admin machine, and that
change the outcome if the machine is attacked.

---

## Why this machine matters more than the ones you are auditing

Every credential you use on an engagement passes through it. If it is
compromised, so is every client environment reachable from it — and unlike a
client's estate, nobody else is auditing this one.

It is also the machine you will be asked about. A client's security team is
entitled to ask what is connecting to their domain controllers with
administrative rights, and "my laptop" is a worse answer than a posture report.

---

## The controls, in the order worth fixing them

### 1. Credential Guard — the single biggest one

Without it, LSASS holds secrets in ordinary memory and any administrator on the
box can harvest every credential used from it. With it, they are in a
VBS-isolated container.

Needs Secure Boot and virtualization enabled in firmware. On Windows 11
Enterprise it is often on by default; on Pro it usually is not.

```text
Computer Configuration → Administrative Templates → System → Device Guard
  Turn On Virtualization Based Security
    Platform Security Level: Secure Boot and DMA Protection
    Credential Guard Configuration: Enabled with UEFI lock
```

Verify with the tool, not with the policy: `SecurityServicesRunning` must
contain Credential Guard. **Configured and running are different states**, and
the policy being set is not evidence that it took effect.

### 2. LSA protection

```text
HKLM\SYSTEM\CurrentControlSet\Control\Lsa
    RunAsPPL = 1
```

Makes LSASS a protected process. Cheap, and it blocks the ordinary
handle-open used to read its memory.

### 3. Cached domain logons

```text
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon
    CachedLogonsCount = 1
```

The default is 10. Each cached logon is a credential verifier on the disk. On a
machine that is always on a network with a domain controller, this can be 0; 1
is the safe compromise if you ever work offline.

### 4. Restricted Admin for outbound RDP

```text
Computer Configuration → Administrative Templates → System → Credentials Delegation
  Restrict delegation of credentials to remote servers
    Use the following restricted mode: Require Restricted Admin
```

**This is the one most often missed and it matters most for a jumpbox.**
Without it, an RDP session from here leaves reusable credentials on the server
you connect to. The trust is meant to flow the other way: the jumpbox trusts
nothing downstream, and nothing downstream should end up holding your ticket.

Note that Restricted Admin changes how the remote session authenticates
onward — network access from inside the session uses the machine account, so
some administrative tasks behave differently. Know that before you turn it on
mid-engagement.

### 5. PowerShell logging and transcription

```text
Computer Configuration → Administrative Templates → Windows Components → Windows PowerShell
  Turn on PowerShell Script Block Logging: Enabled
  Turn on PowerShell Transcription: Enabled
    Output directory: D:\Transcripts   (not C:\work)
```

On the machine all administration is run from, this is the highest-value log
there is. **It also records your own work, which is the point**: a transcript is
the cheapest possible run record, and it answers "what exactly did you run on
our network" with evidence instead of recollection.

Put the output somewhere other than `C:\work`, so a transcript is not sitting
inside the folder you zip up and send to a client.

### 6. Remove the PowerShell v2 engine

```powershell
Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root
```

The v2 engine bypasses script block logging, AMSI and constrained language. It
is a one-line downgrade attack and nothing needs it.

### 7. BitLocker with a TPM

An unencrypted admin workstation gives up its cached credentials, its saved
output and its transcripts to anyone who takes the disk. TPM plus PIN if the
machine leaves the building.

### 8. LAPS for the local administrator account

Windows LAPS ships in-box on Windows 11. `BackupDirectory` 1 backs the password
to Entra ID, 2 to Active Directory. Without it, the local administrator password
is static and probably shared with every other machine built from the same
image.

### 9. Application control

An admin workstation runs a small, known set of software, which makes it the
easiest machine in any estate to put under AppLocker or WDAC. Worth doing after
the credential controls, not before — it takes tuning and the others do not.

---

## RSAT on Windows 11, and the failure you will hit

RSAT is a Feature on Demand and comes from Windows Update. **On a machine
managed by WSUS the install fails with `0x800f0954`**, because the request goes
to WSUS, which does not carry the payload. The error says nothing about WSUS.

Fieldkit predicts this before you try. The prerequisites menu reports the
optional feature source as `OK`, `BLOCKED` or `COULD NOT DETERMINE`, and on
`BLOCKED` it prints the fix:

```text
Computer Configuration → Administrative Templates → System
  Specify settings for optional component installation and component repair
    [x] Download repair content and optional features directly from
        Windows Update instead of Windows Server Update Services (WSUS)
```

That writes `RepairContentServerSource = 2` under
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing`.

It is a change, so it goes through change control. If that will take days,
carrying the module in from another machine is usually faster than waiting.

---

## Things to decide rather than fix

**A real privileged access workstation has no browser and no mail client.** Most
consultants' machines have both, because the same machine writes the report and
joins the call. The tool reports browsing and mail software as `INFO`, not as a
fault, because pretending otherwise is not useful.

What is worth deciding deliberately:

- **Separate accounts.** The account that reads email is not the account that
  administers a domain. This is the control that survives even when the machine
  is not a true PAW.
- **Separate browser profiles**, or no browsing at all while an admin session is
  open.
- **Where client output lives.** `C:\work` on an encrypted disk, cleared between
  engagements, and never the same folder as a transcript.

**Tier-0 credentials in your session.** The posture tool reports whether your
token holds Domain, Enterprise or Schema Admin. Sometimes it has to. The point
is that it should be a deliberate, temporary state rather than how you work all
day.

---

## Running the check

```powershell
powershell -ExecutionPolicy Bypass -File C:\work\Fieldkit\Start-Fieldkit.ps1
```

Pick **Jumpbox Posture**. Run it elevated: BitLocker, TPM, Secure Boot, the
optional-feature state and the audit policy cannot be read without it.

It does not refuse when unelevated, because a partial read still tells you
something. It reports those controls as `UNKNOWN` and says at the top of
`SUMMARY.txt` that the run is not an assessment.

**`UNKNOWN` is not a pass.** Two of the three defects found while building this
tool were controls that could not be measured being reported as controls that
had failed: `Get-Tpm` returns empty properties instead of throwing when it lacks
rights, and `Get-NetFirewallProfile` returns `NotConfigured` for anything no
policy sets, while Windows blocks inbound by default. Both read as a broken
machine when nothing was wrong.
