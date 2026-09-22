#Requires -Version 5.1
<#
.SYNOPSIS
    Habilita WSL2, instala Ubuntu se preciso e faz bootstrap guiado (pt-BR) do ambiente de desenvolvimento.

.DESCRIPTION
    Entrada Windows para um Ubuntu WSL2 enxuto, inspirado no Omarchy, com menu interativo.

    Verifica se a máquina realmente roda WSL2, habilita os recursos do Windows de forma
    idempotente, instala ou atualiza WSL + Ubuntu sem destruir um distro saudável,
    cria/configura um usuário Linux COM senha informada na instalação, e executa
    guest/bootstrap.sh com os recursos escolhidos.

    Reinício: habilitar recursos costuma exigir um reboot. O script grava o usuário e
    as escolhas e sai com 3010. Rode o mesmo comando depois do reboot.

    Execute no Windows PowerShell 64-bit elevado, não de dentro do WSL.

.PARAMETER Username
    Conta Linux a criar ou reutilizar. Se omitido, o script pergunta (oferece o
    usuário do Windows, nunca um nome aleatório).

.PARAMETER Distro
    Nome do distro como em `wsl --list`. Padrão: Ubuntu.

.PARAMETER BootstrapOnly
    Pula recursos do Windows / instalação do WSL. Só copia e roda o bootstrap do guest.

.PARAMETER SkipBootstrap
    Só prepara host e distro/usuário; não roda guest/bootstrap.sh.

.PARAMETER ForceRecreate
    Desregistra o distro (APAGA todos os arquivos) e reinstala. Pede para digitar
    o nome do distro, ou passe -Force para pular a confirmação.

.PARAMETER Force
    Pula a confirmação de -ForceRecreate.

.PARAMETER NonInteractive
    Não pergunta. Username precisa ser passado (ou já estar salvo). Recursos só
    entram pelos switches. Conta nova exige -Password.

.PARAMETER Password
    SecureString da senha do usuário Linux (contas novas). Em modo interativo o
    script pede com entrada oculta.

.PARAMETER SkipBaseDx
    Não instala o DX base (python/node/rust/starship/zoxide/fzf). Padrão: DX base ligado.

.PARAMETER InstallDocker
    Instala Docker Engine no Ubuntu (get.docker.com). Caminho principal documentado.

.PARAMETER InstallGh
    Instala GitHub CLI (gh) no guest via repositório apt oficial.

.PARAMETER InstallHerdr
    Instala Herdr (oficial) no guest e, se possível, no Windows, e grava atalhos Omarchy.

.PARAMETER Agents
    CLIs de agentes a instalar (só os escolhidos): claude, codex, opencode, pi, grok, kimi, cursor.

.PARAMETER SetupGitHubSsh
    Guia de chave SSH ed25519 para o GitHub (e instala gh se ainda não estiver).

.PARAMETER PasswordlessSudo
    sudo sem senha. Só use se o usuário pediu explicitamente. Padrão: sudo COM senha.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -NonInteractive -Username teuzin -Password $pwd -InstallDocker -InstallGh -InstallHerdr -Agents claude,pi
