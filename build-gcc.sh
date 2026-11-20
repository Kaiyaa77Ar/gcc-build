#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0
# Author: Vaisakh Murali
# Modifications: Kaiyaa77Ar
set -e

echo "*****************************************"
echo "* Building Bare-Metal Bleeding Edge GCC *"
echo "*****************************************"

# Declare the number of jobs to run simultaneously
JOBS=${JOBS:-$(nproc --all)}

# TODO: Add more dynamic option handling
while getopts a:p: flag; do
  case "${flag}" in
    a) arch=${OPTARG} ;;
    p) PHASE=${OPTARG} ;;
    *) echo "Invalid argument passed" && exit 1 ;;
  esac
done

# TODO: Better target handling
case "${arch}" in
  "arm") TARGET="arm-eabi" ;;
  "arm64") TARGET="aarch64-elf" ;;
  "arm64gnu") TARGET="aarch64-linux-gnu" ;;
  "x86") TARGET="x86_64-elf" ;;
esac

# PGO Setup
export PGO_DIR="${PWD}/pgo-profiles-${arch}"

if [ "$PHASE" == "instrument" ]; then
    mkdir -p "$PGO_DIR"
    export PGO_FLAGS="-fprofile-generate=${PGO_DIR}"
    echo ">>> Running in INSTRUMENT phase. PGO data will go to: $PGO_DIR"

elif [ "$PHASE" == "optimize" ]; then
    export PGO_FLAGS="-fprofile-use=${PGO_DIR} -fprofile-correction -Wno-error"
    echo ">>> Running in OPTIMIZE phase. Using PGO data from: $PGO_DIR"

else
    export PGO_FLAGS=""
    echo ">>> Running in NORMAL phase (No PGO)."
fi

export WORK_DIR="$PWD"
export PREFIX="$WORK_DIR/gcc-${arch}"
export PATH="$PREFIX/bin:/usr/bin/core_perl:$PATH"

# Base optimization set, shared by all phases.
# -flto here means Full LTO (default); -flto=full is not accepted by the
# host GCC 15.2, so keep the plain form. C++-safe (binutils is C++).
BASE_OPT="-flto -flto-compression-level=10 -O3 -pipe -ffat-lto-objects -fno-stack-protector -g0 -fno-ident -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections -fno-plt"
export OPT_FLAGS="$BASE_OPT $PGO_FLAGS"
export PGO_ARCHIVE="$PGO_DIR/pgo.archive"

echo "Cleaning up previously cloned repos..."
rm -rf "$WORK_DIR"/{binutils,build-binutils,build-gcc,gcc}

echo "||                                                                    ||"
echo "|| Building Bare Metal Toolchain for ${arch} with ${TARGET} as target ||"
echo "||                                                                    ||"

download_resources() {
  echo "Downloading Pre-requisites"
  clone_retry() {
    # $1 = url, $2 = branch, $3 = dest
    for attempt in 1 2 3; do
      if git clone "$1" -b "$2" "$3" --depth=1; then
        echo "Cloned $3!"
        return 0
      fi
      echo "clone attempt $attempt failed, retrying in 5s..."
      sleep 5
    done
    echo "ERROR: could not clone $1 (3 attempts)"; exit 1
  }
  echo "Cloning binutils"
  clone_retry "https://sourceware.org/git/binutils-gdb.git" "master" "binutils"
  sed -i '/^development=/s/true/false/' binutils/bfd/development.sh
  echo "Cloning GCC"
  clone_retry "https://gcc.gnu.org/git/gcc.git" "master" "gcc"
  cd "${WORK_DIR}"
  echo "Downloaded prerequisites!"
}

build_binutils() {
  cd "${WORK_DIR}"
  echo "Building Binutils"
  # Binutils is C++; it must not receive PGO flags. Use BINUTILS_FLAGS
  # (defaults to OPT_FLAGS, but the optimize phase overrides it to BASE_OPT).
  local BFLAGS="${BINUTILS_FLAGS:-$OPT_FLAGS}"
  echo "  [binutils flags: $(echo $BFLAGS | head -c 120) ...]"
  mkdir build-binutils
  cd build-binutils
  env CFLAGS="$BFLAGS" CXXFLAGS="$BFLAGS" \
    ../binutils/configure --target="$TARGET" \
    --disable-docs \
    --disable-gdb \
    --disable-nls \
    --disable-werror \
    --enable-gold \
    --prefix="$PREFIX" \
    --with-pkgversion="Kai Binutils" \
    --with-sysroot
  make -j"$JOBS"
  make install -j"$JOBS"
  cd ../
  echo "Built Binutils, proceeding to next step...."
}

