#!/bin/bash
# ZLMod — artifact verification gates. Fails the build on any violation.
set -euo pipefail

DYLIB="${1:-build/libZLMod.dylib}"
FAIL=0

fail() { echo "GATE FAIL: $1"; FAIL=1; }
pass() { echo "GATE OK:   $1"; }

[ -f "$DYLIB" ] || { fail "missing $DYLIB"; exit 1; }

# 1. Architecture — arm64 thin, dynamic library.
if file "$DYLIB" | grep -q "Mach-O 64-bit dynamically linked shared library arm64"; then
  pass "arm64 dylib"
else
  fail "not an arm64 dynamically linked shared library"
fi

# 2. Dependencies — system frameworks + executable-relative path only. No substrate, no ellekit.
DEPS=$(otool -L "$DYLIB" | tail -n +2 | awk '{print $1}')
UNEXPECTED=$(echo "$DEPS" | grep -Ev '^(/System/Library/|/usr/lib/|@executable_path/|@rpath/|@loader_path/)' || true)
if [ -n "$UNEXPECTED" ]; then
  fail "unexpected dependency: $(echo "$UNEXPECTED" | head -1)"
else
  pass "dependencies clean"
fi

if echo "$DEPS" | grep -qiE 'substrate|ellekit|cydia'; then
  fail "hook-injection library linked"
else
  pass "no substrate/ellekit"
fi

# 3. Install name.
if otool -D "$DYLIB" 2>/dev/null | tail -n +2 | grep -q "@rpath/libZLMod.dylib"; then
  pass "install_name @rpath/libZLMod.dylib"
else
  fail "install_name missing or wrong"
fi

# 4. Platform + deployment target.
LC_BUILD=$(otool -l "$DYLIB" | grep -A10 LC_BUILD_VERSION || true)
if echo "$LC_BUILD" | grep -q "minos 15.1"; then
  pass "minos 15.1"
else
  fail "minos is not 15.1"
fi

if echo "$LC_BUILD" | grep -qiE "platform (2|IOS)"; then
  pass "platform iOS"
else
  fail "platform is not iOS"
fi

# 5. No strong reference to iOS 26-only classes (must be runtime-guarded via NSClassFromString).
if nm -m "$DYLIB" 2>/dev/null | grep "undefined" | grep -q "_OBJC_CLASS_\$_UIGlassEffect"; then
  fail "strong undefined reference to UIGlassEffect (use NSClassFromString)"
else
  pass "UIGlassEffect runtime-guarded"
fi

# 6. Signature present.
if codesign -dv "$DYLIB" 2>&1 | grep -q "Identifier="; then
  pass "codesigned"
else
  fail "not codesigned"
fi

# 7. Non-empty, real content.
SIZE=$(stat -f%z "$DYLIB" 2>/dev/null || stat -c%s "$DYLIB" 2>/dev/null || echo 0)
if [ "$SIZE" -gt 20000 ]; then
  pass "artifact size ${SIZE}B"
else
  fail "artifact suspiciously small (${SIZE}B)"
fi

exit $FAIL
