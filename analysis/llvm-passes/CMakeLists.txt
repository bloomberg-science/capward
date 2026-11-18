# Copyright 2026 Bloomberg Finance L.P.
# Distributed under the terms of the MIT license.

cmake_minimum_required(VERSION 3.13)
project(LLVMPasses LANGUAGES C CXX)

# Find *any* installed LLVM; select version by setting LLVM_DIR at configure time.
#   cmake -DLLVM_DIR=/path/to/llvm/lib/cmake/llvm -S . -B build
find_package(LLVM REQUIRED CONFIG)
message(STATUS "Found LLVM ${LLVM_PACKAGE_VERSION}")
message(STATUS "Using LLVMConfig.cmake in: ${LLVM_DIR}")

# Extract major version (e.g. "16" from "16.0.6")
string(REGEX MATCH "^[0-9]+" LLVM_VERSION_MAJOR "${LLVM_PACKAGE_VERSION}")

# Choose a standard compatible with the found LLVM
if (LLVM_VERSION_MAJOR GREATER_EQUAL 15)
  set(CMAKE_CXX_STANDARD 17)
else()
  set(CMAKE_CXX_STANDARD 14)
endif()
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Build a loadable plugin (PIC is implied for MODULE on most toolchains, but keep it explicit)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Use LLVM's include dirs and common compiler defs
include_directories(${LLVM_INCLUDE_DIRS})
add_definitions(${LLVM_DEFINITIONS})

# The two passes CAPWARD's pipeline invokes:
#   CrossCompartmentTypeAnalyzer  - emits per-library type usage manifests
#   SealInstrumentationPass       - inserts CHERI seal/unseal at compartment boundaries
#
# On Morello, pipeline/build/passes/build_passes_morello.sh compiles
# these directly instead of going through cmake, because the Morello LLVM cmake
# config references missing static libraries.
set(CAPWARD_PASSES
  CrossCompartmentTypeAnalyzer
  SealInstrumentationPass
)

foreach(PASS ${CAPWARD_PASSES})
  add_library(${PASS} MODULE ${PASS}.cpp)

  # Match LLVM's RTTI / EH settings to avoid ODR/typeinfo issues
  if(DEFINED LLVM_ENABLE_RTTI AND NOT LLVM_ENABLE_RTTI)
    target_compile_options(${PASS} PRIVATE -fno-rtti)
  endif()
  if(DEFINED LLVM_ENABLE_EH AND NOT LLVM_ENABLE_EH)
    target_compile_options(${PASS} PRIVATE -fno-exceptions)
  endif()

  # Place the plugins where it's easy to -load-pass-plugin
  set_target_properties(${PASS} PROPERTIES
    OUTPUT_NAME "${PASS}"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    PREFIX "lib"         # lib${PASS}.so / .dylib / .dll
  )

  if(APPLE)
    target_link_options(${PASS} PRIVATE -Wl,-dead_strip)
  endif()
  if(WIN32)
    target_compile_definitions(${PASS} PRIVATE _CRT_SECURE_NO_WARNINGS)
  endif()

  install(TARGETS ${PASS}
          LIBRARY DESTINATION lib
          RUNTIME DESTINATION bin
          ARCHIVE DESTINATION lib)
endforeach()
