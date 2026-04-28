cmake_minimum_required(VERSION 3.20)
project(opengpu_cppref CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

option(OPENGPU_REFSIM_TESTS  "Build refsim Catch2 tests" ON)
option(OPENGPU_REFSIM_WERROR "Treat warnings as errors"  ON)
option(OPENGPU_REFSIM_COVERAGE "Build with gcov coverage instrumentation" OFF)

add_library(opengpu_warnings INTERFACE)
target_compile_options(opengpu_warnings INTERFACE
    -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wnon-virtual-dtor
    -Wold-style-cast -Woverloaded-virtual -Wnull-dereference -Wdouble-promotion
    -Wformat=2)
if(OPENGPU_REFSIM_WERROR)
    target_compile_options(opengpu_warnings INTERFACE -Werror)
endif()
if(OPENGPU_REFSIM_COVERAGE)
    # gcov-compatible instrumentation; works with both gcc and clang via
    # --coverage. lcov/gcovr post-process the produced .gcda/.gcno pairs.
    target_compile_options(opengpu_warnings INTERFACE --coverage -O0 -g)
    target_link_options   (opengpu_warnings INTERFACE --coverage)
endif()

add_library(opengpu_refsim STATIC
    src/memory.cpp
    src/thread.cpp
    src/core.cpp
    src/loader.cpp
    src/trace.cpp)
target_include_directories(opengpu_refsim
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_link_libraries(opengpu_refsim PRIVATE opengpu_warnings)

add_executable(opengpu-refsim src/main.cpp)
target_link_libraries(opengpu-refsim PRIVATE opengpu_refsim opengpu_warnings)

if(OPENGPU_REFSIM_TESTS)
    include(FetchContent)
    FetchContent_Declare(Catch2
        GIT_REPOSITORY https://github.com/catchorg/Catch2.git
        GIT_TAG v3.6.0)
    FetchContent_MakeAvailable(Catch2)

    enable_testing()
    add_executable(refsim_tests
        tests/test_decode.cpp
        tests/test_alu.cpp
        tests/test_kernel.cpp)
    target_link_libraries(refsim_tests PRIVATE
        opengpu_refsim Catch2::Catch2WithMain opengpu_warnings)
    include(Catch)
    catch_discover_tests(refsim_tests)
endif()
