#!/usr/bin/env bash
# Builds, inside the commit image as `mayhem` in /mayhem:
#   1) libpistache.a with ASan+UBSan (halting), SanCov and DWARF-3 -> build-fuzz/
#   2) the fuzz harness tests/fuzzers/fuzz_parser.cpp (upstream's own OSS-Fuzz harness) as
#      /mayhem/fuzz_parsers (libFuzzer) and /mayhem/fuzz_parsers-standalone (run-once reproducer)
#   3) the project's gtest suite with NORMAL flags -> build-tests/ (mayhem/test.sh only runs it)
# All dependencies come from apt packages baked into the image, so a re-run needs no network.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# SanCov on the library even when SANITIZER_FLAGS is empty, else the target records 0 edges in Mayhem.
FUZZ_CXXFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"

# 1) sanitized, instrumented library
cmake -S . -B build-fuzz -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$FUZZ_CXXFLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_CXXFLAGS" \
  -DBUILD_SHARED_LIBS=OFF -DPISTACHE_BUILD_TESTS=OFF -DPISTACHE_USE_SSL=OFF
cmake --build build-fuzz --target pistache_static -j"$MAYHEM_JOBS"

# 2) harness, twice (libFuzzer + standalone reproducer), each with the LSan-off hook
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build-fuzz/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-fuzz/standalone_main.o
$CXX $FUZZ_CXXFLAGS -std=c++17 -Iinclude -Ibuild-fuzz/include -c tests/fuzzers/fuzz_parser.cpp -o build-fuzz/fuzz_parser.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE build-fuzz/fuzz_parser.o build-fuzz/lsan_off.o \
  build-fuzz/src/libpistache.a -pthread -o /mayhem/fuzz_parsers
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS build-fuzz/fuzz_parser.o build-fuzz/standalone_main.o build-fuzz/lsan_off.o \
  build-fuzz/src/libpistache.a -pthread -o /mayhem/fuzz_parsers-standalone

# 3) the project's own gtest suite, NORMAL flags (no sanitizers, no -gdwarf-3)
cmake -S . -B build-tests -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DBUILD_SHARED_LIBS=OFF -DPISTACHE_BUILD_TESTS=ON -DPISTACHE_USE_SSL=OFF
cmake --build build-tests -j"$MAYHEM_JOBS"