#>
[CmdletBinding()]
param(
    [string]$Username,
    [string]$Distro = 'Ubuntu',
    [switch]$BootstrapOnly,
    [switch]$SkipBootstrap,
    [switch]$ForceRecreate,
    [switch]$Force,
    [switch]$NonInteractive,
    [Security.SecureString]$Password,
    [switch]$SkipBaseDx,
    [switch]$InstallDocker,
    [switch]$InstallGh,
    [switch]$InstallHerdr,
    [string[]]$Agents,
    [switch]$SetupGitHubSsh,
    [switch]$PasswordlessSudo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Convenção Windows: 3010 = sucesso, precisa reiniciar para continuar.
$script:RebootExitCode = 3010
$script:StateDir = Join-Path $env:LOCALAPPDATA 'wsl-dev-env'
$script:StatePath = Join-Path $script:StateDir 'state.json'
$script:GuestRel = 'guest\bootstrap.sh'
$script:HerdrKeysRel = 'guest\herdr-omarchy-keys.toml'
$script:KnownAgents = @('claude', 'codex', 'opencode', 'pi', 'grok', 'kimi', 'cursor')
$script:Plan = $null

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn2 { param([string]$Message) Write-Host "    AVISO: $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "ERRO: $Message" -ForegroundColor Red }

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

# wsl --list emite UTF-16 LE. Ler via pipeline do PowerShell 5.1 costuma
# transformar os nomes em letras espaçadas. Decodifica stdout como Unicode.
function Invoke-WslUtf16 {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )
    $wsl = Get-WslExe
    if (-not $wsl) { throw 'wsl.exe não encontrado em System32. Habilite os recursos do Windows, reinicie e rode de novo.' }
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
    if (-not $wsl) { throw 'wsl.exe não encontrado em System32. Habilite os recursos do Windows, reinicie e rode de novo.' }
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
        throw "wsl $($ArgumentList -join ' ') falhou (saída $code): $text"
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

# Envia bytes UTF-8 crus para `wsl bash -c "cat > arquivo"`: não depende de
# /mnt/c e evita stdin UTF-16 do PowerShell 5.1.
function Copy-TextIntoWsl {
    param(
        [string]$DistroName,
        [string]$Content,
        [string]$WslPath,
        [string]$Mode = '644'
    )
    if ($Mode -notmatch '^[0-7]{3,4}$') {
        throw "Modo chmod inválido: $Mode"
    }
    $wsl = Get-WslExe
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wsl
    $quoted = $WslPath.Replace("'", "'\''")
    $psi.Arguments = "-d $DistroName -u root -- bash -c `"cat > '$quoted' && chmod $Mode '$quoted'`""
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
        throw "Falha ao copiar arquivo para o WSL em $WslPath (saída $($p.ExitCode)): $stderr $stdout"
    }
}

function Get-StringArray {
    param($Value)
    $out = @()
    if ($null -eq $Value) { return ,@($out) }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return ,@($out) }
        foreach ($piece in ($Value -split ',')) {
            $t = $piece.Trim().ToLowerInvariant()
            if ($t) { $out += $t }
        }
        return ,@($out)
    }
    foreach ($v in @($Value)) {
        if ($null -eq $v) { continue }
        foreach ($piece in ("$v" -split ',')) {
            $t = $piece.Trim().ToLowerInvariant()
            if ($t) { $out += $t }
        }
    }
    return ,@($out)
}

function Normalize-AgentList {
    param($Value)
    $out = @()
    foreach ($a in @(Get-StringArray -Value $Value)) {
        if ($a -eq 'cursor-agent') { $a = 'cursor' }
        if ($script:KnownAgents -contains $a) {
            if ($out -notcontains $a) { $out += $a }
        } else {
            Write-Warn2 "Agente desconhecido ignorado: $a (use: $($script:KnownAgents -join ', '))"
        }
    }
    return ,@($out)
}

function ConvertFrom-SecureStringPlain {
    param([Security.SecureString]$Secure)
    if ($null -eq $Secure) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Test-SameSecureString {
    param(
        [Security.SecureString]$A,
        [Security.SecureString]$B
    )
    $pa = ConvertFrom-SecureStringPlain -Secure $A
    $pb = ConvertFrom-SecureStringPlain -Secure $B
    try {
        if ([string]::IsNullOrEmpty($pa) -or [string]::IsNullOrEmpty($pb)) { return $false }
        return ($pa -ceq $pb)
    } finally {
        $pa = $null
        $pb = $null
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

function New-InstallPlan {
    param(
        [bool]$BaseDx = $true,
        [bool]$Docker = $false,
        [bool]$Gh = $false,
        [bool]$Herdr = $false,
        [string[]]$AgentList = @(),
        [bool]$GitHubSsh = $false,
        [bool]$PasswordlessSudoOpt = $false
    )
    return [pscustomobject]@{
        BaseDx            = [bool]$BaseDx
        Docker            = [bool]$Docker
        Gh                = [bool]$Gh
        Herdr             = [bool]$Herdr
        Agents            = @(Normalize-AgentList -Value $AgentList)
        GitHubSsh         = [bool]$GitHubSsh
        PasswordlessSudo  = [bool]$PasswordlessSudoOpt
    }
}

function Save-State {
    param(
        [string]$User,
        [string]$DistroName,
        $Plan
    )
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir | Out-Null
    }
    if (-not $Plan) { $Plan = $script:Plan }
    $agentList = @()
    if ($Plan -and $Plan.PSObject.Properties['Agents'] -and $Plan.Agents) {
        $agentList = @($Plan.Agents)
    }
    $obj = @{
        Username         = $User
        Distro           = $DistroName
        SavedAt          = (Get-Date).ToString('o')
        BaseDx           = [bool]$(if ($Plan) { $Plan.BaseDx } else { $true })
        Docker           = [bool]$(if ($Plan) { $Plan.Docker } else { $false })
        Gh               = [bool]$(if ($Plan) { $Plan.Gh } else { $false })
        Herdr            = [bool]$(if ($Plan) { $Plan.Herdr } else { $false })
        Agents           = @($agentList)
        GitHubSsh        = [bool]$(if ($Plan) { $Plan.GitHubSsh } else { $false })
        PasswordlessSudo = [bool]$(if ($Plan) { $Plan.PasswordlessSudo } else { $false })
    }
    ($obj | ConvertTo-Json) | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Get-PlanFromState {
    param($Saved)
    if (-not $Saved) { return $null }
    $hasFeat = $false
    foreach ($n in @('BaseDx', 'Docker', 'Gh', 'Herdr', 'GitHubSsh', 'PasswordlessSudo', 'Agents')) {
        if ($Saved.PSObject.Properties[$n]) { $hasFeat = $true; break }
    }
    if (-not $hasFeat) { return $null }
    $base = $true
    if ($Saved.PSObject.Properties['BaseDx'] -and $null -ne $Saved.BaseDx) { $base = [bool]$Saved.BaseDx }
    return (New-InstallPlan `
            -BaseDx $base `
            -Docker ([bool]$(if ($Saved.PSObject.Properties['Docker']) { $Saved.Docker } else { $false })) `
            -Gh ([bool]$(if ($Saved.PSObject.Properties['Gh']) { $Saved.Gh } else { $false })) `
            -Herdr ([bool]$(if ($Saved.PSObject.Properties['Herdr']) { $Saved.Herdr } else { $false })) `
            -AgentList @(Get-StringArray -Value $(if ($Saved.PSObject.Properties['Agents']) { $Saved.Agents } else { @() })) `
            -GitHubSsh ([bool]$(if ($Saved.PSObject.Properties['GitHubSsh']) { $Saved.GitHubSsh } else { $false })) `
            -PasswordlessSudoOpt ([bool]$(if ($Saved.PSObject.Properties['PasswordlessSudo']) { $Saved.PasswordlessSudo } else { $false })))
}

function Test-WindowsCapability {
    Write-Step 'Verificando se este Windows consegue rodar WSL2'

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        throw 'Este script precisa rodar no Windows, não no Linux/macOS. No Windows: powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1'
    }
    if ($env:WSL_DISTRO_NAME -or $env:WSL_INTEROP) {
        throw 'Isto parece PowerShell dentro do WSL. Rode no Windows PowerShell elevado.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'WSL2 exige Windows 64-bit.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw 'Use PowerShell 64-bit. O PowerShell 32-bit não enxerga System32\wsl.exe (redirecionamento WOW64).'
    }

    $nt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$nt.CurrentBuildNumber
    $display = $null
    foreach ($prop in @('DisplayVersion', 'ReleaseId')) {
        if ($nt.PSObject.Properties[$prop] -and $nt.$prop) { $display = [string]$nt.$prop; break }
    }
    $product = [string]$nt.ProductName
    Write-Ok "$product $display (build $build)"

    # 18362 = Win10 1903 (primeiro WSL2). 19041 = 2004 (wsl --install confiável).
    if ($build -lt 18362) {
        throw @"
WSL2 precisa do Windows 10 versão 1903 (build 18362) ou posterior, ou Windows 11.
Esta máquina está no build $build. Atualize o Windows e rode de novo.
"@
    }
    if ($build -lt 19041) {
        Write-Warn2 "Build $build consegue WSL2, mas o instalador atual da Microsoft espera 2004+ (19041). Atualize o Windows se wsl --install não existir."
    }

    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $fwVirt = $null
    if ($cpu -and $cpu.PSObject.Properties['VirtualizationFirmwareEnabled']) {
        $fwVirt = $cpu.VirtualizationFirmwareEnabled
    }
    if ($null -ne $fwVirt) {
        if (-not $fwVirt) {
            throw @"
A virtualização da CPU está desligada no firmware (BIOS/UEFI).

Reinicie na BIOS/UEFI e ligue Intel VT-x / AMD-V / SVM.
Alguns menus de BIOS rotulam este ajuste de firmware como "Virtualization Technology" ou "Hyper-V" — é uma configuração de CPU/firmware, não o recurso Windows Hyper-V.

Depois rode o script de novo.
"@
        }
        Write-Ok 'Virtualização no firmware está ligada'
    } else {
        Write-Warn2 'Não foi possível ler VirtualizationFirmwareEnabled; seguindo'
    }

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $model = ('{0} {1}' -f $cs.Manufacturer, $cs.Model)
    $inVm = $model -match 'Virtual|VMware|Hyper-V|KVM|QEMU|Xen|VirtualBox|HVM|Bochs|Amazon|Google|QEMU'
    if ($inVm) {
        Write-Warn2 "Isto parece uma VM ($model)."
        Write-Warn2 'WSL2 precisa de virtualização aninhada no hipervisor (Hyper-V: ExposeVirtualizationExtensions; VMware: "Virtualize Intel VT-x/AMD-V"; VirtualBox: nested VT-x).'
        if (-not $cs.HypervisorPresent) {
            Write-Warn2 'HypervisorPresent é falso — nested virt provavelmente está desligado. WSL2 vai falhar até o hipervisor expor isso.'
        } else {
            Write-Ok 'HypervisorPresent=true (nested virt pode já estar ligado)'
        }
    } elseif ($cs.HypervisorPresent) {
        Write-Ok 'Hipervisor presente'
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
        Write-Ok "Recurso já habilitado: $Name"
        return $false
    }
    Write-Step "Habilitando recurso do Windows: $Name"
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
    Write-Step 'Habilitando WSL + Virtual Machine Platform (idempotente)'
    if (-not (Test-IsAdministrator)) {
        if (Test-WslHostReady) {
            Write-Ok 'Sem elevação; WSL já funciona, pulando habilitação de recursos'
            return $false
        }
        throw @"
Habilitar recursos do Windows exige PowerShell 64-bit elevado.

  1. Menu Iniciar -> Windows PowerShell -> Executar como administrador
  2. cd até este repositório
  3. powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1
"@
    }
    try {
        $bcd = (& bcdedit /enum '{current}' 2>$null | Out-String)
        if ($bcd -match 'hypervisorlaunchtype\s+Off') {
            Write-Warn2 'bcdedit hypervisorlaunchtype está Off. WSL2 precisa de Auto (elevado: bcdedit /set hypervisorlaunchtype Auto) e depois reboot.'
        }
    } catch {
        # bcdedit é só informativo
    }
    $needReboot = $false
    foreach ($feat in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
        if (Enable-FeatureIdempotent -Name $feat) { $needReboot = $true }
    }
    return $needReboot
}

