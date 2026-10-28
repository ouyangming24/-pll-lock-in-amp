#include "serial_port.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <setupapi.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <cwchar>

#ifdef _MSC_VER
#pragma comment(lib, "setupapi.lib")
#endif

namespace lockin {
namespace detail {

namespace {

// GUID_DEVCLASS_PORTS; MinGW 的导入库里没有, 自己定义
const GUID kGuidDevClassPorts = {0x4D36E978, 0xE325, 0x11CE, {0xBF, 0xC1, 0x08, 0x00, 0x2B, 0xE1, 0x03, 0x18}};

std::string wideToUtf8(const wchar_t* w) {
    if (!w || !*w) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) return std::string();
    std::string s(static_cast<size_t>(n - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
    return s;
}

std::string lastWinError() {
    DWORD code = GetLastError();
    wchar_t* msg = nullptr;
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                       FORMAT_MESSAGE_IGNORE_INSERTS,
                   nullptr, code, MAKELANGID(LANG_ENGLISH, SUBLANG_DEFAULT),
                   reinterpret_cast<wchar_t*>(&msg), 0, nullptr);
    std::string s = "win32 error " + std::to_string(code);
    if (msg) {
        std::string m = wideToUtf8(msg);
        while (!m.empty() && (m.back() == '\n' || m.back() == '\r' || m.back() == ' '))
            m.pop_back();
        if (!m.empty()) s += ": " + m;
        LocalFree(msg);
    }
    return s;
}

int portNumber(const std::string& name) {
    size_t i = 0;
    while (i < name.size() && !(name[i] >= '0' && name[i] <= '9')) ++i;
    return i < name.size() ? std::atoi(name.c_str() + i) : 0;
}

}  // namespace

SerialPort::~SerialPort() { close(); }

bool SerialPort::open(const std::string& port, uint32_t baud, int readTimeoutMs,
                      std::string& err) {
    close();
    // COM10 以上必须用 \\.\COMxx 形式, 统一加前缀
    std::string path = port.rfind("\\\\.\\", 0) == 0 ? port : "\\\\.\\" + port;
    HANDLE h = CreateFileA(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                           OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        err = "open " + port + " failed (" + lastWinError() + ")";
        return false;
    }

    SetupComm(h, 1 << 16, 1 << 12);

    DCB dcb;
    std::memset(&dcb, 0, sizeof(dcb));
    dcb.DCBlength = sizeof(dcb);
    if (!GetCommState(h, &dcb)) {
        err = "GetCommState failed (" + lastWinError() + ")";
        CloseHandle(h);
        return false;
    }
    dcb.BaudRate = baud;
    dcb.ByteSize = 8;
    dcb.Parity = NOPARITY;
    dcb.StopBits = ONESTOPBIT;
    dcb.fBinary = TRUE;
    dcb.fParity = FALSE;
    dcb.fOutxCtsFlow = FALSE;
    dcb.fOutxDsrFlow = FALSE;
    dcb.fDtrControl = DTR_CONTROL_ENABLE;
    dcb.fDsrSensitivity = FALSE;
    dcb.fOutX = FALSE;
    dcb.fInX = FALSE;
    dcb.fErrorChar = FALSE;
    dcb.fNull = FALSE;
    dcb.fRtsControl = RTS_CONTROL_ENABLE;
    dcb.fAbortOnError = FALSE;
    if (!SetCommState(h, &dcb)) {
        err = "SetCommState failed, baud " + std::to_string(baud) + " (" + lastWinError() + ")";
        CloseHandle(h);
        return false;
    }

    // 有数据立即返回, 无数据最多等 readTimeoutMs
    COMMTIMEOUTS to;
    to.ReadIntervalTimeout = MAXDWORD;
    to.ReadTotalTimeoutMultiplier = MAXDWORD;
    to.ReadTotalTimeoutConstant = static_cast<DWORD>(std::max(1, readTimeoutMs));
    to.WriteTotalTimeoutMultiplier = 0;
    to.WriteTotalTimeoutConstant = 1000;
    if (!SetCommTimeouts(h, &to)) {
        err = "SetCommTimeouts failed (" + lastWinError() + ")";
        CloseHandle(h);
        return false;
    }

    PurgeComm(h, PURGE_RXCLEAR | PURGE_TXCLEAR | PURGE_RXABORT | PURGE_TXABORT);
    rdEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    wrEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!rdEvent_ || !wrEvent_) {
        err = "CreateEvent failed (" + lastWinError() + ")";
        CloseHandle(h);
        close();
        return false;
    }
    handle_ = h;
    return true;
}

void SerialPort::close() {
    if (handle_) {
        CancelIoEx(static_cast<HANDLE>(handle_), nullptr);
        CloseHandle(static_cast<HANDLE>(handle_));
        handle_ = nullptr;
    }
    if (rdEvent_) { CloseHandle(static_cast<HANDLE>(rdEvent_)); rdEvent_ = nullptr; }
    if (wrEvent_) { CloseHandle(static_cast<HANDLE>(wrEvent_)); wrEvent_ = nullptr; }
}

bool SerialPort::isOpen() const { return handle_ != nullptr; }

int SerialPort::read(uint8_t* buf, size_t maxLen) {
    if (!handle_) return -1;
    HANDLE h = static_cast<HANDLE>(handle_);
    OVERLAPPED ov;
    std::memset(&ov, 0, sizeof(ov));
    ov.hEvent = static_cast<HANDLE>(rdEvent_);
    ResetEvent(ov.hEvent);
    DWORD got = 0;
    BOOL ok = ReadFile(h, buf, static_cast<DWORD>(maxLen), &got, &ov);
    if (!ok && GetLastError() == ERROR_IO_PENDING)
        ok = GetOverlappedResult(h, &ov, &got, TRUE);   // COMMTIMEOUTS 保证按时返回
    if (!ok) {
        DWORD errs = 0;
        COMSTAT st;
        // 帧错误 / 溢出等线路错误会让 ReadFile 失败, 清掉后继续
        if (ClearCommError(h, &errs, &st)) return 0;
        return -1;
    }
    return static_cast<int>(got);
}

bool SerialPort::write(const void* data, size_t len) {
    if (!handle_) return false;
    HANDLE h = static_cast<HANDLE>(handle_);
    const uint8_t* p = static_cast<const uint8_t*>(data);
    while (len > 0) {
        OVERLAPPED ov;
        std::memset(&ov, 0, sizeof(ov));
        ov.hEvent = static_cast<HANDLE>(wrEvent_);
        ResetEvent(ov.hEvent);
        DWORD put = 0;
        BOOL ok = WriteFile(h, p, static_cast<DWORD>(len), &put, &ov);
        if (!ok && GetLastError() == ERROR_IO_PENDING)
            ok = GetOverlappedResult(h, &ov, &put, TRUE);
        if (!ok || put == 0) return false;
        p += put;
        len -= put;
    }
    return true;
}

void SerialPort::purge() {
    if (handle_) PurgeComm(static_cast<HANDLE>(handle_), PURGE_RXCLEAR | PURGE_TXCLEAR);
}

std::vector<PortInfo> SerialPort::enumerate() {
    std::vector<PortInfo> out;
    HDEVINFO devs = SetupDiGetClassDevsW(&kGuidDevClassPorts, nullptr, nullptr, DIGCF_PRESENT);
    if (devs == INVALID_HANDLE_VALUE) return out;

    SP_DEVINFO_DATA info;
    info.cbSize = sizeof(info);
    for (DWORD i = 0; SetupDiEnumDeviceInfo(devs, i, &info); ++i) {
        wchar_t portName[64] = {0};
        HKEY key = SetupDiOpenDevRegKey(devs, &info, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_READ);
        if (key == INVALID_HANDLE_VALUE) continue;
        DWORD type = 0, size = sizeof(portName) - sizeof(wchar_t);
        LONG rc = RegQueryValueExW(key, L"PortName", nullptr, &type,
                                   reinterpret_cast<BYTE*>(portName), &size);
        RegCloseKey(key);
        if (rc != ERROR_SUCCESS || type != REG_SZ || std::wcsncmp(portName, L"COM", 3) != 0)
            continue;

        wchar_t friendly[256] = {0};
        SetupDiGetDeviceRegistryPropertyW(devs, &info, SPDRP_FRIENDLYNAME, nullptr,
                                          reinterpret_cast<BYTE*>(friendly),
                                          sizeof(friendly) - sizeof(wchar_t), nullptr);
        wchar_t hwid[512] = {0};
        SetupDiGetDeviceRegistryPropertyW(devs, &info, SPDRP_HARDWAREID, nullptr,
                                          reinterpret_cast<BYTE*>(hwid),
                                          sizeof(hwid) - sizeof(wchar_t), nullptr);

        PortInfo p;
        p.name = wideToUtf8(portName);
        p.description = friendly[0] ? wideToUtf8(friendly) : p.name;
        std::string id = wideToUtf8(hwid), desc = p.description;
        auto upper = [](std::string& s) {
            for (char& c : s) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
        };
        upper(id);
        upper(desc);
        p.isCh340 = id.find("VID_1A86") != std::string::npos ||
                    desc.find("CH340") != std::string::npos;
        out.push_back(p);
    }
    SetupDiDestroyDeviceInfoList(devs);

    std::sort(out.begin(), out.end(), [](const PortInfo& a, const PortInfo& b) {
        if (a.isCh340 != b.isCh340) return a.isCh340;
        return portNumber(a.name) < portNumber(b.name);
    });
    return out;
}

}  // namespace detail
}  // namespace lockin
