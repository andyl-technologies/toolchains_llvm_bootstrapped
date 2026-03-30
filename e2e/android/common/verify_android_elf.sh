#!/bin/sh
# Verify a cross-compiled binary is a correctly linked Android ELF.
# Usage: verify_android_elf.sh <binary> <arch> <type>
#   arch: aarch64 | x86_64
#   type: executable | shared
set -eu

binary="$1"
expected_arch="$2"
binary_type="$3"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

echo "=== Verifying: $binary (arch=$expected_arch, type=$binary_type) ==="

# 1. Check it's an ELF for the expected architecture
file_output="$(file -L "$binary")"
echo "file: $file_output"

case "$expected_arch" in
    aarch64) echo "$file_output" | grep -q "ARM aarch64" || fail "expected ARM aarch64" ;;
    x86_64)  echo "$file_output" | grep -q "x86-64"      || fail "expected x86-64" ;;
    *)       fail "unknown arch $expected_arch" ;;
esac

# 2. Check binary type
case "$binary_type" in
    executable) echo "$file_output" | grep -q "executable" || fail "expected executable" ;;
    shared)     echo "$file_output" | grep -q "shared object" || fail "expected shared object" ;;
esac

# 3. Check it targets Android (not glibc Linux)
# Executables should use Android's dynamic linker, not glibc's ld-linux.
if [ "$binary_type" = "executable" ]; then
    echo "$file_output" | grep -q '/system/bin/linker' \
        || fail "expected Android interpreter (/system/bin/linker*), not glibc"
fi

# Ensure no glibc ld-linux reference.
if echo "$file_output" | grep -q 'ld-linux'; then
    fail "references glibc ld-linux interpreter"
fi

echo ""
echo "PASS: $binary is a valid Android $expected_arch $binary_type"
