#Requires -Version 5.1
<#
.SYNOPSIS
    Enable WSL2, install Ubuntu if needed, and bootstrap a lean developer guest.

.DESCRIPTION
    Windows host entrypoint for a lean Omarchy-inspired WSL2 Ubuntu environment.

    Checks that this machine can actually run WSL2, enables the required Windows
    features idempotently, installs or updates WSL + Ubuntu without destroying an
    existing healthy distro, creates/configures a named Linux user, then runs
    guest/bootstrap.sh non-interactively.

    Reboot: enabling features often requires one reboot. The script saves the
    chosen username and exits 3010. Re-run the same command after reboot.

    Run from 64-bit Windows PowerShell, not from inside WSL.

.PARAMETER Username
    Linux account to create or reuse. If omitted, you are prompted (Windows
    username is offered as a default, never a random name).

.PARAMETER Distro
    Distro name as shown by `wsl --list`. Default: Ubuntu (current Microsoft
    Store / wsl --install Ubuntu).

.PARAMETER BootstrapOnly
    Skip Windows feature / WSL install. Only copy and run the guest bootstrap.

.PARAMETER SkipBootstrap
    Only prepare the host and distro/user; do not run guest/bootstrap.sh.

.PARAMETER ForceRecreate
    Unregister the distro (DESTROYS all files in it) then reinstall. Requires
    typing the distro name, or pass -Force to skip that confirm.

.PARAMETER Force
    Skip the ForceRecreate confirmation prompt.

