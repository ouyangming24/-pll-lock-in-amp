# =============================================================================
# vitis_rebuild_platform.py
#
# 用新 XSA 更新 solidify_lock 里的 Platform 并 Rebuild (生成 fsbl.elf + 导出 bit)
#
# 用法:
#   vitis -s tools/vitis_rebuild_platform.py
# 环境变量 (可选):
#   LOCKIN_VITIS_WS   默认 ..\solidify_lock (相对 git_pll)
#   LOCKIN_XSA        默认 <git_pll>\design_1_wrapper.xsa
#   LOCKIN_PLATFORM   默认 platform
#
# 注意: 若 Vitis IDE 已打开同一工作区, set_workspace 会失败.
# =============================================================================
import os
import sys

import vitis

HERE = os.path.dirname(os.path.abspath(__file__))
GIT_PLL = os.path.normpath(os.path.join(HERE, ".."))
DEFAULT_WS = os.path.normpath(os.path.join(GIT_PLL, "..", "solidify_lock"))
DEFAULT_XSA = os.path.join(GIT_PLL, "design_1_wrapper.xsa")

ws = os.environ.get("LOCKIN_VITIS_WS", DEFAULT_WS)
xsa = os.environ.get("LOCKIN_XSA", DEFAULT_XSA)
plat_name = os.environ.get("LOCKIN_PLATFORM", "platform")


def log(msg: str) -> None:
    print(msg, flush=True)


log("==== vitis_rebuild_platform ====")
log(f"workspace: {ws}")
log(f"xsa      : {xsa}")
log(f"platform : {plat_name}")

if not os.path.isfile(xsa):
    print("ERROR: XSA 不存在:", xsa, file=sys.stderr, flush=True)
    sys.exit(1)
if not os.path.isdir(ws):
    print("ERROR: Vitis workspace 不存在:", ws, file=sys.stderr, flush=True)
    sys.exit(1)

client = None
try:
    client = vitis.create_client()
    try:
        client.set_workspace(path=ws)
    except Exception as e:
        msg = str(e)
        print(f"ERROR: set_workspace 失败: {msg}", file=sys.stderr, flush=True)
        if "already in use" in msg.lower() or "FAILED_PRECONDITION" in msg:
            print(
                "HINT: 请先关闭正在打开 solidify_lock 的 Vitis IDE, 再重跑;"
                " 或仅用 -SkipVitis, 脚本仍可用 Vivado 新 bit + 现有 fsbl 生成 BOOT.bin",
                file=sys.stderr,
                flush=True,
            )
        sys.exit(2)

    platform = client.get_component(name=plat_name)
    log("update_hw ...")
    platform.update_hw(hw_design=xsa)
    log("clean ...")
    platform.clean()
    log("build ...")
    platform.build()
    log("OK: platform rebuilt")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr, flush=True)
    sys.exit(1)
finally:
    if client is not None:
        try:
            client.dispose()
        except Exception:
            pass

sys.exit(0)
