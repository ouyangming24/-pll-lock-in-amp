// SDK Osc1 示例: 配振荡器1 → DAC → SDKOUT 流 2 秒 (每帧含 osc1 X/Y + V3/V4/V5)
//
// 用法: lockin_osc1_demo [COMx]
#include <lockin_osc1/lockin_sdk.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>

#ifdef _WIN32
#include <windows.h>
#endif

using namespace lockin_osc1;

static bool check(bool ok, LockinDevice& dev, const char* what) {
    if (!ok) std::printf("  [FAIL] %s: %s\n", what, dev.lastError().c_str());
    return ok;
}

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
        std::printf("  %-6s %s%s\n", p.name.c_str(), p.description.c_str(),
                    p.isCh340 ? "  [CH340]" : "");

    LockinDevice dev;
    std::string port = argc > 1 ? argv[1] : "";
    if (!dev.open(port)) {
        std::printf("open failed: %s\n", dev.lastError().c_str());
        return 1;
    }
    std::printf("connected: %s\n", dev.portName().c_str());

    std::printf("configure oscillator 1\n");
    check(dev.setRefMode(RefMode::Manual), dev, "REFMODE");
    check(dev.setOsc1Frequency(10000.0), dev, "osc1 freq");
    check(dev.setOsc1Harmonic(1), dev, "osc1 harmonic");
    check(dev.setOsc1Input(OscInput::CH3), dev, "osc1 input");
    check(dev.setOsc1TimeConstant(12), dev, "osc1 tau");
    check(dev.setOsc1FilterOrder(2), dev, "osc1 order");

    std::printf("configure DAC (osc1 sine, 1 Vpk)\n");
    check(dev.setDacSourceOsc1(), dev, "DAC source");
    check(dev.setDacWaveform(DacWave::Sine), dev, "DAC wave");
    check(dev.setDacAmplitude(1.0), dev, "DAC amplitude");
    check(dev.setDacOffset(0.0), dev, "DAC offset");

    std::printf("ADC range V3/V4 = ±10 V (default)\n");
    check(dev.setAdcRangeV3(AdcRange::Bipolar10V), dev, "RNG3");
    check(dev.setAdcRangeV4(AdcRange::Bipolar10V), dev, "RNG4");

    std::printf("SDKOUT stream 2 s\n");
    std::atomic<int> nCb{0};
    double sumV3 = 0, sumV4 = 0, sumV5 = 0;
    dev.setFrameCallback([&](const Frame& f) {
        ++nCb;
        sumV3 += f.v3Volts();
        sumV4 += f.v4Volts();
        sumV5 += f.v5Volts();
    });
    if (check(dev.startStream(), dev, "SDKOUT")) {
        std::this_thread::sleep_for(std::chrono::seconds(2));
        check(dev.stopStream(), dev, "stop");
        const int n = nCb.load();
        std::printf("  frames: %d (callback)  rate ~%.0f /s  crc errors: %llu\n", n,
                    n / 2.0, static_cast<unsigned long long>(dev.crcErrors()));
        Frame f;
        if (dev.latestFrame(f) && n > 0) {
            std::printf("  osc1: X %+.6f V  Y %+.6f V  R %.6f Vpk  phase %+.2f deg\n",
                        f.osc1XVolts(), f.osc1YVolts(), f.osc1RVolts(), f.osc1PhaseDeg());
            std::printf("  V3/V4/V5 mean: %+.4f / %+.4f / %+.4f V  (last raw %d/%d/%d)\n",
                        sumV3 / n, sumV4 / n, sumV5 / n, f.v3, f.v4, f.v5);
            // 电压换算请用 f.v3Volts(dev.adcRangeV3()) 等
            std::printf("  sample_cnt %u  frame_seq %u\n", f.sampleCount, f.frameSeq);
        }
    }
    dev.setFrameCallback(nullptr);
    dev.close();
    std::printf("done\n");
    return 0;
}
