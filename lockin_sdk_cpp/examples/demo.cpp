// SDK 示例: 配置振荡器1/2 → DAC 输出振荡器1 → 抓 V5/V6 波形存 CSV → 读 2 秒锁相结果
//
// 用法: lockin_demo [COMx]      (不带参数时自动找 CH340)
#include <lockin/lockin_sdk.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <thread>

#ifdef _WIN32
#include <windows.h>
#endif

using namespace lockin;

static bool check(bool ok, LockinDevice& dev, const char* what) {
    if (!ok) std::printf("  [FAIL] %s: %s\n", what, dev.lastError().c_str());
    return ok;
}

static void printWave(const char* name, const std::vector<double>& v) {
    double mn = *std::min_element(v.begin(), v.end());
    double mx = *std::max_element(v.begin(), v.end());
    double sum = 0, sq = 0;
    for (double x : v) { sum += x; sq += x * x; }
    double mean = sum / v.size();
    double rms = std::sqrt(sq / v.size());
    std::printf("  %s: min %+.4f V  max %+.4f V  Vpp %.4f V  mean %+.4f V  rms %.4f V\n",
                name, mn, mx, mx - mn, mean, rms);
}

static void saveCsv(const char* path, const ScopeData& s) {
    FILE* f = std::fopen(path, "w");
    if (!f) return;
    std::fprintf(f, "t_s,v5_V,v6_V\n");
    for (size_t i = 0; i < s.n; ++i)
        std::fprintf(f, "%.9f,%.6f,%.6f\n", s.timeAt(i), s.v5[i], s.v6[i]);
    std::fclose(f);
}

// 双击运行时控制台只属于本进程, 退出前停住, 否则窗口一闪而过
static void pauseIfOwnConsole() {
#ifdef _WIN32
    DWORD pids[2];
    if (GetConsoleProcessList(pids, 2) <= 1) {
        std::printf("\nPress Enter to exit...");
        std::fflush(stdout);
        std::getchar();
    }
#endif
}

int main(int argc, char** argv) {
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif
    std::atexit(pauseIfOwnConsole);
    std::printf("Serial ports:\n");
    for (const auto& p : LockinDevice::listPorts())
        std::printf("  %-6s %s%s\n", p.name.c_str(), p.description.c_str(), p.isCh340 ? "  [CH340]" : "");

    LockinDevice dev;
    std::string port = argc > 1 ? argv[1] : "";
    if (!dev.open(port)) {
        std::printf("open failed: %s\n", dev.lastError().c_str());
        return 1;
    }
    std::printf("connected: %s\n", dev.portName().c_str());

    // ---- 振荡器1 / 2: 手动频率模式 ----------------------------------------
    std::printf("configure oscillators\n");
    check(dev.setRefMode(RefMode::Manual), dev, "REFMODE");

    check(dev.setOscFrequency(1, 10000.0), dev, "osc1 freq");
    check(dev.setOscHarmonic(1, 1), dev, "osc1 harmonic");
    check(dev.setOscInput(1, OscInput::CH3), dev, "osc1 input");
    check(dev.setOscTimeConstant(1, 12), dev, "osc1 tau");
    check(dev.setOscFilterOrder(1, 2), dev, "osc1 order");

    check(dev.setOscFrequency(2, 20000.0), dev, "osc2 freq");
    check(dev.setOscHarmonic(2, 1), dev, "osc2 harmonic");
    check(dev.setOscInput(2, OscInput::CH3), dev, "osc2 input");
    check(dev.setOscTimeConstant(2, 12), dev, "osc2 tau");
    check(dev.setOscFilterOrder(2, 2), dev, "osc2 order");
    std::printf("  tau 12 -> fc = %.3f Hz, TC = %.3f ms\n", tauToCutoffHz(12), tauToSeconds(12) * 1e3);

    // ---- DAC: 振荡器1 的正弦, 1 Vpk, 无偏置 --------------------------------
    std::printf("configure DAC\n");
    check(dev.setDacSource(1), dev, "DAC source");
    check(dev.setDacWaveform(DacWave::Sine), dev, "DAC wave");
    check(dev.setDacAmplitude(1.0), dev, "DAC amplitude");
    check(dev.setDacOffset(0.0), dev, "DAC offset");

    // ---- 示波器: 自由触发 + V5 上升沿触发 ---------------------------------
    std::printf("scope capture (free run, decim 0 -> 1 us/pt)\n");
    ScopeData sd;
    ScopeConfig cfg;
    if (check(dev.captureScope(sd, cfg), dev, "scope free")) {
        std::printf("  seq %u  n %u  pre %u  dt %.1f us  forced %d\n", sd.seq, sd.n, sd.pre,
                    sd.dt * 1e6, sd.forced);
        printWave("V5", sd.v5);
        printWave("V6", sd.v6);
        saveCsv("scope_free.csv", sd);
        std::printf("  saved scope_free.csv\n");
    }

    std::printf("scope capture (V5 rising @ 0 V, decim 9 -> 10 us/pt)\n");
    cfg.decimation = 9;
    cfg.trigger = ScopeTrigger::V5Rising;
    cfg.levelVolts = 0.0;
    if (check(dev.captureScope(sd, cfg), dev, "scope V5 rising")) {
        std::printf("  seq %u  dt %.1f us  forced %d  (forced=1: no edge found, auto-triggered)\n",
                    sd.seq, sd.dt * 1e6, sd.forced);
        printWave("V5", sd.v5);
        printWave("V6", sd.v6);
        saveCsv("scope_trig.csv", sd);
        std::printf("  saved scope_trig.csv\n");
    }

    // ---- 数据流: 2 秒 -------------------------------------------------------
    std::printf("stream 2 s\n");
    std::atomic<int> nCb{0};
    dev.setFrameCallback([&](const Frame&) { ++nCb; });
    if (check(dev.startStream(), dev, "XYOUT")) {
        std::this_thread::sleep_for(std::chrono::seconds(2));
        check(dev.stopStream(), dev, "stop");
        std::printf("  frames: %d (callback)  crc errors: %llu\n", nCb.load(),
                    static_cast<unsigned long long>(dev.crcErrors()));
        Frame f;
        if (dev.latestFrame(f)) {
            for (int osc = 1; osc <= 2; ++osc)
                std::printf("  osc%d: ref %.3f Hz  X %+.6f V  Y %+.6f V  R %.6f Vpk  phase %+.2f deg\n",
                            osc, f.oscRefHz(osc), f.oscXVolts(osc), f.oscYVolts(osc),
                            f.oscRVolts(osc), f.oscPhaseDeg(osc));
            std::printf("  PLL1 %.3f Hz (%s)  PLL2 %.3f Hz (%s)\n", f.pllHz(1),
                        f.ch1Locked() ? "locked" : "unlocked", f.pllHz(2),
                        f.ch2Locked() ? "locked" : "unlocked");
        }
    }
    dev.setFrameCallback(nullptr);

    dev.close();
    std::printf("done\n");
    return 0;
}
