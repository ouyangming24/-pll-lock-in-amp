@echo off
rem Build with MinGW g++ without CMake/VS. Defaults to Vivado-bundled MinGW; override GXX_DIR.
setlocal
if "%GXX_DIR%"=="" set GXX_DIR=D:\software\xilinx\2025.1\tps\mingw\10.0.0\win64.o\nt\bin
set PATH=%GXX_DIR%;%PATH%
cd /d %~dp0
if not exist build_mingw mkdir build_mingw

set CXXFLAGS=-std=c++17 -O2 -Wall -Wextra -Iinclude

g++ %CXXFLAGS% -c src\lockin_sdk.cpp      -o build_mingw\lockin_sdk.o      || goto :err
g++ %CXXFLAGS% -c src\serial_port_win.cpp -o build_mingw\serial_port_win.o || goto :err
ar rcs build_mingw\liblockin_sdk_osc1.a build_mingw\lockin_sdk.o build_mingw\serial_port_win.o || goto :err
g++ %CXXFLAGS% examples\demo.cpp build_mingw\liblockin_sdk_osc1.a -lsetupapi -static -o build_mingw\lockin_osc1_demo.exe || goto :err
g++ %CXXFLAGS% tests\sdk_selftest.cpp build_mingw\liblockin_sdk_osc1.a -lsetupapi -static -o build_mingw\sdk_osc1_selftest.exe || goto :err

echo.
echo OK: build_mingw\liblockin_sdk_osc1.a  build_mingw\lockin_osc1_demo.exe  build_mingw\sdk_osc1_selftest.exe
exit /b 0
:err
echo BUILD FAILED
exit /b 1
