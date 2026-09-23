# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec: 生成可拷贝到其他 Windows 电脑直接运行的绿色包
# 用法: 在 lockin_gui 目录执行  build_portable.bat

block_cipher = None

a = Analysis(
    ['main.py'],
    pathex=[],
    binaries=[],
    datas=[],
    hiddenimports=[
        'PyQt5.QtCore',
        'PyQt5.QtGui',
        'PyQt5.QtWidgets',
        'PyQt5.sip',
        'pyqtgraph',
        'pyqtgraph.graphicsItems',
        'numpy',
        'serial',
        'serial.tools',
        'serial.tools.list_ports',
        'device',
        'main_window',
        'stress_calc',
        # OpenGL 可选; 未安装时 GUI 自动回退 CPU 渲染
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        'matplotlib',
        'tkinter',
        'pytest',
        'IPython',
        'jupyter',
        'pandas',
        'scipy',
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='LockinGUI',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,          # 无黑框窗口; 调试可改为 True
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='LockinGUI',
)
