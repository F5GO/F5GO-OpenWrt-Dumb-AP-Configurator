# =====================================================
# НАЗВАНИЕ: OpenWrt Dumb AP Launcher (Windows)
# ОПИСАНИЕ: Копирует f5go-openwrt-dumb-ap.sh на роутер OpenWrt по SCP
#           и запускает его через SSH. Python не требуется.
#           Если OpenSSH Client не установлен, пытается установить автоматически.
#           Если локального скрипта нет, пытается скачать его с GitHub.
# =====================================================

[CmdletBinding()]
param(
    [string]$RouterIp,
    [string]$User = "root",
    [int]$Port = 22,
    [string]$RemotePath = "/tmp/f5go-openwrt-dumb-ap.sh",
    [string]$ScriptUrl = "https://raw.githubusercontent.com/F5GO/F5GO-OpenWrt-Dumb-AP-Configurator/main/f5go-openwrt-dumb-ap.sh",
    [switch]$CopyOnly
)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-OpenSshClient {
    $ssh = Get-Command ssh -ErrorAction SilentlyContinue
    $scp = Get-Command scp -ErrorAction SilentlyContinue
    if ($ssh -and $scp) {
        return
    }

    Write-Host "OpenSSH Client не найден. Пробую установить..."
    if (-not (Test-IsAdmin)) {
        throw "Для авто-установки OpenSSH Client запустите PowerShell от имени администратора и повторите."
    }

    $capName = "OpenSSH.Client~~~~0.0.1.0"
    $cap = Get-WindowsCapability -Online -Name $capName
    if ($cap.State -ne "Installed") {
        Add-WindowsCapability -Online -Name $capName | Out-Null
    }

    $ssh = Get-Command ssh -ErrorAction SilentlyContinue
    $scp = Get-Command scp -ErrorAction SilentlyContinue
    if (-not ($ssh -and $scp)) {
        throw "OpenSSH Client не удалось установить автоматически. Установите вручную в Optional Features."
    }
}

function Ask-Default([string]$Prompt, [string]$Default) {
    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Ensure-LocalScript([string]$Path, [string]$Url) {
    if (Test-Path -LiteralPath $Path) {
        return
    }

    Write-Host "Локальный файл не найден: $Path"
    Write-Host "Пробую скачать: $Url"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
    } catch {
        throw "Не удалось скачать скрипт с GitHub. Скачайте все файлы репозитория заранее (например, из GitHub Release)."
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Скрипт не скачан: $Path"
    }
}

Ensure-OpenSshClient

if ([string]::IsNullOrWhiteSpace($RouterIp)) {
    $RouterIp = Ask-Default "Router IP" "192.168.1.1"
}
if ([string]::IsNullOrWhiteSpace($User)) {
    $User = Ask-Default "SSH user" "root"
}

$localScript = Join-Path $PSScriptRoot "f5go-openwrt-dumb-ap.sh"
Ensure-LocalScript -Path $localScript -Url $ScriptUrl

$target = "$User@$RouterIp" + ":" + "$RemotePath"
Write-Host "Загрузка: $localScript -> $target"
& scp -P $Port "$localScript" "$target"
if ($LASTEXITCODE -ne 0) {
    throw "SCP завершился с ошибкой: $LASTEXITCODE"
}
Write-Host "Загрузка завершена."

if ($CopyOnly) {
    Write-Host "Copy-only режим: запуск на роутере пропущен."
    exit 0
}

$remoteCmd = "chmod +x '$RemotePath' && sh '$RemotePath'"
Write-Host "Запуск скрипта на роутере..."
& ssh -tt -p $Port "$User@$RouterIp" "$remoteCmd"
if ($LASTEXITCODE -ne 0) {
    throw "SSH завершился с ошибкой: $LASTEXITCODE"
}

Write-Host "Готово."
