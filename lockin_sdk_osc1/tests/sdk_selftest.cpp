// 配合 fake_fpga.py 的自测: 配置 osc1/DAC → SDKOUT → 校验帧字段与速率
#include <lockin_osc1/lockin_sdk.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>

using namespace lockin_osc1;

static int g_fail = 0;
#define EXPECT(cond) do { \
    if (!(cond)) { std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); ++g_fail; } \
} while (0)

int main(int argc, char** argv) {
    const char* port = argc > 1 ? argv[1] : "";
    LockinDevice dev;
    if (!dev.open(port)) {
        std::printf("open failed: %s\n", dev.lastError().c_str());
        std::printf("(start: python tests/fake_fpga.py COMx)\n");
        return 2;
    }
    std::printf("open %s\n", dev.portName().c_str());

    EXPECT(dev.setRefMode(RefMode::Manual));
    EXPECT(dev.setOsc1Frequency(12345.0));
    EXPECT(dev.setOsc1Harmonic(2));
    EXPECT(dev.setOsc1Coefficients(1, 0));
    EXPECT(dev.setOsc1Input(OscInput::CH3));
    EXPECT(dev.setOsc1TimeConstant(10));
    EXPECT(dev.setOsc1FilterOrder(3));
    EXPECT(dev.setDacSourceOsc1());
    EXPECT(dev.setDacWaveform(DacWave::Sine));
    EXPECT(dev.setDacAmplitude(1.5));
    EXPECT(dev.setDacOffset(0.0));
    EXPECT(!dev.sendCommand("BOGUS:1"));

    std::atomic<int> n{0};
    uint32_t lastSeq = 0;
    int seqOk = 0;
    dev.setFrameCallback([&](const Frame& f) {
        if (n.load() > 0 && f.frameSeq == lastSeq + 1) ++seqOk;
        lastSeq = f.frameSeq;
        ++n;
    });
    EXPECT(dev.startStream());
    std::this_thread::sleep_for(std::chrono::milliseconds(800));
    EXPECT(dev.stopStream());

    const int got = n.load();
    std::printf("frames=%d seq_steps=%d crc_err=%llu\n", got, seqOk,
                static_cast<unsigned long long>(dev.crcErrors()));
    EXPECT(got > 200);           // ~2 kHz * 0.8s, 宽松下限
    EXPECT(seqOk > got / 2);

    Frame f;
    EXPECT(dev.latestFrame(f));
    EXPECT(f.osc1X != 0 || f.osc1Y != 0);
    std::printf("last: X=%d Y=%d V3=%d V4=%d V5=%d seq=%u\n",
                f.osc1X, f.osc1Y, f.v3, f.v4, f.v5, f.frameSeq);

    // 回调里禁止发命令
    std::atomic<int> cbResult{-1};
    dev.setFrameCallback([&](const Frame&) {
        cbResult = dev.sendCommand("TAU21:1") ? 1 : 0;
    });
    EXPECT(dev.startStream());
    for (int i = 0; i < 50 && cbResult.load() < 0; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    EXPECT(cbResult.load() == 0);
    EXPECT(dev.stopStream());
    dev.setFrameCallback(nullptr);

    dev.close();
    if (g_fail) {
        std::printf("%d FAILED\n", g_fail);
        return 1;
    }
    std::printf("ALL PASS\n");
    return 0;
}
