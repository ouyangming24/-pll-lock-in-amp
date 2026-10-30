<#
.SYNOPSIS
  一键: Vivado 出 bit/XSA → (可选) Vitis 更新 Platform → bootgen 生成 BOOT.bin → 可选拷到 SD

.DESCRIPTION
  PL 逻辑变更时, BOOT.bin 真正需要更新的是 bit; fsbl.elf 仅在 PS/硬件交接变更时才必须重编.
  若 Vitis IDE 正占用 solidify_lock, Platform 更新会失败 — 脚本仍会用
  Vivado 新 bit + 现有 fsbl.elf 生成 BOOT.bin.

.PARAMETER SkipVivado
  已有最新 bit/XSA 时跳过 Vivado

.PARAMETER SkipVitis
  跳过 Platform update (推荐: IDE 开着时; PL-only 改动够用)

.PARAMETER RequireVitis
  Platform 更新失败则中止 (默认失败只警告, 仍打 BOOT.bin)

.PARAMETER Jobs
  Vivado 并行核数 (默认 8)

.PARAMETER XsaName
  XSA 文件名 (默认 design_1_wrapper.xsa)

.PARAMETER SdDrive
  SD 盘符, 如 E:

.PARAMETER OpenExplorer
  完成后打开 boot 目录

.PARAMETER PauseAtEnd
  结束时 pause (双击 .bat 时用, 避免窗口闪退)
#>
[CmdletBinding()]
param(
    [switch]$SkipVivado,
    [switch]$SkipVitis,
    [switch]$RequireVitis,
    [int]$Jobs = 8,
    [string]$XsaName = "design_1_wrapper.xsa",
    [string]$SdDrive = "",
    [switch]$OpenExplorer,
    [switch]$PauseAtEnd
)

$ErrorActionPreference = "Stop"

$GitPll = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $GitPll "project_1.xpr"))) {
    throw "未找到 project_1.xpr, 请在 git_pll 仓库下运行本脚本"
}
$Solidify = Join-Path (Split-Path -Parent $GitPll) "solidify_lock"
$XsaPath  = Join-Path $GitPll $XsaName
$BootDir  = Join-Path $Solidify "boot"
$BootBin  = Join-Path $BootDir "BOOT.bin"
$BifPath  = Join-Path $BootDir "BOOT.auto.bif"
$VivadoBit = Join-Path $GitPll "project_1.runs\impl_1\design_1_wrapper.bit"

$VivadoBat = "D:\software\xilinx\2025.1\Vivado\bin\vivado.bat"
$VitisBat  = "D:\software\xilinx\2025.1\Vitis\bin\vitis.bat"
$Bootgen   = "D:\software\xilinx\2025.1\Vitis\bin\bootgen.bat"

foreach ($p in @($VivadoBat, $VitisBat, $Bootgen)) {
    if (-not (Test-Path $p)) { throw "找不到工具: $p (请改脚本里的 Xilinx 安装路径)" }
}
if (-not (Test-Path $Solidify)) {
    throw "找不到 Vitis 工作区: $Solidify"
}

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "======== $msg ========" -ForegroundColor Cyan
}

function Invoke-LoggedCmd {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$LogPath
    )
    # 用 cmd 跑 .bat, 保证 ERRORLEVEL 传回; 同时写日志
    $argLine = ($ArgumentList | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '
    $cmd = "`"$FilePath`" $argLine"
    cmd.exe /c "$cmd > `"$LogPath`" 2>&1"
    $code = $LASTEXITCODE
    if (Test-Path $LogPath) {
        Get-Content -Path $LogPath -Encoding UTF8 -ErrorAction SilentlyContinue | Write-Host
    }
    return $code
}

