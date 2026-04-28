# Native DRAM backends (C-6).
#
# This CMake project optionally pulls in Ramulator2 and/or DRAMSim3 via
# FetchContent and exposes a thin C wrapper that the Python BFM in
# sim/memory/dram_bfm.py loads through CFFI. Both options are OFF by
# default — public CI exercises only the Python ``simple`` backend, which
# requires no native build.
#
# Enable a backend by configuring with:
#
#   cmake -S sim/memory -B build/memory -DOPENGPU_RAMULATOR2=ON
#   cmake -S sim/memory -B build/memory -DOPENGPU_DRAMSIM3=ON
#
# The resulting shared libraries are written to ``build/memory/`` and
# wrapped by future ``opengpu_ramulator2`` / ``opengpu_dramsim3`` Python
# modules (out-of-tree; not part of this CMake project today).

cmake_minimum_required(VERSION 3.20)
project(opengpu_memory C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(OPENGPU_RAMULATOR2
       "Build the Ramulator2 backend for the DRAM BFM" OFF)
option(OPENGPU_DRAMSIM3
       "Build the DRAMSim3 backend for the DRAM BFM" OFF)

if(OPENGPU_RAMULATOR2)
    include(FetchContent)
    FetchContent_Declare(ramulator2
        GIT_REPOSITORY https://github.com/CMU-SAFARI/ramulator2.git
        GIT_TAG        main)
    FetchContent_MakeAvailable(ramulator2)
    add_library(opengpu_ramulator2 SHARED src/ramulator2_shim.cc)
    target_link_libraries(opengpu_ramulator2 PRIVATE ramulator)
    target_compile_definitions(opengpu_ramulator2 PRIVATE OPENGPU_HAVE_RAMULATOR2=1)
endif()

if(OPENGPU_DRAMSIM3)
    include(FetchContent)
    FetchContent_Declare(dramsim3
        GIT_REPOSITORY https://github.com/umd-memsys/DRAMsim3.git
        GIT_TAG        master)
    FetchContent_MakeAvailable(dramsim3)
    add_library(opengpu_dramsim3 SHARED src/dramsim3_shim.cc)
    target_link_libraries(opengpu_dramsim3 PRIVATE dramsim3)
    target_compile_definitions(opengpu_dramsim3 PRIVATE OPENGPU_HAVE_DRAMSIM3=1)
endif()

# When both are off this project is a no-op marker; CMake won't error.
if(NOT OPENGPU_RAMULATOR2 AND NOT OPENGPU_DRAMSIM3)
    message(STATUS "opengpu_memory: no native backends enabled (simple only)")
endif()