.PARAMETER NonInteractive
    Do not prompt. Username must be passed (or already saved from a prior run).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -Username teuzin

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -BootstrapOnly -Username teuzin
#>
[CmdletBinding()]
param(
    [string]$Username,
    [string]$Distro = 'Ubuntu',
    [switch]$BootstrapOnly,
    [switch]$SkipBootstrap,
    [switch]$ForceRecreate,
    [switch]$Force,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows convention: 3010 = success, reboot required to continue.
$script:RebootExitCode = 3010
$script:StateDir = Join-Path $env:LOCALAPPDATA 'wsl-dev-env'
$script:StatePath = Join-Path $script:StateDir 'state.json'
$script:GuestRel = 'guest\bootstrap.sh'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn2 { param([string]$Message) Write-Host "    WARN: $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "ERROR: $Message" -ForegroundColor Red }

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal $id
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WslExe {
    $p = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    $cmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# wsl --list emits UTF-16 LE. Reading it via PowerShell 5.1 pipelines often
# turns the names into space-separated letters. Decode stdout as Unicode.
function Invoke-WslUtf16 {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )
    $wsl = Get-WslExe
    if (-not $wsl) { throw 'wsl.exe not found under System32. Enable Windows features and reboot, then re-run.' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wsl
    $psi.Arguments = ($ArgumentList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut   = ($stdout -replace "`0", '').Trim()
        StdErr   = ($stderr -replace "`0", '').Trim()
    }
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,
        [switch]$IgnoreExitCode
    )
    $wsl = Get-WslExe
    if (-not $wsl) { throw 'wsl.exe not found under System32. Enable Windows features and reboot, then re-run.' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $wsl @ArgumentList 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if (-not $IgnoreExitCode -and $code -ne 0) {
        $text = ($output | Out-String).Trim()
        throw "wsl $($ArgumentList -join ' ') failed (exit $code): $text"
    }
    return $output
}

function Get-WslDistroNames {
    $wsl = Get-WslExe
    if (-not $wsl) { return @() }
    $r = Invoke-WslUtf16 -ArgumentList @('--list', '--quiet')
    if ($r.ExitCode -ne 0) { return @() }
    $names = @()
    foreach ($line in ($r.StdOut -split "`r?`n")) {
        $n = $line.Trim()
        if ($n) { $names += $n }
    }
    return $names
}

function Test-WslDistroPresent {
    param([string]$Name)
    $names = @(Get-WslDistroNames)
    foreach ($n in $names) {
        if ([string]::Equals($n, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-WslDistroHealthy {
    param([string]$Name)
    if (-not (Test-WslDistroPresent -Name $Name)) { return $false }
    try {
        Invoke-Wsl -ArgumentList @('-d', $Name, '-u', 'root', '--', 'true') | Out-Null
        return $true
    } catch {
        return $false
    }
}

# Pipe raw UTF-8 bytes into `wsl bash -c "cat > file"` so we do not depend on
# /mnt/c automount and we avoid PowerShell 5.1 UTF-16 stdin.
function Copy-TextIntoWsl {
    param(
        [string]$DistroName,
        [string]$Content,
        [string]$WslPath
    )
    $wsl = Get-WslExe
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wsl
    $quoted = $WslPath.Replace("'", "'\''")
    $psi.Arguments = "-d $DistroName -u root -- bash -c `"cat > '$quoted' && chmod 755 '$quoted'`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
        throw "Failed to copy file into WSL at $WslPath (exit $($p.ExitCode)): $stderr $stdout"
    }
}

function Read-SavedState {
    if (-not (Test-Path -LiteralPath $script:StatePath)) { return $null }
    try {
        return (Get-Content -LiteralPath $script:StatePath -Raw -ErrorAction Stop | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Save-State {
    param([string]$User, [string]$DistroName)
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir | Out-Null
    }
    $obj = @{ Username = $User; Distro = $DistroName; SavedAt = (Get-Date).ToString('o') }
    ($obj | ConvertTo-Json) | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Test-WindowsCapability {
    Write-Step 'Checking Windows / hardware capability for WSL2'

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        throw 'This script must run from Windows, not Linux/macOS. From Windows: powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1'
    }
    if ($env:WSL_DISTRO_NAME -or $env:WSL_INTEROP) {
        throw 'This looks like Windows PowerShell inside WSL. Run it from elevated Windows PowerShell instead.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'WSL2 requires 64-bit Windows.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw 'Use 64-bit PowerShell. 32-bit PowerShell cannot see System32\wsl.exe (WOW64 redirection).'
    }

    $nt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$nt.CurrentBuildNumber
    $display = $null
    foreach ($prop in @('DisplayVersion', 'ReleaseId')) {
        if ($nt.PSObject.Properties[$prop] -and $nt.$prop) { $display = [string]$nt.$prop; break }
    }
    $product = [string]$nt.ProductName
    Write-Ok "$product $display (build $build)"

    # 18362 = Win10 1903 (first WSL2). 19041 = 2004 (reliable wsl --install).
    if ($build -lt 18362) {
        throw @"
WSL2 needs Windows 10 version 1903 (build 18362) or later, or Windows 11.
This machine is build $build. Update Windows, then re-run.
"@
    }
    if ($build -lt 19041) {
        Write-Warn2 "Build $build can run WSL2 but Microsoft's current installer expects 2004+ (19041). Upgrade Windows if wsl --install is missing."
    }

    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $fwVirt = $null
    if ($cpu -and $cpu.PSObject.Properties['VirtualizationFirmwareEnabled']) {
        $fwVirt = $cpu.VirtualizationFirmwareEnabled
    }
    if ($null -ne $fwVirt) {
        if (-not $fwVirt) {
            throw @"
CPU virtualization is disabled in firmware.
Reboot into BIOS/UEFI and enable Intel VT-x / AMD-V / SVM, then re-run.
On some laptops this is named "Virtualization Technology" or "Hyper-V".
"@
        }
        Write-Ok 'Firmware virtualization is enabled'
    } else {
        Write-Warn2 'Could not read VirtualizationFirmwareEnabled; continuing'
    }

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $model = ('{0} {1}' -f $cs.Manufacturer, $cs.Model)
    $inVm = $model -match 'Virtual|VMware|Hyper-V|KVM|QEMU|Xen|VirtualBox|HVM|Bochs|Amazon|Google|QEMU'
    if ($inVm) {
        Write-Warn2 "This looks like a VM ($model)."
        Write-Warn2 'WSL2 needs nested virtualization enabled on the host hypervisor (Hyper-V: ExposeVirtualizationExtensions; VMware: "Virtualize Intel VT-x/AMD-V"; VirtualBox: nested VT-x).'
        if (-not $cs.HypervisorPresent) {
            Write-Warn2 'HypervisorPresent is false - nested virt is probably off. WSL2 will fail until the hypervisor exposes it.'
        } else {
            Write-Ok 'HypervisorPresent=true (nested virt may already be on)'
        }
    } elseif ($cs.HypervisorPresent) {
        Write-Ok 'Hypervisor is present'
    }

    return [pscustomobject]@{ Build = $build; Product = $product }
}

function Test-FeatureEnabled {
    param([string]$Name)
    $f = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
    return ($f.State -eq 'Enabled')
}

function Enable-FeatureIdempotent {
    param([string]$Name)
    if (Test-FeatureEnabled -Name $Name) {
        Write-Ok "Feature already enabled: $Name"
        return $false
    }
    Write-Step "Enabling Windows feature: $Name"
    $r = Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart
    return [bool]$r.RestartNeeded
}

function Test-WslHostReady {
    if (-not (Get-WslExe)) { return $false }
    try {
        $r = Invoke-WslUtf16 -ArgumentList @('--status')
        return ($r.ExitCode -eq 0)
    } catch {
        return $false
    }
}

function Enable-WslFeatures {
    Write-Step 'Enabling WSL + Virtual Machine Platform (idempotent)'
    if (-not (Test-IsAdministrator)) {
        if (Test-WslHostReady) {
            Write-Ok 'Not elevated; WSL already works, skipping feature enable'
            return $false
        }
        throw @"
Enabling Windows features requires an elevated 64-bit PowerShell.

  1. Start menu -> Windows PowerShell -> Run as administrator
  2. cd to this repo
  3. powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -Username <you>
"@
    }
    try {
        $bcd = (& bcdedit /enum '{current}' 2>$null | Out-String)
        if ($bcd -match 'hypervisorlaunchtype\s+Off') {
            Write-Warn2 'bcdedit hypervisorlaunchtype is Off. WSL2 needs it Auto (elevated: bcdedit /set hypervisorlaunchtype Auto) then reboot.'
        }
    } catch {
        # bcdedit is informational only
    }
    $needReboot = $false
    foreach ($feat in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
        if (Enable-FeatureIdempotent -Name $feat) { $needReboot = $true }
    }
    return $needReboot
}

function Install-WslHost {
    Write-Step 'Installing / updating WSL (prefer WSL2)'
    $wsl = Get-WslExe
    if (-not $wsl) {
        Write-Warn2 'wsl.exe still missing; a reboot after feature enable is required.'
        return $true
    }

    # Packaged WSL (kernel + wsl.exe) is distinct from the optional Windows features.
    try {
        Write-Step 'wsl --install --no-distribution (current WSL, no distro yet)'
        Invoke-Wsl -ArgumentList @('--install', '--no-distribution') -IgnoreExitCode | Out-Null
        Write-Ok 'wsl --install --no-distribution finished'
    } catch {
        Write-Warn2 "wsl --install --no-distribution skipped: $($_.Exception.Message)"
    }

    # --set-default-version 2 is the whole point of this script.
    try {
        Invoke-Wsl -ArgumentList @('--set-default-version', '2') -IgnoreExitCode | Out-Null
        Write-Ok 'Default WSL version set to 2'
    } catch {
        Write-Warn2 "Could not set default version 2: $($_.Exception.Message)"
    }

    try {
        Write-Step 'wsl --update (Microsoft WSL kernel / inbox package)'
        Invoke-Wsl -ArgumentList @('--update') -IgnoreExitCode | Out-Null
        Write-Ok 'wsl --update finished'
    } catch {
        Write-Warn2 "wsl --update skipped: $($_.Exception.Message)"
    }

    return $false
}

function Install-UbuntuDistro {
    param([string]$DistroName)

    if ($ForceRecreate -and (Test-WslDistroPresent -Name $DistroName)) {
        if (-not $Force) {
            Write-Warn2 "This DELETES distro '$DistroName' and every file inside it."
            if ($NonInteractive) {
                throw 'Refusing -ForceRecreate in -NonInteractive without -Force.'
            }
            $ans = Read-Host "Type the distro name '$DistroName' to confirm destruction"
            if ($ans -ne $DistroName) { throw 'Aborted. Distro was not changed.' }
        }
        Write-Step "Unregistering $DistroName (-ForceRecreate)"
        Invoke-Wsl -ArgumentList @('--terminate', $DistroName) -IgnoreExitCode | Out-Null
        Invoke-Wsl -ArgumentList @('--unregister', $DistroName) | Out-Null
        Write-Ok "unregistered $DistroName"
    }

    if (Test-WslDistroHealthy -Name $DistroName) {
        Write-Ok "Healthy distro '$DistroName' already present; will not reinstall"
        return
    }
    if (Test-WslDistroPresent -Name $DistroName) {
        throw @"
Distro '$DistroName' is registered but not healthy (wsl -d $DistroName -u root -- true failed).
Fix it by hand, or re-run with -ForceRecreate (DESTROYS all data in that distro).
"@
    }

    Write-Step "Installing distro $DistroName"
    # --no-launch skips the interactive UNIX user OOBE so we can create the
    # named account ourselves. Older wsl.exe may not support the flag.
    $installed = $false
    foreach ($args in @(
            @('--install', '-d', $DistroName, '--no-launch'),
            @('--install', '-d', $DistroName)
        )) {
        Write-Ok ("trying: wsl " + ($args -join ' '))
        try {
            Invoke-Wsl -ArgumentList $args | Out-Null
            $installed = $true
            break
        } catch {
            Write-Warn2 $_.Exception.Message
        }
    }
    if (-not $installed) {
        throw @"
Could not install distro '$DistroName'.
Install Ubuntu from an elevated prompt:

  wsl --install -d $DistroName

Then re-run this script. If wsl --install is unknown, update Windows (2004+/Win11).
"@
    }

    # First boot can take a while (rootfs extract). Retry health until it answers.
    $deadline = (Get-Date).AddMinutes(5)
    do {
        if (Test-WslDistroHealthy -Name $DistroName) { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    if (-not (Test-WslDistroHealthy -Name $DistroName)) {
        throw "Distro '$DistroName' installed but did not become healthy within 5 minutes. Try: wsl -d $DistroName"
    }
    Write-Ok "$DistroName is healthy"
    Invoke-Wsl -ArgumentList @('--set-default', $DistroName) -IgnoreExitCode | Out-Null
}

function Test-ValidLinuxUsername {
    param([string]$Name)
    return [bool]($Name -match '^[a-z_][a-z0-9_-]{0,31}$')
}

function Get-SuggestedUsername {
    $raw = [string]$env:USERNAME
    $s = $raw.ToLowerInvariant() -replace '[^a-z0-9_-]', ''
    if ($s -match '^[0-9]') { $s = 'u' + $s }
    if ($s.Length -gt 32) { $s = $s.Substring(0, 32) }
    if (Test-ValidLinuxUsername $s) { return $s }
    return 'dev'
}

function Resolve-LinuxUsername {
    param([string]$DistroName)

    if ($Username) {
        $u = $Username.Trim().ToLowerInvariant()
        if (-not (Test-ValidLinuxUsername $u)) {
            throw "Invalid Linux username '$Username'. Use lowercase letters, digits, _ or -, starting with a letter or _."
        }
        return $u
    }

    $saved = Read-SavedState
    if ($saved -and $saved.PSObject.Properties['Username'] -and $saved.Username) {
        Write-Ok "Using username saved from previous run: $($saved.Username)"
        return [string]$saved.Username
    }

    $existing = $null
    if (Test-WslDistroHealthy -Name $DistroName) {
        try {
            $out = Invoke-Wsl -ArgumentList @(
                '-d', $DistroName, '-u', 'root', '--',
                'bash', '-c',
                "getent passwd | awk -F: '`$3>=1000 && `$3<65534 {print `$1; exit}'"
            )
            $existing = (($out | Out-String) -replace "`0", '').Trim()
            if ($existing -and -not (Test-ValidLinuxUsername $existing)) { $existing = $null }
        } catch {
            $existing = $null
        }
    }

    $suggestion = if ($existing) { $existing } else { Get-SuggestedUsername }

    if ($NonInteractive) {
        throw "NonInteractive run requires -Username (suggestion would have been '$suggestion')."
    }

    $entered = Read-Host "Linux username [$suggestion]"
    if ([string]::IsNullOrWhiteSpace($entered)) { $entered = $suggestion }
    $entered = $entered.Trim().ToLowerInvariant()
    if (-not (Test-ValidLinuxUsername $entered)) {
        throw "Invalid Linux username '$entered'."
    }
    return $entered
}

function Invoke-GuestBootstrap {
    param(
        [string]$DistroName,
        [string]$LinuxUser
    )
    $guestWin = Join-Path $PSScriptRoot $script:GuestRel
    if (-not (Test-Path -LiteralPath $guestWin)) {
        throw "Missing guest bootstrap at $guestWin"
    }
    Write-Step 'Copying guest/bootstrap.sh into the distro'
    $text = [System.IO.File]::ReadAllText($guestWin) -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    Copy-TextIntoWsl -DistroName $DistroName -Content $text -WslPath '/tmp/wsl-dev-env-bootstrap.sh'

    Write-Step "Running guest bootstrap as root then $LinuxUser (non-interactive)"
    Invoke-Wsl -ArgumentList @(
        '-d', $DistroName, '-u', 'root', '--',
        'bash', '/tmp/wsl-dev-env-bootstrap.sh', '--user', $LinuxUser
    )
    Write-Ok 'Guest bootstrap finished'
    Invoke-Wsl -ArgumentList @('--terminate', $DistroName) -IgnoreExitCode | Out-Null
    Write-Ok "Terminated $DistroName so /etc/wsl.conf default user applies on next start"
}

function Show-NextSteps {
    param([string]$DistroName, [string]$LinuxUser)
    Write-Host ''
    Write-Host 'Done. Open a WSL shell:' -ForegroundColor Green
    Write-Host "  wsl -d $DistroName -u $LinuxUser" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Optional:'
    Write-Host '  passwd                  # set a Linux password'
    Write-Host '  Windows Terminal        # starship icons look better with a Nerd Font, not required'
    Write-Host 'Re-run anytime (idempotent, will not delete the distro):'
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -Username $LinuxUser"
}

# --- main ---
if ($BootstrapOnly -and $SkipBootstrap) {
    throw '-BootstrapOnly and -SkipBootstrap cannot be combined.'
}

$linuxUser = $null

try {
    Test-WindowsCapability | Out-Null
    if ($Username) {
        $normalized = $Username.Trim().ToLowerInvariant()
        if (-not (Test-ValidLinuxUsername $normalized)) {
            throw "Invalid Linux username '$Username'. Use lowercase letters, digits, _ or -, starting with a letter or _."
        }
        $Username = $normalized
    }

    if (-not $BootstrapOnly) {
        $reboot = Enable-WslFeatures
        # Persist username before a possible reboot so the next run can skip the prompt.
        if ($Username) { Save-State -User $Username -DistroName $Distro }
        if ($reboot) {
            Write-Host ''
            Write-Warn2 'Windows features were enabled and a reboot is required before WSL2 works.'
            Write-Host 'Reboot, then re-run the same command (the script is idempotent):' -ForegroundColor Yellow
            $hintUser = if ($Username) { " -Username $Username" } else { '' }
            Write-Host "  powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1$hintUser" -ForegroundColor Yellow
            exit $script:RebootExitCode
        }
        $stillNeedReboot = Install-WslHost
        if ($stillNeedReboot) {
            Write-Warn2 'wsl.exe is not available yet. Reboot, then re-run this script.'
            exit $script:RebootExitCode
        }
        $linuxUser = Resolve-LinuxUsername -DistroName $Distro
        Save-State -User $linuxUser -DistroName $Distro
        Install-UbuntuDistro -DistroName $Distro
    } else {
        if (-not (Get-WslExe)) { throw 'wsl.exe not found. Run without -BootstrapOnly first.' }
        $linuxUser = Resolve-LinuxUsername -DistroName $Distro
        if (-not (Test-WslDistroHealthy -Name $Distro)) {
            throw "Distro '$Distro' is missing or unhealthy. Re-run without -BootstrapOnly."
        }
    }

    if (-not $linuxUser) {
        $linuxUser = Resolve-LinuxUsername -DistroName $Distro
    }
    Save-State -User $linuxUser -DistroName $Distro

    if (-not $SkipBootstrap) {
        Invoke-GuestBootstrap -DistroName $Distro -LinuxUser $linuxUser
    } else {
        Write-Ok 'SkipBootstrap set; guest tools were not installed'
    }

    Show-NextSteps -DistroName $Distro -LinuxUser $linuxUser
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
