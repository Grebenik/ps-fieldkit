<#
    Get-Fieldkit.ps1

    Download the kit onto a machine and put it in C:\work\Fieldkit.

    This is the only file you ever need to get onto a new client machine by
    hand. Everything else comes down with it.

    ---------------------------------------------------------------------------
    THE ONE-LINER

    From an elevated PowerShell prompt on the target machine:

        [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
        iwr https://raw.githubusercontent.com/Grebenik/ps-fieldkit/main/Get-Fieldkit.ps1 -OutFile $env:TEMP\Get-Fieldkit.ps1
        powershell -ExecutionPolicy Bypass -File $env:TEMP\Get-Fieldkit.ps1

    The repository is public, so that works with no credential of any kind.

    On a network that blocks it, or an isolated segment with no route out,
    download the ZIP on your own machine and use -FromZip. That is the reliable
    path and it takes less time than arguing with a proxy.

    ---------------------------------------------------------------------------
    A WORD ABOUT TOKENS ON CLIENT MACHINES

    Pasting a GitHub token into a console on a client's server puts your
    credential in that machine's history and possibly in its transcript logs.
    Prefer carrying the ZIP on a USB stick or through the client's own file
    transfer. If you must use a token, make it read-only, scoped to this one
    repository, and revoke it when the engagement ends.
#>

[CmdletBinding()]
param(
    [string] $Repo        = 'Grebenik/ps-fieldkit',
    [string] $Branch      = 'main',
    [string] $Destination = 'C:\work\Fieldkit',

    # A read-only personal access token, for a private repository.
    [string] $Token,

    # Replace an existing copy. Output and logs are never touched.
    [switch] $Update,

    # Install from a ZIP already on disk instead of downloading.
    [string] $FromZip
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  $m" -ForegroundColor Yellow }
function Write-Bad  { param($m) Write-Host "  $m" -ForegroundColor Red }

Write-Host ''
Write-Host '  FIELDKIT INSTALLER' -ForegroundColor Cyan
Write-Host '  ------------------' -ForegroundColor Cyan
Write-Host ''

# Older servers still negotiate TLS 1.0 by default, and GitHub refuses it. The
# failure looks like a connection reset rather than a protocol problem, so set
# this before the first request rather than debugging it afterwards.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$temp = Join-Path $env:TEMP ('fieldkit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $temp -Force
$zip  = Join-Path $temp 'kit.zip'

try {
    # ------------------------------------------------------------------ fetch
    if ($FromZip) {
        if (-not (Test-Path -LiteralPath $FromZip)) { throw "ZIP not found: $FromZip" }
        Write-Step "Using local ZIP: $FromZip"
        Copy-Item -LiteralPath $FromZip -Destination $zip -Force
    }
    else {
        $url = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
        Write-Step "Downloading $url"
        $headers = @{}
        if ($Token) { $headers['Authorization'] = "token $Token" }
        try {
            Invoke-WebRequest -Uri $url -OutFile $zip -Headers $headers -UseBasicParsing -ErrorAction Stop
        }
        catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            Write-Host ''
            if ($status -eq 404) {
                Write-Bad 'GitHub returned 404.'
                Write-Host ''
                Write-Warn 'That is what a PRIVATE repository looks like to an unauthenticated'
                Write-Warn 'request. It does not necessarily mean the repository is missing.'
                Write-Host ''
                Write-Host '  Three ways forward:'
                Write-Host ''
                Write-Host '    1. Download the ZIP on your own laptop, copy it to this machine,'
                Write-Host '       and run:   .\Get-Fieldkit.ps1 -FromZip C:\path\to\kit.zip'
                Write-Host ''
                Write-Host '    2. Use a read-only token scoped to this repository:'
                Write-Host '                  .\Get-Fieldkit.ps1 -Token ghp_xxx'
                Write-Host '       Remember it lands in this machine''s console history.'
                Write-Host ''
                Write-Host '    3. Make the repository public. It holds no client data.'
            }
            elseif ($status -eq 401 -or $status -eq 403) {
                Write-Bad "GitHub returned $status. The token was rejected or has no access to $Repo."
            }
            else {
                Write-Bad "Download failed: $($_.Exception.Message)"
                Write-Host ''
                Write-Warn 'If this is a client network, an outbound proxy or a TLS-inspecting'
                Write-Warn 'firewall may be in the way. Carrying the ZIP in is the reliable path.'
            }
            Write-Host ''
            throw 'Download failed.'
        }
        Write-Ok ("Downloaded {0:N0} KB" -f ((Get-Item $zip).Length / 1KB))
    }

    # ---------------------------------------------------------------- extract
    Write-Step 'Extracting'
    $expand = Join-Path $temp 'x'
    $null = New-Item -ItemType Directory -Path $expand -Force
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath $expand -Force -ErrorAction Stop
    }
    catch {
        # Expand-Archive arrived in PowerShell 5.0. Fall back for anything older.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $expand)
    }

    # A GitHub branch ZIP contains a single folder named repo-branch.
    $root = @(Get-ChildItem -LiteralPath $expand -Directory) | Select-Object -First 1
    if (-not $root) { throw 'The archive did not contain the expected folder.' }
    if (-not (Test-Path (Join-Path $root.FullName 'Start-Fieldkit.ps1'))) {
        throw 'Start-Fieldkit.ps1 is not in the archive. This is not a Fieldkit package.'
    }

    # ---------------------------------------------------------------- install
    if ((Test-Path -LiteralPath $Destination) -and -not $Update) {
        Write-Host ''
        Write-Warn "$Destination already exists."
        Write-Host '  Run again with -Update to replace the scripts. Output and logs are'
        Write-Host '  kept either way, because they live outside this folder.'
        Write-Host ''
        throw 'Destination exists.'
    }

    if (Test-Path -LiteralPath $Destination) {
        Write-Step "Replacing the scripts in $Destination"
        # Remove only the kit's own folders, never anything a previous run left
        # behind that is not ours.
        foreach ($sub in @('Lib', 'Tools', 'Docs')) {
            $p = Join-Path $Destination $sub
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
    }
    else {
        Write-Step "Creating $Destination"
    }
    $null = New-Item -ItemType Directory -Path $Destination -Force
    Copy-Item -Path (Join-Path $root.FullName '*') -Destination $Destination -Recurse -Force

    # Files that came from the internet carry a mark of the web, and PowerShell
    # refuses to run them under some execution policies. Clearing it here is
    # what stops the first run failing for a reason that looks like a bug.
    Write-Step 'Unblocking downloaded files'
    Get-ChildItem -LiteralPath $Destination -Recurse -File -Include *.ps1, *.psm1, *.psd1 |
        Unblock-File -ErrorAction SilentlyContinue

    # -------------------------------------------------------------- workspace
    foreach ($d in @('C:\work', 'C:\work\Output', 'C:\work\Logs')) {
        if (-not (Test-Path -LiteralPath $d)) { $null = New-Item -ItemType Directory -Path $d -Force }
    }

    $toolCount = @(Get-ChildItem -LiteralPath (Join-Path $Destination 'Tools') -Filter *.ps1 -File -ErrorAction SilentlyContinue).Count

    Write-Host ''
    Write-Ok "Installed to $Destination"
    Write-Ok "$toolCount tool(s) available"
    Write-Host ''
    Write-Host '  Start it with:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "      powershell -ExecutionPolicy Bypass -File $Destination\Start-Fieldkit.ps1"
    Write-Host ''
    Write-Host '  Run it elevated where you can. The menu marks which tools need it.'
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Bad "Install did not complete: $($_.Exception.Message)"
    Write-Host ''
    exit 1
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0