function Install-WslHost {
    Write-Step 'Instalando / atualizando WSL (preferir WSL2)'
    $wsl = Get-WslExe
    if (-not $wsl) {
        Write-Warn2 'wsl.exe ainda ausente; é preciso reiniciar depois de habilitar os recursos.'
        return $true
    }

    try {
        Write-Step 'wsl --install --no-distribution (WSL atual, ainda sem distro)'
        Invoke-Wsl -ArgumentList @('--install', '--no-distribution') -IgnoreExitCode | Out-Null
        Write-Ok 'wsl --install --no-distribution terminou'
    } catch {
        Write-Warn2 "wsl --install --no-distribution pulado: $($_.Exception.Message)"
    }

    try {
        Invoke-Wsl -ArgumentList @('--set-default-version', '2') -IgnoreExitCode | Out-Null
        Write-Ok 'Versão padrão do WSL definida para 2'
    } catch {
        Write-Warn2 "Não foi possível definir versão padrão 2: $($_.Exception.Message)"
    }

    try {
        Write-Step 'wsl --update (kernel / pacote WSL da Microsoft)'
        Invoke-Wsl -ArgumentList @('--update') -IgnoreExitCode | Out-Null
        Write-Ok 'wsl --update terminou'
    } catch {
        Write-Warn2 "wsl --update pulado: $($_.Exception.Message)"
    }

    return $false
}

