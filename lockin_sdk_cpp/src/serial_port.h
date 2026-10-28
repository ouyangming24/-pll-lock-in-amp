// 串口薄封装 (内部使用). 目前只实现 Win32.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "lockin/lockin_sdk.h"

namespace lockin {
namespace detail {

class SerialPort {
public:
    SerialPort() = default;
    ~SerialPort();
    SerialPort(const SerialPort&) = delete;
    SerialPort& operator=(const SerialPort&) = delete;

    // 8N1, 无流控; 读超时 readTimeoutMs (有数据立即返回)
    bool open(const std::string& port, uint32_t baud, int readTimeoutMs, std::string& err);
    void close();
    bool isOpen() const;

    // 返回读到的字节数, 超时返回 0, 出错返回 -1
    int  read(uint8_t* buf, size_t maxLen);
    bool write(const void* data, size_t len);
    void purge();

    static std::vector<PortInfo> enumerate();

private:
    // 读写在不同线程并发, 必须用重叠 I/O (同步句柄上 ReadFile 会阻塞 WriteFile)
    void* handle_  = nullptr;
    void* rdEvent_ = nullptr;
    void* wrEvent_ = nullptr;
};

}  // namespace detail
}  // namespace lockin
