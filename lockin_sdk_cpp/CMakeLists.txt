cmake_minimum_required(VERSION 3.14)
project(lockin_sdk VERSION 1.0.0 LANGUAGES CXX)

option(LOCKIN_BUILD_SHARED   "Build lockin_sdk as a DLL" OFF)
option(LOCKIN_BUILD_EXAMPLES "Build example programs"   ON)

if(NOT WIN32)
    message(FATAL_ERROR "lockin_sdk currently supports Windows only (Win32 serial API)")
endif()

set(LOCKIN_SOURCES
    src/lockin_sdk.cpp
    src/serial_port_win.cpp
)

if(LOCKIN_BUILD_SHARED)
    add_library(lockin_sdk SHARED ${LOCKIN_SOURCES})
    target_compile_definitions(lockin_sdk PUBLIC LOCKIN_SDK_SHARED PRIVATE LOCKIN_SDK_EXPORTS)
else()
    add_library(lockin_sdk STATIC ${LOCKIN_SOURCES})
endif()
add_library(lockin::sdk ALIAS lockin_sdk)

target_compile_features(lockin_sdk PUBLIC cxx_std_17)
target_include_directories(lockin_sdk PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)
target_link_libraries(lockin_sdk PRIVATE setupapi)
if(MSVC)
    target_compile_options(lockin_sdk PRIVATE /utf-8 /W4)
else()
    target_compile_options(lockin_sdk PRIVATE -Wall -Wextra)
    find_package(Threads REQUIRED)
    target_link_libraries(lockin_sdk PUBLIC Threads::Threads)
endif()

if(LOCKIN_BUILD_EXAMPLES)
    add_executable(lockin_demo examples/demo.cpp)
    target_link_libraries(lockin_demo PRIVATE lockin_sdk)
    if(MSVC)
        target_compile_options(lockin_demo PRIVATE /utf-8)
    endif()

    add_executable(sdk_selftest tests/sdk_selftest.cpp)
    target_link_libraries(sdk_selftest PRIVATE lockin_sdk)
endif()

install(TARGETS lockin_sdk ARCHIVE DESTINATION lib LIBRARY DESTINATION lib RUNTIME DESTINATION bin)
install(DIRECTORY include/ DESTINATION include)