$failed = $false
try {
    # ---- 1. Vivado ----
    if (-not $SkipVivado) {
        Write-Step "1/4 Vivado: bitstream + export XSA"
        $tcl  = Join-Path $PSScriptRoot "vivado_build_export.tcl"
        $log  = Join-Path $PSScriptRoot "_vivado_build.log"
        $wrap = Join-Path $env:TEMP "lockin_vivado_wrap.tcl"
        @"
set jobs $Jobs
set xsa_out {$XsaPath}
set skip_impl 0
source {$tcl}
"@ | Set-Content -Path $wrap -Encoding ASCII
        Write-Host "log -> $log"
        $vc = Invoke-LoggedCmd -FilePath $VivadoBat -ArgumentList @("-mode","batch","-nojournal","-nolog","-source",$wrap) -LogPath $log
        if ($vc -ne 0 -or -not (Test-Path $XsaPath) -or -not (Test-Path $VivadoBit)) {
            throw "Vivado 失败 (exit=$vc). 详见 $log"
        }
        Write-Host "OK bit: $VivadoBit  ($((Get-Item $VivadoBit).LastWriteTime))" -ForegroundColor Green
        Write-Host "OK XSA: $XsaPath" -ForegroundColor Green
    } else {
        Write-Step "1/4 Vivado: SKIP"
        if (-not (Test-Path $VivadoBit)) { throw "SkipVivado 但缺少 $VivadoBit" }
        if (-not (Test-Path $XsaPath)) {
            Write-Host "警告: 无 XSA $XsaPath (仅影响 Vitis update_hw)" -ForegroundColor Yellow
        }
    }

    # ---- 2. Vitis Platform (可选) ----
    $vitisOk = $false
    if (-not $SkipVitis) {
        Write-Step "2/4 Vitis: update_hw + clean + build platform"
        # IDE 占用时必败 — 提前提示
        $ide = Get-Process -Name "vitis-ide" -ErrorAction SilentlyContinue
        if ($ide) {
            Write-Host "检测到 Vitis IDE 正在运行 (PID: $($ide.Id -join ','))." -ForegroundColor Yellow
            Write-Host "同一工作区被占用时 Platform 更新会失败; 建议关掉 IDE 或加 -SkipVitis." -ForegroundColor Yellow
        }
        $env:LOCKIN_VITIS_WS = $Solidify
        $env:LOCKIN_XSA = $XsaPath
        $env:LOCKIN_PLATFORM = "platform"
        $py = Join-Path $PSScriptRoot "vitis_rebuild_platform.py"
        $vlog = Join-Path $PSScriptRoot "_vitis_rebuild.log"
        $code = Invoke-LoggedCmd -FilePath $VitisBat -ArgumentList @("-s", $py) -LogPath $vlog
        $logText = if (Test-Path $vlog) { Get-Content $vlog -Raw -ErrorAction SilentlyContinue } else { "" }
        if ($code -eq 0 -and $logText -match "OK: platform rebuilt") {
            $vitisOk = $true
            Write-Host "OK platform rebuilt" -ForegroundColor Green
        } else {
            $msg = "Vitis Platform 未更新成功 (exit=$code). 详见 $vlog"
            if ($RequireVitis) {
                throw $msg
            }
            Write-Host "警告: $msg" -ForegroundColor Yellow
            Write-Host "将继续用 Vivado 新 bit + 现有 fsbl.elf 生成 BOOT.bin (PL-only 够用)." -ForegroundColor Yellow
        }
    } else {
        Write-Step "2/4 Vitis: SKIP"
    }

    # ---- 3. bootgen ----
    Write-Step "3/4 bootgen: BOOT.bin"
    $Fsbl = Join-Path $Solidify "platform\export\platform\sw\boot\fsbl.elf"
    if (-not (Test-Path $Fsbl)) { throw "找不到 fsbl.elf: $Fsbl (需至少成功 Build 过一次 Platform)" }

    # 优先 Vivado 刚出的 bit (PL 最新); 其次 platform export
    $Bit = $null
    $BitNote = ""
    if (Test-Path $VivadoBit) {
        $Bit = $VivadoBit
        $BitNote = "Vivado impl_1 (推荐 PL 最新)"
    }
    if ($vitisOk) {
        $BitFromSdt = Get-ChildItem (Join-Path $Solidify "platform\export\platform\hw\sdt") -Filter "*.bit" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $platBit = Join-Path $Solidify "platform\export\platform\hw\design_1_wrapper.bit"
        if ($BitFromSdt -and $BitFromSdt.LastWriteTime -ge (Get-Item $VivadoBit).LastWriteTime.AddMinutes(-1)) {
            $Bit = $BitFromSdt.FullName
            $BitNote = "platform export/sdt"
        } elseif (Test-Path $platBit) {
            $pItem = Get-Item $platBit
            if ($pItem.LastWriteTime -ge (Get-Item $VivadoBit).LastWriteTime.AddMinutes(-1)) {
                $Bit = $platBit
                $BitNote = "platform export/hw"
            }
        }
    }
    if (-not $Bit) { throw "找不到可用 .bit" }

    $fsblInfo = Get-Item $Fsbl
    $bitInfo  = Get-Item $Bit
    Write-Host "fsbl.elf : $($fsblInfo.FullName)"
    Write-Host "           $($fsblInfo.LastWriteTime)  ($([math]::Round($fsblInfo.Length/1KB)) KB)  vitisOk=$vitisOk"
    Write-Host "bit      : $($bitInfo.FullName)"
    Write-Host "           $($bitInfo.LastWriteTime)  ($([math]::Round($bitInfo.Length/1MB,2)) MB)  [$BitNote]"

    New-Item -ItemType Directory -Force -Path $BootDir | Out-Null
    $bifText = @"
//arch = zynq; split = false; format = BIN
// auto-generated by rebuild_sd_boot.ps1
the_ROM_image:
{
	[bootloader]$Fsbl
	$Bit
}
"@
    Set-Content -Path $BifPath -Value $bifText -Encoding ASCII
    Write-Host "BIF: $BifPath"

    $blog = Join-Path $PSScriptRoot "_bootgen.log"
    $bc = Invoke-LoggedCmd -FilePath $Bootgen -ArgumentList @("-arch","zynq","-image",$BifPath,"-w","on","-o",$BootBin) -LogPath $blog
    if ($bc -ne 0 -or -not (Test-Path $BootBin)) {
        throw "bootgen 失败 (exit=$bc), 见 $blog"
    }
    $bootInfo = Get-Item $BootBin
    Write-Host "OK BOOT.bin: $($bootInfo.FullName)" -ForegroundColor Green
    Write-Host "   时间 $($bootInfo.LastWriteTime)  大小 $([math]::Round($bootInfo.Length/1MB,2)) MB" -ForegroundColor Green

    # ---- 4. SD ----
    Write-Step "4/4 复制到 SD"
    if ($SdDrive -ne "") {
        $drive = $SdDrive.TrimEnd('\').TrimEnd('/')
        if ($drive -notmatch ':$') { $drive = "${drive}:" }
        if (-not (Test-Path "$drive\")) { throw "SD 盘符不存在: $drive" }
        Copy-Item $BootBin (Join-Path $drive "BOOT.bin") -Force
        Write-Host "已复制到 ${drive}\BOOT.bin" -ForegroundColor Green
        Write-Host "请拨码 SD 启动后重新上电验证 LED1 闪烁." -ForegroundColor Yellow
    } else {
        Write-Host "未指定 -SdDrive, 请手动拷贝:" -ForegroundColor Yellow
        Write-Host "  $BootBin"
    }

    if ($OpenExplorer) {
        Start-Process explorer.exe $BootDir
    }

    Write-Host ""
    Write-Host "全部完成." -ForegroundColor Green
    if (-not $vitisOk -and -not $SkipVitis) {
        Write-Host "说明: fsbl.elf 未重编 (Vitis 未成功). PL-only 改动一般仍可用旧 fsbl." -ForegroundColor Yellow
    }
}
catch {
    $failed = $true
    Write-Host ""
    Write-Host "失败: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($PauseAtEnd) {
        Write-Host ""
        Read-Host "按 Enter 关闭"
    }
}

if ($failed) { exit 1 }
exit 0
