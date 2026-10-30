cmake_minimum_required(VERSION 3.14)
project(lockin_sdk_osc1 VERSION 1.0.0 LANGUAGES CXX)

option(LOCKIN_OSC1_BUILD_SHARED   "Build as DLL" OFF)
option(LOCKIN_OSC1_BUILD_EXAMPLES "Build examples" ON)

if(NOT WIN32)
    message(FATAL_ERROR "lockin_sdk_osc1 currently supports Windows only (Win32 serial API)")
endif()

set(LOCKIN_OSC1_SOURCES
    src/lockin_sdk.cpp
    src/serial_port_win.cpp
)

if(LOCKIN_OSC1_BUILD_SHARED)
    add_library(lockin_sdk_osc1 SHARED ${LOCKIN_OSC1_SOURCES})
    target_compile_definitions(lockin_sdk_osc1 PUBLIC LOCKIN_OSC1_SHARED PRIVATE LOCKIN_OSC1_EXPORTS)
else()
    add_library(lockin_sdk_osc1 STATIC ${LOCKIN_OSC1_SOURCES})
endif()
add_library(lockin_osc1::sdk ALIAS lockin_sdk_osc1)

target_compile_features(lockin_sdk_osc1 PUBLIC cxx_std_17)
target_include_directories(lockin_sdk_osc1 PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)
target_link_libraries(lockin_sdk_osc1 PRIVATE setupapi)
if(MSVC)
    target_compile_options(lockin_sdk_osc1 PRIVATE /utf-8 /W4)
else()
    target_compile_options(lockin_sdk_osc1 PRIVATE -Wall -Wextra)
    find_package(Threads REQUIRED)
    target_link_libraries(lockin_sdk_osc1 PUBLIC Threads::Threads)
endif()

if(LOCKIN_OSC1_BUILD_EXAMPLES)
    add_executable(lockin_osc1_demo examples/demo.cpp)
    target_link_libraries(lockin_osc1_demo PRIVATE lockin_sdk_osc1)
    if(MSVC)
        target_compile_options(lockin_osc1_demo PRIVATE /utf-8)
    endif()

    add_executable(sdk_osc1_selftest tests/sdk_selftest.cpp)
    target_link_libraries(sdk_osc1_selftest PRIVATE lockin_sdk_osc1)
endif()

install(TARGETS lockin_sdk_osc1 ARCHIVE DESTINATION lib LIBRARY DESTINATION lib RUNTIME DESTINATION bin)
install(DIRECTORY include/ DESTINATION include)