function Install-UbuntuDistro {
    param([string]$DistroName)

    if ($ForceRecreate -and (Test-WslDistroPresent -Name $DistroName)) {
        if (-not $Force) {
            Write-Warn2 "Isto APAGA o distro '$DistroName' e todo arquivo dentro dele."
            if ($NonInteractive) {
                throw 'Recusando -ForceRecreate em -NonInteractive sem -Force.'
            }
            $ans = Read-Host "Digite o nome do distro '$DistroName' para confirmar a destruição"
            if ($ans -ne $DistroName) { throw 'Abortado. O distro não foi alterado.' }
        }
        Write-Step "Removendo registro de $DistroName (-ForceRecreate)"
        Invoke-Wsl -ArgumentList @('--terminate', $DistroName) -IgnoreExitCode | Out-Null
        Invoke-Wsl -ArgumentList @('--unregister', $DistroName) | Out-Null
        Write-Ok "registro de $DistroName removido"
    }

    if (Test-WslDistroHealthy -Name $DistroName) {
        Write-Ok "Distro saudável '$DistroName' já existe; não vamos reinstalar"
        return
    }
    if (Test-WslDistroPresent -Name $DistroName) {
        throw @"
O distro '$DistroName' está registrado, mas não saudável (wsl -d $DistroName -u root -- true falhou).
Conserte na mão, ou rode de novo com -ForceRecreate (APAGA todos os dados desse distro).
"@
    }

    Write-Step "Instalando distro $DistroName"
    # --no-launch pula o OOBE interativo de usuário UNIX para criarmos a conta.
    $installed = $false
    foreach ($args in @(
            @('--install', '-d', $DistroName, '--no-launch'),
            @('--install', '-d', $DistroName)
        )) {
        Write-Ok ("tentando: wsl " + ($args -join ' '))
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
Não foi possível instalar o distro '$DistroName'.
Instale o Ubuntu num prompt elevado:

  wsl --install -d $DistroName

Depois rode este script de novo. Se wsl --install for desconhecido, atualize o Windows (2004+/Win11).
"@
    }

    $deadline = (Get-Date).AddMinutes(5)
    do {
        if (Test-WslDistroHealthy -Name $DistroName) { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    if (-not (Test-WslDistroHealthy -Name $DistroName)) {
        throw "O distro '$DistroName' instalou mas não ficou saudável em 5 minutos. Tente: wsl -d $DistroName"
    }
    Write-Ok "$DistroName está saudável"
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

function Test-LinuxUserExists {
    param([string]$DistroName, [string]$LinuxUser)
    if (-not (Test-WslDistroHealthy -Name $DistroName)) { return $false }
    try {
        Invoke-Wsl -ArgumentList @(
            '-d', $DistroName, '-u', 'root', '--',
            'getent', 'passwd', $LinuxUser
        ) | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Resolve-LinuxUsername {
    param([string]$DistroName)

    if ($Username) {
        $u = $Username.Trim().ToLowerInvariant()
        if (-not (Test-ValidLinuxUsername $u)) {
            throw "Nome de usuário Linux inválido '$Username'. Use letras minúsculas, dígitos, _ ou -, começando com letra ou _."
        }
        return $u
    }

    $saved = Read-SavedState
    if ($saved -and $saved.PSObject.Properties['Username'] -and $saved.Username) {
        Write-Ok "Usando usuário salvo da execução anterior: $($saved.Username)"
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
        throw "Execução NonInteractive exige -Username (a sugestão teria sido '$suggestion')."
    }

    $entered = Read-Host "Nome de usuário Linux [$suggestion]"
    if ([string]::IsNullOrWhiteSpace($entered)) { $entered = $suggestion }
    $entered = $entered.Trim().ToLowerInvariant()
    if (-not (Test-ValidLinuxUsername $entered)) {
        throw "Nome de usuário Linux inválido '$entered'."
    }
    return $entered
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $false
    )
    $hint = if ($Default) { 'S/n' } else { 's/N' }
    $ans = Read-Host "$Prompt [$hint]"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    return [bool]($ans -match '^[sSyY]')
}

function Read-LinuxPassword {
    Write-Host ''
    Write-Host 'A conta Linux precisa de senha (não criamos senha vazia nem sudo sem senha por padrão).' -ForegroundColor Yellow
    Write-Host 'A senha não é gravada no Windows. Se o PC reiniciar no meio, você informa de novo.' -ForegroundColor Yellow
    while ($true) {
        $p1 = Read-Host 'Senha do usuário Linux (digitação oculta)' -AsSecureString
        $p2 = Read-Host 'Confirme a senha' -AsSecureString
        $plain = ConvertFrom-SecureStringPlain -Secure $p1
        if ([string]::IsNullOrEmpty($plain)) {
            Write-Warn2 'Senha vazia não é permitida.'
            continue
        }
        if ($plain -match "[\r\n]") {
            Write-Warn2 'A senha não pode conter quebra de linha.'
            continue
        }
        if (-not (Test-SameSecureString -A $p1 -B $p2)) {
            Write-Warn2 'As senhas não coincidem. Tente de novo.'
            continue
        }
        return $p1
    }
}

function Show-Plan {
    param($Plan)
    $mark = {
        param([bool]$On)
        if ($On) { '[X]' } else { '[ ]' }
    }
    Write-Host ''
    Write-Host 'Plano de instalação:' -ForegroundColor Cyan
    Write-Host ("  {0} DX base (python / node via fnm / rust / starship / zoxide / fzf)" -f (& $mark $Plan.BaseDx))
    Write-Host ("  {0} Docker Engine no Ubuntu (WSL2)" -f (& $mark $Plan.Docker))
    Write-Host ("  {0} GitHub CLI (gh)" -f (& $mark $Plan.Gh))
    Write-Host ("  {0} Herdr + atalhos Omarchy (prefixo ctrl+espaço)" -f (& $mark $Plan.Herdr))
    $agentText = if ($Plan.Agents -and @($Plan.Agents).Count -gt 0) { @($Plan.Agents) -join ', ' } else { 'nenhum' }
    Write-Host ("  {0} CLIs de agentes: {1}" -f (& $mark (@($Plan.Agents).Count -gt 0)), $agentText)
    Write-Host ("  {0} Guia GitHub + chave SSH" -f (& $mark $Plan.GitHubSsh))
    Write-Host ("  {0} sudo sem senha (opt-in)" -f (& $mark $Plan.PasswordlessSudo))
}

function Read-AgentMenu {
    param([string[]]$Current)
    $selected = @{}
    foreach ($a in $script:KnownAgents) { $selected[$a] = $false }
    foreach ($a in @($Current)) { if ($selected.ContainsKey($a)) { $selected[$a] = $true } }

    $labels = @{
        claude   = 'Claude Code (Anthropic)'
        codex    = 'Codex CLI (OpenAI)'
        opencode = 'OpenCode'
        pi       = 'Pi coding agent (pi.dev)'
        grok     = 'Grok CLI (xAI)'
        kimi     = 'Kimi Code CLI (Moonshot)'
        cursor   = 'Cursor Agent'
    }

    Write-Host ''
    Write-Host 'Quais CLIs de agentes instalar? (só os escolhidos; firstmate não entra aqui)' -ForegroundColor Cyan
    Write-Host 'Digite o número para ligar/desligar, A para todos, N para nenhum, Enter para seguir.'
    while ($true) {
        Write-Host ''
        for ($i = 0; $i -lt $script:KnownAgents.Count; $i++) {
            $id = $script:KnownAgents[$i]
            $box = if ($selected[$id]) { '[X]' } else { '[ ]' }
            Write-Host ("  {0} {1}. {2,-9} — {3}" -f $box, ($i + 1), $id, $labels[$id])
        }
        $choice = Read-Host 'Agentes'
        if ([string]::IsNullOrWhiteSpace($choice)) { break }
        $c = $choice.Trim()
        if ($c -match '^[aA]$') {
            foreach ($a in $script:KnownAgents) { $selected[$a] = $true }
            continue
        }
        if ($c -match '^[nN]$') {
            foreach ($a in $script:KnownAgents) { $selected[$a] = $false }
            continue
        }
        foreach ($piece in ($c -split '[,\s]+')) {
            if ($piece -match '^\d+$') {
                $n = [int]$piece
                if ($n -ge 1 -and $n -le $script:KnownAgents.Count) {
                    $id = $script:KnownAgents[$n - 1]
                    $selected[$id] = -not $selected[$id]
                }
            }
        }
    }
    $out = @()
    foreach ($a in $script:KnownAgents) {
        if ($selected[$a]) { $out += $a }
    }
    return ,@($out)
}

function Read-FeaturePlan {
    param($Initial)

    $plan = if ($Initial) {
        New-InstallPlan -BaseDx $Initial.BaseDx -Docker $Initial.Docker -Gh $Initial.Gh -Herdr $Initial.Herdr -AgentList @($Initial.Agents) -GitHubSsh $Initial.GitHubSsh -PasswordlessSudoOpt $Initial.PasswordlessSudo
    } else {
        New-InstallPlan
    }

    Write-Host ''
    Write-Host 'Instalação guiada (português do Brasil)' -ForegroundColor Cyan
    Write-Host 'Padrão enxuto: DX base ligado; o resto você escolhe.'
    Write-Host 'Digite o número para ligar/desligar, Enter para seguir.'

    while ($true) {
        $agentBox = if (@($plan.Agents).Count -gt 0) { '[X]' } else { '[ ]' }
        $agentSummary = if (@($plan.Agents).Count -gt 0) { @($plan.Agents) -join ', ' } else { 'nenhum ainda' }
        Write-Host ''
        Write-Host ("  {0} 1. DX base — Python, Node (fnm), Rust, starship, zoxide, fzf  (recomendado)" -f $(if ($plan.BaseDx) { '[X]' } else { '[ ]' }))
        Write-Host ("  {0} 2. Docker Engine no Ubuntu (WSL2, get.docker.com)" -f $(if ($plan.Docker) { '[X]' } else { '[ ]' }))
        Write-Host ("  {0} 3. GitHub CLI (gh)" -f $(if ($plan.Gh) { '[X]' } else { '[ ]' }))
        Write-Host ("  {0} 4. Herdr + atalhos estilo Omarchy (prefixo ctrl+espaço)" -f $(if ($plan.Herdr) { '[X]' } else { '[ ]' }))
        Write-Host ("  {0} 5. CLIs de agentes ({1})" -f $agentBox, $agentSummary)
        Write-Host ("  {0} 6. Conta GitHub + guia de chave SSH" -f $(if ($plan.GitHubSsh) { '[X]' } else { '[ ]' }))
        Write-Host ("  {0} 7. sudo sem senha (não recomendado; padrão é sudo COM senha)" -f $(if ($plan.PasswordlessSudo) { '[X]' } else { '[ ]' }))
        $choice = Read-Host 'Recurso'
        if ([string]::IsNullOrWhiteSpace($choice)) { break }
        switch ($choice.Trim()) {
            '1' { $plan.BaseDx = -not $plan.BaseDx }
            '2' { $plan.Docker = -not $plan.Docker }
            '3' { $plan.Gh = -not $plan.Gh }
            '4' { $plan.Herdr = -not $plan.Herdr }
            '5' {
                $plan.Agents = @(Read-AgentMenu -Current @($plan.Agents))
            }
            '6' { $plan.GitHubSsh = -not $plan.GitHubSsh }
            '7' { $plan.PasswordlessSudo = -not $plan.PasswordlessSudo }
            default { Write-Warn2 'Escolha 1-7 ou Enter para continuar.' }
        }
    }

    if (-not $plan.GitHubSsh) {
        if (Read-YesNo -Prompt 'Você usa GitHub?' -Default $false) {
            $plan.GitHubSsh = $true
            Write-Ok 'Vamos guiar a chave SSH no final. gh será instalado se ainda não estiver.'
        }
    }

    if ($plan.GitHubSsh) {
        $plan.Gh = $true
    }

    if (@($plan.Agents).Count -eq 0 -and (Read-YesNo -Prompt 'Quer escolher CLIs de agentes agora (Claude, Codex, Pi, ...)?' -Default $false)) {
        $plan.Agents = @(Read-AgentMenu -Current @())
    }

    return $plan
}

function Resolve-InstallPlan {
    $flagTouched = $SkipBaseDx -or $InstallDocker -or $InstallGh -or $InstallHerdr -or $SetupGitHubSsh -or $PasswordlessSudo -or ($null -ne $Agents -and $Agents.Count -gt 0)

    $fromFlags = New-InstallPlan `
        -BaseDx (-not [bool]$SkipBaseDx) `
        -Docker ([bool]$InstallDocker) `
        -Gh ([bool]$InstallGh -or [bool]$SetupGitHubSsh) `
        -Herdr ([bool]$InstallHerdr) `
        -AgentList @(Normalize-AgentList -Value $Agents) `
        -GitHubSsh ([bool]$SetupGitHubSsh) `
        -PasswordlessSudoOpt ([bool]$PasswordlessSudo)

    if ($NonInteractive) {
        return $fromFlags
    }

    $savedPlan = Get-PlanFromState -Saved (Read-SavedState)
    if ($savedPlan -and -not $flagTouched) {
        Write-Ok 'Reusando recursos salvos da execução anterior (state.json).'
        Show-Plan -Plan $savedPlan
        if (Read-YesNo -Prompt 'Manter este plano?' -Default $true) {
            return $savedPlan
        }
    }

    $initial = if ($flagTouched) { $fromFlags } elseif ($savedPlan) { $savedPlan } else { (New-InstallPlan) }
    $plan = Read-FeaturePlan -Initial $initial
    Show-Plan -Plan $plan
    return $plan
}

function Get-GuestBootstrapArgs {
    param($Plan)
    $args = @()
    if (-not $Plan.BaseDx) { $args += '--skip-base-dx' }
    if ($Plan.Docker) { $args += '--docker' }
    if ($Plan.Gh -or $Plan.GitHubSsh) { $args += '--gh' }
    if ($Plan.Herdr) { $args += '--herdr' }
    if ($Plan.PasswordlessSudo) { $args += '--passwordless-sudo' }
    if ($Plan.Herdr) {
        $args += '--herdr-keys'
        $args += '/tmp/wsl-dev-env-herdr-omarchy-keys.toml'
    }
    if ($Plan.Agents -and @($Plan.Agents).Count -gt 0) {
        $args += '--agents'
        $args += (@($Plan.Agents) -join ',')
    }
    return ,@($args)
}

function Invoke-GuestBootstrap {
    param(
        [string]$DistroName,
        [string]$LinuxUser,
        $Plan,
        [Security.SecureString]$UserPassword
    )
    $guestWin = Join-Path $PSScriptRoot $script:GuestRel
    if (-not (Test-Path -LiteralPath $guestWin)) {
        throw "Bootstrap do guest ausente em $guestWin"
    }
    Write-Step 'Copiando guest/bootstrap.sh para o distro'
    $text = [System.IO.File]::ReadAllText($guestWin) -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    Copy-TextIntoWsl -DistroName $DistroName -Content $text -WslPath '/tmp/wsl-dev-env-bootstrap.sh' -Mode '755'

    if ($Plan.Herdr) {
        $keysWin = Join-Path $PSScriptRoot $script:HerdrKeysRel
        if (-not (Test-Path -LiteralPath $keysWin)) {
            throw "Template de atalhos Herdr ausente em $keysWin"
        }
        $keys = [System.IO.File]::ReadAllText($keysWin) -replace "`r`n", "`n" -replace "`r", "`n"
        if (-not $keys.EndsWith("`n")) { $keys += "`n" }
        Copy-TextIntoWsl -DistroName $DistroName -Content $keys -WslPath '/tmp/wsl-dev-env-herdr-omarchy-keys.toml' -Mode '644'
    }

    $bootArgs = @('/tmp/wsl-dev-env-bootstrap.sh', '--user', $LinuxUser)
    $bootArgs += @(Get-GuestBootstrapArgs -Plan $Plan)

    if ($null -ne $UserPassword) {
        $plain = ConvertFrom-SecureStringPlain -Secure $UserPassword
        try {
            if ([string]::IsNullOrEmpty($plain)) {
                throw 'Senha vazia não é permitida para conta nova.'
            }
            $passFile = '{0}:{1}' -f $LinuxUser, $plain
            if (-not $passFile.EndsWith("`n")) { $passFile += "`n" }
            Copy-TextIntoWsl -DistroName $DistroName -Content $passFile -WslPath '/tmp/wsl-dev-env-chpasswd' -Mode '600'
            $bootArgs += @('--password-file', '/tmp/wsl-dev-env-chpasswd')
        } finally {
            $plain = $null
            $passFile = $null
        }
    }

    Write-Step "Rodando bootstrap do guest como root e depois $LinuxUser"
    Invoke-Wsl -ArgumentList (
        @('-d', $DistroName, '-u', 'root', '--', 'bash') + $bootArgs
    )
    Write-Ok 'Bootstrap do guest terminou'
    Invoke-Wsl -ArgumentList @('--terminate', $DistroName) -IgnoreExitCode | Out-Null
    Write-Ok "Encerrou $DistroName para o usuário padrão de /etc/wsl.conf valer na próxima abertura"
}

function Strip-TomlTable {
    param([string[]]$Lines, [string]$Name)
    $skip = $false
    $out = New-Object System.Collections.Generic.List[string]
    $header = '[' + $Name + ']'
    $nested = '[' + $Name + '.'
    foreach ($line in $Lines) {
        $t = $line.Trim()
        if ($t -eq $header -or $t.StartsWith($nested)) {
            $skip = $true
            continue
        }
        if ($skip -and $t -match '^\[[A-Za-z0-9_-]+') {
            $skip = $false
        }
        if (-not $skip) { [void]$out.Add($line) }
    }
    return , @($out.ToArray())
}

function Strip-MarkedBlock {
    param([string[]]$Lines, [string]$Begin, [string]$End)
    $skip = $false
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        if ($line -eq $Begin) { $skip = $true; continue }
        if ($line -eq $End) { $skip = $false; continue }
        if (-not $skip) { [void]$out.Add($line) }
    }
    return , @($out.ToArray())
}

function Merge-HerdrOmarchyKeys {
    param([string]$ConfigPath)
    $keysWin = Join-Path $PSScriptRoot $script:HerdrKeysRel
    if (-not (Test-Path -LiteralPath $keysWin)) {
        throw "Template de atalhos Herdr ausente em $keysWin"
    }
    $dir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    $begin = '# --- wsl-dev-env begin:herdr-keys ---'
    $end = '# --- wsl-dev-env end:herdr-keys ---'
    $tBegin = '# --- wsl-dev-env begin:herdr-theme ---'
    $tEnd = '# --- wsl-dev-env end:herdr-theme ---'
    $existing = ''
    if (Test-Path -LiteralPath $ConfigPath) {
        $existing = [System.IO.File]::ReadAllText($ConfigPath)
    }
    $lines = @($existing -replace "`r`n", "`n" -replace "`r", "`n" -split "`n")
    $lines = @(Strip-MarkedBlock -Lines $lines -Begin $begin -End $end)
    $lines = @(Strip-TomlTable -Lines $lines -Name 'keys')
    $body = [System.IO.File]::ReadAllText($keysWin) -replace "`r`n", "`n" -replace "`r", "`n"
    $body = $body.TrimEnd("`n")
    $joined = ($lines -join "`n").TrimEnd()
    $chunk = $begin + "`n" + $body + "`n" + $end
    if ([string]::IsNullOrWhiteSpace($joined)) {
        $joined = $chunk
    } else {
        $joined = $joined + "`n`n" + $chunk
    }
    if ($joined -notmatch '(?m)^\[theme\]') {
        $theme = @"
$tBegin
# tokyo-night, como no config Omarchy do captain
[theme]
name = "tokyo-night"
auto_switch = false
$tEnd
"@
        $joined = $joined.TrimEnd() + "`n`n" + ($theme -replace "`r`n", "`n")
    }
    if (-not $joined.EndsWith("`n")) { $joined += "`n" }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ConfigPath, $joined, $utf8)
    Write-Ok "Atalhos Omarchy gravados em $ConfigPath (outras seções preservadas)"
}

function Install-HerdrWindows {
    Write-Step 'Herdr no Windows (instalador oficial, sem iniciar sessão)'
    $existing = Get-Command herdr -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Ok "herdr já no PATH ($($existing.Source))"
    } else {
        $tmp = Join-Path $env:TEMP 'wsl-dev-env-herdr-install.ps1'
        $prev = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri 'https://herdr.dev/install.ps1' -OutFile $tmp -UseBasicParsing
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
            Write-Ok 'Instalador oficial do Herdr no Windows terminou'
        } catch {
            Write-Warn2 "Falha ao instalar Herdr no Windows: $($_.Exception.Message)"
            Write-Warn2 'No guest o Herdr ainda pode ter sido instalado. Manual: irm https://herdr.dev/install.ps1 | iex'
        } finally {
            $ProgressPreference = $prev
        }
    }
    $cfg = Join-Path $env:APPDATA 'herdr\config.toml'
    try {
        Merge-HerdrOmarchyKeys -ConfigPath $cfg
    } catch {
        Write-Warn2 "Não foi possível gravar atalhos Omarchy no Herdr do Windows: $($_.Exception.Message)"
    }
}

