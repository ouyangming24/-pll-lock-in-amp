#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "lockin_osc1/lockin_sdk.h"

namespace lockin_osc1 {
namespace detail {

class SerialPort {
public:
    SerialPort() = default;
    ~SerialPort();
    SerialPort(const SerialPort&) = delete;
    SerialPort& operator=(const SerialPort&) = delete;

    bool open(const std::string& port, uint32_t baud, int readTimeoutMs, std::string& err);
    void close();
    bool isOpen() const;

    int  read(uint8_t* buf, size_t maxLen);
    bool write(const void* data, size_t len);
    void purge();

    static std::vector<PortInfo> enumerate();

private:
    void* handle_  = nullptr;
    void* rdEvent_ = nullptr;
    void* wrEvent_ = nullptr;
};

}  // namespace detail
}  // namespace lockin_osc1