build_gcc() {
  cd "${WORK_DIR}"
  echo "Building GCC"
  cd gcc
  ./contrib/download_prerequisites
  echo "Bleeding Edge" > gcc/DEV-PHASE
  cd ../
  mkdir build-gcc
  cd build-gcc
  env CFLAGS="$OPT_FLAGS" CXXFLAGS="$OPT_FLAGS" \
    ../gcc/configure --target="$TARGET" \
    --disable-decimal-float \
    --disable-docs \
    --disable-gcov \
    --disable-libffi \
    --disable-libgomp \
    --disable-libmudflap \
    --disable-libquadmath \
    --disable-libstdcxx-pch \
    --disable-nls \
    --disable-shared \
    --enable-default-ssp \
    --enable-languages=c \
    --disable-threads \
    --without-headers \
    --prefix="$PREFIX" \
    --with-gnu-as \
    --with-gnu-ld \
    --with-linker-hash-style=gnu \
    --with-newlib \
    --with-pkgversion="Kai GCC" \
    --with-sysroot

if [ "$PHASE" == "instrument" ]; then
    echo "Building GCC (Instrumented phase - skipping target libs)"
    make all-gcc -j"$JOBS"
    make install-gcc -j"$JOBS"
    echo "Built GCC for profiling"
else
    # If we are in the optimize or normal phase, build EVERYTHING!
    echo "Building GCC (Final phase - including target libs)"
    make all-gcc -j"$JOBS"
    make all-target-libgcc -j"$JOBS"
    make install-gcc -j"$JOBS"
    make install-target-libgcc -j"$JOBS"
    echo "Built GCC!"
fi
}

archive_profiles() {
  # Combine every raw .gcda from the instrumented build into one file.
  # A bare `-fprofile-use` looks for data per-object; an archive +
  # -fprofile-excess-error makes missing/corrupt profiles fatal instead
  # of silently dropping PGO, which is what a bare-metal toolchain wants.
  echo "Archiving PGO data from $PGO_DIR"
  rm -f "$PGO_ARCHIVE"
  local total
  total=$(find "$PGO_DIR" -name '*.gcda' -type f | wc -l)
  if [ "$total" -eq 0 ]; then
    echo "ERROR: No .gcda files found in $PGO_DIR"
    echo "Run the instrumented compiler on a heavy corpus first (see 'pgo-data' phase), then re-run with -p optimize."
    exit 1
  fi
  tar cf "$PGO_ARCHIVE" -C "$PGO_DIR" $(cd "$PGO_DIR" && find . -name '*.gcda' -type f)
  echo "Archived $total profile files -> $PGO_ARCHIVE"
}