function Invoke-GitHubSshGuide {
    param(
        [string]$DistroName,
        [string]$LinuxUser
    )
    Write-Step 'Guia GitHub + chave SSH (ed25519)'
    Write-Host 'Nunca compartilhe nem envie a chave PRIVADA. Só a .pub.' -ForegroundColor Yellow
    Write-Host 'A chave fica só em ~/.ssh no Ubuntu; este script nunca copia chave privada para o repositório.' -ForegroundColor Yellow

    $gen = @'
set -euo pipefail
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ -f "$HOME/.ssh/id_ed25519" ]; then
  echo "CHAVE_EXISTE"
else
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -C "wsl-dev-env" -N ""
  echo "CHAVE_NOVA"
fi
chmod 600 "$HOME/.ssh/id_ed25519"
chmod 644 "$HOME/.ssh/id_ed25519.pub"
cat "$HOME/.ssh/id_ed25519.pub"
'@
    if ($NonInteractive) {
        Write-Ok 'NonInteractive: gerando chave se faltar, sem abrir o navegador.'
    }
    $out = Invoke-Wsl -ArgumentList @(
        '-d', $DistroName, '-u', $LinuxUser, '--',
        'bash', '-lc', $gen
    )
    $text = ($out | Out-String -Width 4096) -replace "`0", ''
    Write-Host ''
    Write-Host 'Chave pública (cole no GitHub):' -ForegroundColor Green
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match 'PRIVATE KEY') { continue }
        if ($line -match '^\s*ssh-(ed25519|rsa|ed25519-sk) ') {
            Write-Host $line.Trim() -ForegroundColor Green
        }
    }
    Write-Host ''
    Write-Host 'No GitHub: Configurações -> SSH and GPG keys -> New SSH key'
    Write-Host '  https://github.com/settings/keys'
    Write-Host 'Ou, no Ubuntu: gh auth login   (GitHub.com, HTTPS ou SSH, login pelo navegador)'
    if (-not $NonInteractive) {
        if (Read-YesNo -Prompt 'Abrir a página de chaves SSH do GitHub no navegador?' -Default $true) {
            Start-Process 'https://github.com/settings/keys' | Out-Null
        }
        Write-Host 'Depois de cadastrar a chave pública, testamos ssh -T git@github.com'
        Read-Host 'Enter para testar (ou Ctrl+C para pular)' | Out-Null
    }
    Write-Step 'Testando ssh -T git@github.com'
    Invoke-Wsl -ArgumentList @(
        '-d', $DistroName, '-u', $LinuxUser, '--',
        'bash', '-lc',
        'ssh -o StrictHostKeyChecking=accept-new -T git@github.com || true'
    ) -IgnoreExitCode | Out-Null
    Write-Ok 'Teste SSH disparado (o GitHub costuma responder "Hi <user>!" com código 1 — isso é sucesso).'
}

