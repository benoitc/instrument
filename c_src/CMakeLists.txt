cmake_minimum_required(VERSION 3.18 FATAL_ERROR)

project(InstrumentNIF C)

# CMake policies
if(POLICY CMP0028)
  cmake_policy(SET CMP0028 NEW)
endif()
if(POLICY CMP0054)
  cmake_policy(SET CMP0054 NEW)
endif()
if(POLICY CMP0074)
  cmake_policy(SET CMP0074 NEW)
endif()

list(APPEND CMAKE_MODULE_PATH "${PROJECT_SOURCE_DIR}/CMake")

# Output directory
set(priv_dir "${PROJECT_SOURCE_DIR}/../priv")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${priv_dir})
file(MAKE_DIRECTORY ${priv_dir})

# Build type
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# C11 standard
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Sanitizer options for debugging
option(ENABLE_ASAN "Enable AddressSanitizer" OFF)
option(ENABLE_TSAN "Enable ThreadSanitizer" OFF)
option(ENABLE_UBSAN "Enable UndefinedBehaviorSanitizer" OFF)

if(ENABLE_ASAN)
    message(STATUS "AddressSanitizer enabled")
    add_compile_options(-fsanitize=address -fno-omit-frame-pointer -g -O1)
    add_link_options(-fsanitize=address)
    if(ENABLE_TSAN)
        message(FATAL_ERROR "ASan and TSan cannot be used together")
    endif()
endif()

if(ENABLE_TSAN)
    message(STATUS "ThreadSanitizer enabled")
    add_compile_options(-fsanitize=thread -fno-omit-frame-pointer -g -O1)
    add_link_options(-fsanitize=thread)
endif()

if(ENABLE_UBSAN)
    message(STATUS "UndefinedBehaviorSanitizer enabled")
    add_compile_options(-fsanitize=undefined -fno-omit-frame-pointer -g -O1)
    add_link_options(-fsanitize=undefined)
endif()

# Find Erlang
include(FindErlang)
include_directories(${ERLANG_ERTS_INCLUDE_PATH})

# NIF library
add_library(instrument_nif MODULE
    instrument_nif.c
    gauge.c
)

# Set output name
set_target_properties(instrument_nif PROPERTIES
    PREFIX ""
    OUTPUT_NAME "instrument_nif"
)

# Include directories
target_include_directories(instrument_nif PRIVATE
    ${ERLANG_ERTS_INCLUDE_PATH}
)

# Compiler flags
target_compile_options(instrument_nif PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -fPIC
)

# Platform-specific settings
if(APPLE)
    target_link_options(instrument_nif PRIVATE
        -undefined dynamic_lookup
        -flat_namespace
    )
elseif(CMAKE_SYSTEM_NAME STREQUAL "FreeBSD" OR
       CMAKE_SYSTEM_NAME STREQUAL "NetBSD" OR
       CMAKE_SYSTEM_NAME STREQUAL "OpenBSD")
    target_link_options(instrument_nif PRIVATE
        -Wl,--export-dynamic
    )
elseif(UNIX)
    target_link_options(instrument_nif PRIVATE
        -Wl,--export-dynamic
    )
endif()

message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "Output directory: ${CMAKE_LIBRARY_OUTPUT_DIRECTORY}")
