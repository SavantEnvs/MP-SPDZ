#!/usr/bin/env bash
#
# mayhem/build.sh — build MP-SPDZ's fuzz harnesses and the oracle's test build.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — a sanitized libSPDZ object set linked into one libFuzzer binary
# (and one -standalone reproducer) per harness, plus the project's own emulator built with NORMAL flags
# for the functional oracle that mayhem/test.sh runs. Upstream is not edited: the tree is copied into
# gitignored build dirs under mayhem/ (the upstream Makefile only builds in-tree) and `make` runs there.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS


: "${SRC:=/mayhem}"
cd "$SRC"

# Fixed instruction-set flags (not -march=native: the image builds on one host, runs on another).
ARCH_FLAGS="-mavx2 -msse4.2 -maes -mpclmul -mbmi2 -madx"
# alignment: Tools/avx_memcpy.h deliberately does unaligned __m128i* loads/stores (benign on x86); every
# decode_length() in the network layer trips it. All other UBSan checks stay on and halting.
RELAX_UBSAN="-fno-sanitize=alignment"
LIBS="-lgmpxx -lgmp -lsodium -lssl -lcrypto -lboost_filesystem -lboost_iostreams"
TARGETS="fuzz_program_parse fuzz_gc_program_parse fuzz_octetstream"
ASAN_DIR="$SRC/mayhem/build-asan"
TEST_DIR="$SRC/mayhem/build-test"

copy_tree() {
  rm -rf "$1" && mkdir -p "$1"
  tar -C "$SRC" --exclude=./.git --exclude=./mayhem -cf - . | tar -C "$1" -xf -
}

# AVX_OT=0 pins the (host-cpuinfo dependent) CONFIG probe; the OT/libOTe submodules are never needed.
MAKE_VARS=(AVX_OT=0 ERROR= GDEBUG= ARCH="$ARCH_FLAGS")

# 1) The project: the object set of libSPDZ.so, sanitized, DWARF 3 (paths mapped back to /mayhem), with
#    SanCov (-fsanitize=fuzzer-no-link, unconditional) so the parsers/deserialisers give coverage feedback.
copy_tree "$ASAN_DIR"
make -C "$ASAN_DIR" -j"$MAYHEM_JOBS" libSPDZ.so "${MAKE_VARS[@]}" OPTIM=-O1 \
  MY_CFLAGS="$SANITIZER_FLAGS $RELAX_UBSAN $DEBUG_FLAGS -fsanitize=fuzzer-no-link -fdebug-prefix-map=$ASAN_DIR=$SRC"
OBJS=$(make -s -C "$ASAN_DIR" "${MAKE_VARS[@]}" \
  --eval='print-objs: ; @echo $(PROCESSOR) $(COMMONOBJS) GC/square64.o GC/Instruction.o' print-objs)

CXXFLAGS_H="-std=c++20 -DUSE_GF2N_LONG -DNO_AVX_OT -DPREP_DIR=\"Player-Data/\" -DSSL_DIR=\"Player-Data/\" \
  -I$ASAN_DIR -I$ASAN_DIR/deps -I$ASAN_DIR/local/include -pthread -fPIC -O1 -Wno-overloaded-virtual $ARCH_FLAGS \
  -fdebug-prefix-map=$ASAN_DIR=$SRC"
OBJ_PATHS=$(for o in $OBJS; do echo "$ASAN_DIR/$o"; done | sort -u)

# 2) Harnesses: fuzzer + standalone reproducer, each with the LSan-off hook.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o mayhem/build-asan/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o mayhem/build-asan/standalone_main.o
for t in $TARGETS; do
  $CXX $SANITIZER_FLAGS $RELAX_UBSAN $DEBUG_FLAGS $CXXFLAGS_H $LIB_FUZZING_ENGINE mayhem/$t.cpp \
    $OBJ_PATHS mayhem/build-asan/lsan_off.o $LIBS -o "/mayhem/$t"
  $CXX $SANITIZER_FLAGS $RELAX_UBSAN $DEBUG_FLAGS $CXXFLAGS_H mayhem/$t.cpp mayhem/build-asan/standalone_main.o \
    $OBJ_PATHS mayhem/build-asan/lsan_off.o $LIBS -o "/mayhem/$t-standalone"
done

# 3) The functional oracle: upstream's own emulator and Python compiler, NORMAL flags, no sanitizers.
copy_tree "$TEST_DIR"
make -C "$TEST_DIR" -j"$MAYHEM_JOBS" emulate.x "${MAKE_VARS[@]}" OPTIM=-O2 \
  MY_CFLAGS="-DFEWER_RINGS $COVERAGE_FLAGS"
cp mayhem/oracle.mpc "$TEST_DIR/Programs/Source/mayhem_oracle.mpc"
(cd "$TEST_DIR" && python3 compile.py -R 64 mayhem_oracle >/dev/null && Scripts/setup-ssl.sh 1 >/dev/null 2>&1)
test -s "$TEST_DIR/Programs/Schedules/mayhem_oracle.sch"