function Show-NextSteps {
    param([string]$DistroName, [string]$LinuxUser, $Plan)
    Write-Host ''
    Write-Host 'Pronto. Abra um shell WSL:' -ForegroundColor Green
    Write-Host "  wsl -d $DistroName -u $LinuxUser" -ForegroundColor Green
    Write-Host ''
    if ($Plan.Docker) {
        Write-Host 'Docker: engine no Ubuntu. Abra um shell NOVO para o grupo docker valer.'
        Write-Host '  docker run --rm hello-world'
        Write-Host 'Não instale Docker Desktop por cima deste engine (conflito). Quem preferir Desktop: use-o no lugar deste recurso.'
    }
    if ($Plan.Herdr) {
        Write-Host 'Herdr: instale/anexe você mesmo com `herdr` no Ubuntu (este instalador NÃO inicia o Herdr).'
        Write-Host 'Atalhos Omarchy: prefixo ctrl+espaço (ver guest/herdr-omarchy-keys.toml).'
    }
    if ($Plan.GitHubSsh) {
        Write-Host 'GitHub: se o teste SSH falhou, cadastre a .pub em https://github.com/settings/keys e rode: ssh -T git@github.com'
    }
    Write-Host 'Opcional:'
    Write-Host '  Windows Terminal        # ícones do starship ficam melhores com Nerd Font, não obrigatório'
    Write-Host 'Reexecução (idempotente, não apaga o distro):'
    Write-Host "  powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -Username $LinuxUser"
}