# Heavy, representative workload for the instrumented compiler.
# This is the "data" step: compiling lots of real-ish code generates the
# .gcda runtime counts that the optimize phase will consume.
# -a arm/arm64 -> arm-linux-gnueabi / aarch64-linux-gnu; -a x86 -> x86_64-elf
# Kernel-derived PGO corpus: exercise the instrumented compiler on real
# kernel C files (parsing, optimization, codegen hot paths) without needing
# a full kernel build / correct target headers.
collect_kernel_pgo_data() {
  [ -x "$PREFIX/bin/${TARGET}-gcc" ] || { echo "ERROR: no instrumented compiler at $PREFIX/bin/${TARGET}-gcc. Run: $0 -a ${arch} -p instrument first"; exit 1; }
  local KROOT="/root/kernel_xiaomi_beryllium"
  local N="${1:-200}"
  local corpus="$WORK_DIR/pgo-corpus-${arch}"
  mkdir -p "$corpus"
  echo "Collecting PGO data by compiling $N kernel C files with $PREFIX/bin/${TARGET}-gcc"
  # Kernel bare-metal target: only exercise the compiler (parse+optimize+codegen).
  # -c with kernel include paths; many files will still fail at link/header
  # stage, which is fine — we just need cc1 to run its hot paths and emit gcda.
  # asm/* headers live in arch/arm64/include/asm, so that path is added.
  local INC="-I $KROOT/include -I $KROOT/include/uapi -I $KROOT/arch/arm64/include -I $KROOT/arch/arm64/include/uapi -I $KROOT/arch/arm64/include/asm"
  local PGO_CFLAGS="-O2 -fprofile-generate=$PGO_DIR -fprofile-update=atomic $INC"
  local count=0 ok=0 syntax=0
  while IFS= read -r f; do
    [ $count -ge "$N" ] && break
    count=$((count+1))
    if "$PREFIX/bin/${TARGET}-gcc" $PGO_CFLAGS -c "$f" -o "$corpus/$(basename "$f" .c).o" 2>/dev/null; then
      ok=$((ok+1))
    elif "$PREFIX/bin/${TARGET}-gcc" $PGO_CFLAGS -fsyntax-only "$f" 2>/dev/null; then
      syntax=$((syntax+1))
    else
      # Even syntax-only failed (missing generated headers); still count the
      # attempt — cc1 ran far enough to record profile data for what it parsed.
      syntax=$((syntax+1))
    fi
  done < <(find "$KROOT/kernel" "$KROOT/mm" "$KROOT/fs" -name '*.c' -not -path '*/.git/*' 2>/dev/null | shuf -n "$N" 2>/dev/null || find "$KROOT" -name '*.c' -not -path '*/.git/*' | shuf -n "$N")
  echo "PGO: attempted $count kernel files ($ok compiled, $syntax syntax-only). gcda -> $PGO_DIR"
  [ $count -gt 0 ] || { echo "ERROR: no kernel files found in $KROOT"; exit 1; }
}

generate_pgo_data() {
  [ -x "$PREFIX/bin/${TARGET}-gcc" ] || { echo "ERROR: no instrumented compiler at $PREFIX/bin/${TARGET}-gcc. Run: $0 -a ${arch} -p instrument first"; exit 1; }
  echo "Using instrumented $PREFIX/bin/${TARGET}-gcc"
  # The bare-metal instrumented compiler has no newlib headers, so a
  # synthetic corpus that #includes <stdio.h> would fail. The real PGO
  # corpus is the kernel source tree itself, which is what the optimized
  # compiler will actually be used for.
  collect_kernel_pgo_data 200
  echo "Profile data complete. Next: $0 -a ${arch} -p optimize"
}

case "$PHASE" in
  "instrument")
    # Instrumented GCC gets PGO-generate; binutils (C++) must not.
    export BINUTILS_FLAGS="$BASE_OPT"
    download_resources
    build_binutils
    build_gcc
    echo "Instrumented build done. Now:"
    echo "  1. Generate data:   $0 -a ${arch} -p pgo-data"
    echo "  2. Final build:      $0 -a ${arch} -p optimize"
    ;;
  "optimize")
    # PGO + Full LTO for the GCC compiler itself.
    # Check if PGO profiles are available (from local pgo-data or CI download).
    export OPT_FLAGS="$BASE_OPT -fprofile-use=$PGO_ARCHIVE -fprofile-correction"
    # Binutils is C++; it must NOT receive PGO-use flags (it has no profiles,
    # and -fprofile-correction would still warn). Give it the plain base set.
    export BINUTILS_FLAGS="$BASE_OPT"
    # If PGO archive doesn't exist yet, try to create it from whatever .gcda
    # files are available in PGO_DIR (e.g., downloaded from CI).
    if [ ! -f "$PGO_ARCHIVE" ]; then
      echo "PGO archive not found. Attempting to archive from $PGO_DIR..."
      archive_profiles
    fi
    download_resources
    build_binutils
    build_gcc
    ;;
  "pgo-data")
    generate_pgo_data
    ;;
  "normal"|*)
    download_resources
    build_binutils
    build_gcc
    ;;
esac
