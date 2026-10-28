// SDK 自测: 配合 tests/fake_fpga.py 使用
//   python tests/fake_fpga.py COM2 30     (另一个终端)
//   sdk_selftest COM1
// 校验命令编码 / 应答处理 / 帧与示波器包解析 / CRC 重发; 失败返回非 0
#include <lockin/lockin_sdk.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <thread>

using namespace lockin;

static int g_fail = 0;

#define EXPECT(cond)                                                       \
    do {                                                                   \
        if (cond) {                                                        \
            std::printf("  ok   %s\n", #cond);                             \
        } else {                                                           \
            std::printf("  FAIL %s  (line %d)\n", #cond, __LINE__);         \
            ++g_fail;                                                      \
        }                                                                  \
    } while (0)

static bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

int main(int argc, char** argv) {
    const std::string port = argc > 1 ? argv[1] : "COM1";
    LockinDevice dev;

    std::printf("[open]\n");
    EXPECT(dev.open(port));
    if (!dev.isOpen()) {
        std::printf("open failed: %s\n", dev.lastError().c_str());
        return 1;
    }

    std::printf("[conversions]\n");
    EXPECT(hzToFreqWord(160000.0) == 692861481134ull);
    EXPECT(near(freqWordToHz(hzToFreqWord(12345.678)), 12345.678, 1e-6));
    EXPECT(near(tauToCutoffHz(10), 155.5, 0.5));

    std::printf("[argument checks]\n");
    EXPECT(!dev.setOscFrequency(0, 1000.0));
    EXPECT(!dev.setOscFrequency(8, 1000.0));
    EXPECT(!dev.setOscFrequency(1, 40e6));
    EXPECT(!dev.setOscTimeConstant(1, 32));
    EXPECT(!dev.setOscFilterOrder(2, 5));
    EXPECT(!dev.setOscHarmonic(1, 0));
    EXPECT(!dev.setDacAmplitude(3.5));
    EXPECT(!dev.setDacOffset(-3.1));

    std::printf("[command error reply]\n");
    EXPECT(!dev.sendCommand("BOGUS:1"));
    EXPECT(dev.lastError().find("Command Error") != std::string::npos);

    std::printf("[oscillators]\n");
    EXPECT(dev.setRefMode(RefMode::Manual));
    EXPECT(dev.setOscFrequency(1, 12345.678));
    EXPECT(dev.setOscHarmonic(1, 3));
    EXPECT(dev.setOscFrequency(2, 20000.0));
    EXPECT(dev.setOscHarmonic(2, 1));
    EXPECT(dev.setOscCoefficients(2, 1, 2));
    EXPECT(dev.setOscInput(2, OscInput::CH3_minus_CH4));
    EXPECT(dev.setOscTimeConstant(2, 20));
    EXPECT(dev.setOscFilterOrder(2, 4));
    EXPECT(dev.setOscFrequency(7, 1000.0));

    std::printf("[dac]\n");
    EXPECT(dev.setDacSource(2));
    EXPECT(dev.setDacWaveform(DacWave::Square));
    EXPECT(dev.setDacAmplitude(1.0));
    EXPECT(dev.setDacOffset(-1.5));

    std::printf("[stream]\n");
    std::atomic<int> nCb{0};
    std::atomic<uint32_t> lastSeq{0};
    std::atomic<int> seqBack{0};
    dev.setFrameCallback([&](const Frame& f) {
        if (f.frameSeq <= lastSeq.load()) ++seqBack;
        lastSeq = f.frameSeq;
        ++nCb;
    });
    EXPECT(dev.startStream());
    EXPECT(dev.isStreaming());
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    EXPECT(dev.setDacAmplitude(2.0));       // 流模式下发命令
    EXPECT(dev.setOscHarmonic(2, 2));
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    Frame f;
    EXPECT(dev.latestFrame(f));
    EXPECT(dev.stopStream());
    EXPECT(!dev.isStreaming());
    std::printf("  frames via callback: %d\n", nCb.load());
    EXPECT(nCb.load() > 200);
    EXPECT(seqBack.load() == 0);
    EXPECT(f.ch1X == 1 && f.ch1Y == -2 && f.ch2X == 3 && f.ch2Y == -4);
    EXPECT(f.oscX[0] == 1000 && f.oscY[0] == -500);
    EXPECT(f.oscX[6] == 7000 && f.oscY[6] == -3500);
    EXPECT(f.ch3Dc == -12345);
    EXPECT(f.adc[0] == 11 && f.adc[1] == 22 && f.adc[2] == 33);
    EXPECT(f.lockFlags == 3 && f.ch1Locked() && f.ch2Locked());
    EXPECT(near(f.pllHz(1), 1000.0, 1e-3) && near(f.pllHz(2), 2000.0, 1e-3));
    EXPECT(near(f.oscRefHz(1), 12345.678 * 3, 1e-3));
    EXPECT(near(f.oscRefHz(2), 40000.0, 1e-3));
    EXPECT(near(f.oscRefHz(7), 1000.0, 1e-3));
    EXPECT(near(f.oscRVolts(1), std::hypot(1000.0, 500.0) * voltsPerLsb(), 1e-15));
    EXPECT(near(f.oscPhaseDeg(1), std::atan2(-500.0, 1000.0) * 180.0 / 3.14159265358979, 1e-9));
    dev.setFrameCallback(nullptr);

    std::printf("[scope: first packet has bad CRC -> SDK re-arms]\n");
    ScopeData sd;
    ScopeConfig cfg;
    auto t0 = std::chrono::steady_clock::now();
    EXPECT(dev.captureScope(sd, cfg, 5000));
    double el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    std::printf("  took %.2f s\n", el);
    EXPECT(el > 0.9);
    EXPECT(sd.n == 1024 && sd.pre == 128 && sd.decimation == 0);
    EXPECT(sd.trigger == ScopeTrigger::Free && !sd.forced);
    EXPECT(sd.v5Raw.size() == 1024 && sd.v6Raw.size() == 1024);
    bool wave = true;
    for (int i = 0; i < 1024; ++i)
        wave = wave && sd.v5Raw[i] == i - 512 && sd.v6Raw[i] == 1000 - 2 * i;
    EXPECT(wave);
    EXPECT(near(sd.v5[0], -512 * 10.0 / 32768, 1e-12));
    EXPECT(near(sd.dt, 1e-6, 1e-15) && sd.timeAt(128) == 0.0 && near(sd.timeAt(0), -128e-6, 1e-15));

    std::printf("[scope: V5 rising, decim 9, level 1.0 V]\n");
    cfg.decimation = 9;
    cfg.trigger = ScopeTrigger::V5Rising;
    cfg.levelVolts = 1.0;
    t0 = std::chrono::steady_clock::now();
    EXPECT(dev.captureScope(sd, cfg, 3000));
    el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    std::printf("  took %.3f s\n", el);
    EXPECT(el < 0.5);
    EXPECT(sd.decimation == 9 && sd.trigger == ScopeTrigger::V5Rising && sd.forced);
    EXPECT(near(sd.dt, 10e-6, 1e-15));

    std::printf("[scope: async armScope + callback, V6 falling normal mode]\n");
    std::atomic<int> nScope{0};
    std::atomic<int> lastTrig{-1};
    dev.setScopeCallback([&](const ScopeData& s) {
        lastTrig = static_cast<int>(s.trigger);
        ++nScope;
    });
    cfg.decimation = 0;
    cfg.trigger = ScopeTrigger::V6Falling;
    cfg.levelVolts = -2.5;
    cfg.normalMode = true;
    EXPECT(dev.armScope(cfg));
    for (int i = 0; i < 100 && nScope.load() == 0; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    EXPECT(nScope.load() == 1 && lastTrig.load() == 4);
    dev.setScopeCallback(nullptr);

    std::printf("[stats]\n");
    std::printf("  frames %llu  scopes %llu  crc errors %llu\n",
                (unsigned long long)dev.framesReceived(), (unsigned long long)dev.scopesReceived(),
                (unsigned long long)dev.crcErrors());
    EXPECT(dev.scopesReceived() == 3);
    EXPECT(dev.crcErrors() >= 1);

    std::printf("[callback may not send commands]\n");
    std::atomic<int> cbResult{-1};
    dev.setScopeCallback([&](const ScopeData&) { cbResult = dev.sendCommand("SDEC:0") ? 1 : 0; });
    cfg = ScopeConfig();
    EXPECT(dev.armScope(cfg));
    for (int i = 0; i < 100 && cbResult.load() < 0; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    EXPECT(cbResult.load() == 0);
    dev.setScopeCallback(nullptr);

    dev.close();
    EXPECT(!dev.isOpen());
    EXPECT(!dev.setDacAmplitude(1.0));

    std::printf("\n%s (%d failures)\n", g_fail ? "SELFTEST FAILED" : "SELFTEST PASSED", g_fail);
    return g_fail ? 1 : 0;
}