# --- main ---
if ($BootstrapOnly -and $SkipBootstrap) {
    throw '-BootstrapOnly e -SkipBootstrap não podem ser combinados.'
}

$linuxUser = $null
$script:Plan = $null
$userPassword = $Password

try {
    Test-WindowsCapability | Out-Null
    if ($Username) {
        $normalized = $Username.Trim().ToLowerInvariant()
        if (-not (Test-ValidLinuxUsername $normalized)) {
            throw "Nome de usuário Linux inválido '$Username'. Use letras minúsculas, dígitos, _ ou -, começando com letra ou _."
        }
        $Username = $normalized
    }

    $script:Plan = Resolve-InstallPlan
    if (-not $script:Plan) { $script:Plan = New-InstallPlan }

    if (-not $BootstrapOnly) {
        if ($Username) { Save-State -User $Username -DistroName $Distro -Plan $script:Plan }
        $reboot = Enable-WslFeatures
        if ($reboot) {
            Write-Host ''
            Write-Warn2 'Recursos do Windows foram habilitados e é preciso reiniciar antes do WSL2 funcionar.'
            Write-Host 'Reinicie e rode o mesmo comando (o script é idempotente; senha NÃO fica salva):' -ForegroundColor Yellow
            $hintUser = if ($Username) { " -Username $Username" } else { '' }
            Write-Host "  powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1$hintUser" -ForegroundColor Yellow
            exit $script:RebootExitCode
        }
        $stillNeedReboot = Install-WslHost
        if ($stillNeedReboot) {
            Write-Warn2 'wsl.exe ainda não está disponível. Reinicie e rode este script de novo.'
            exit $script:RebootExitCode
        }
        $linuxUser = Resolve-LinuxUsername -DistroName $Distro
        Save-State -User $linuxUser -DistroName $Distro -Plan $script:Plan
        Install-UbuntuDistro -DistroName $Distro
    } else {
        if (-not (Get-WslExe)) { throw 'wsl.exe não encontrado. Rode sem -BootstrapOnly primeiro.' }
        $linuxUser = Resolve-LinuxUsername -DistroName $Distro
        if (-not (Test-WslDistroHealthy -Name $Distro)) {
            throw "Distro '$Distro' ausente ou não saudável. Rode sem -BootstrapOnly."
        }
    }

    if (-not $linuxUser) {
        $linuxUser = Resolve-LinuxUsername -DistroName $Distro
    }
    Save-State -User $linuxUser -DistroName $Distro -Plan $script:Plan

    $userExists = Test-LinuxUserExists -DistroName $Distro -LinuxUser $linuxUser
    if (-not $userExists) {
        if ($null -eq $userPassword) {
            if ($NonInteractive) {
                throw "Conta nova '$linuxUser' exige senha: passe -Password (SecureString). Não criamos senha vazia."
            }
            $userPassword = Read-LinuxPassword
        }
    } else {
        Write-Ok "Usuário $linuxUser já existe; senha não será redefinida"
        if ($userPassword) {
            Write-Warn2 'Uma senha foi informada, mas a conta já existe; ignorando a senha nova.'
            $userPassword = $null
        }
    }

    if (-not $SkipBootstrap) {
        Invoke-GuestBootstrap -DistroName $Distro -LinuxUser $linuxUser -Plan $script:Plan -UserPassword $userPassword
    } else {
        Write-Ok 'SkipBootstrap definido; ferramentas do guest não foram instaladas'
        if (-not $userExists -and $null -ne $userPassword) {
            Write-Warn2 'SkipBootstrap: a conta Linux só é criada no bootstrap. Rode sem -SkipBootstrap para criar o usuário com senha.'
        }
    }

    if ($script:Plan.Herdr) {
        Install-HerdrWindows
    }

    if ($script:Plan.GitHubSsh -and -not $SkipBootstrap) {
        Invoke-GitHubSshGuide -DistroName $Distro -LinuxUser $linuxUser
    }

    Show-NextSteps -DistroName $Distro -LinuxUser $linuxUser -Plan $script:Plan
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
