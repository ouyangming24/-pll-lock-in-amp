@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo ========================================
echo  锁相 GUI 绿色包打包 (PyInstaller)
echo ========================================
echo.

where python >nul 2>&1
if errorlevel 1 (
    echo [错误] 找不到 python，请先安装 Python 并加入 PATH
    pause
    exit /b 1
)

python -c "import PyInstaller" 2>nul
if errorlevel 1 (
    echo [信息] 正在安装 PyInstaller...
    python -m pip install -U pyinstaller
)

echo [信息] 安装/核对运行依赖...
python -m pip install -r requirements.txt -q

echo.
echo [信息] 开始打包 (onedir，约 1~3 分钟)...
if exist build rmdir /s /q build
if exist dist\LockinGUI rmdir /s /q dist\LockinGUI

python -m PyInstaller --noconfirm --clean lockin_gui.spec
if errorlevel 1 (
    echo [错误] 打包失败
    pause
    exit /b 1
)

echo.
echo [信息] 写入启动脚本与说明...
copy /y portable_assets\启动_UDP模式.bat dist\LockinGUI\ >nul
copy /y portable_assets\启动_串口模式.bat dist\LockinGUI\ >nul
copy /y portable_assets\启动_演示模式.bat dist\LockinGUI\ >nul
copy /y portable_assets\使用说明.txt dist\LockinGUI\ >nul

echo.
echo ========================================
echo  完成!
echo  输出目录: %cd%\dist\LockinGUI\
echo  把整个 LockinGUI 文件夹拷到目标电脑即可
echo ========================================
explorer dist\LockinGUI
pause
