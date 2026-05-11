#!/usr/bin/env bash
# Black-box tests for miscfifo. Run: sudo ./test.sh (after make)

DEV=/dev/miscfifo0
MOD=miscfifo
TMPDIR=$(mktemp -d)

cleanup() {
    rmmod "$MOD" 2>/dev/null || true
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

PASS=0
FAIL=0

# Colored PASS/FAIL when stdout is a TTY; plain text when piped or redirected.
if [[ -t 1 ]]; then
    _G=$'\033[32m'
    _R=$'\033[31m'
    _N=$'\033[0m'
else
    _G= _R= _N=
fi
pass() { echo "${_G}PASS:${_N} $1"; PASS=$((PASS + 1)); }
fail() { echo "${_R}FAIL:${_N} $1"; FAIL=$((FAIL + 1)); }

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo ./test.sh"; exit 1; }
[[ -f ./miscfifo.ko ]] || { echo "miscfifo.ko not found. Run 'make' first."; exit 1; }

reload() {
    rmmod "$MOD" 2>/dev/null || true
    insmod ./miscfifo.ko "$@" || { echo "insmod failed"; exit 1; }
    [[ -c $DEV ]] || { echo "device node $DEV missing after insmod"; exit 1; }
}

# -----------------------------------------------------------------------------
# Test 1 — Load miscfifo.ko; misc_register must create $DEV as a character device.
# -----------------------------------------------------------------------------
echo "=== Test 1: insmod + $DEV is a char device ==="
reload buffer_size=64
pass "module loaded, $DEV is a char device"

# -----------------------------------------------------------------------------
# Test 2 — Push bytes into the kfifo and read the same payload back (basic I/O).
# -----------------------------------------------------------------------------
echo "=== Test 2: write/read round-trip ==="
echo "hello" > "$DEV"
OUT=$(timeout 1 cat "$DEV")
[[ "$OUT" == "hello" ]] && pass "write/read 'hello'" || fail "expected 'hello', got '$OUT'"

# -----------------------------------------------------------------------------
# Test 3 — Reader blocks on empty FIFO; write wakes miscfifo_read_wq; output matches write.
# -----------------------------------------------------------------------------
echo "=== Test 3: blocking read wakes on write ==="
reload buffer_size=64

timeout 3 cat "$DEV" > "$TMPDIR/out" &
READER_PID=$!
sleep 0.3

if kill -0 "$READER_PID" 2>/dev/null; then
    echo "world" > "$DEV"
    wait "$READER_PID" || true
    OUT=$(cat "$TMPDIR/out")
    [[ "$OUT" == "world" ]] && pass "blocking read unblocks on write" || fail "expected 'world', got '$OUT'"
else
    fail "reader exited before write — not blocking"
    wait "$READER_PID" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Test 4 — Fill FIFO to capacity; extra write blocks; draining FIFO wakes miscfifo_write_wq.
# -----------------------------------------------------------------------------
echo "=== Test 4: blocking write wakes on read (drain) ==="
reload buffer_size=64
head -c 64 /dev/urandom > "$DEV"

( timeout 3 sh -c "head -c 32 /dev/urandom > $DEV" ) &
WRITER_PID=$!
sleep 0.3

if kill -0 "$WRITER_PID" 2>/dev/null; then
    dd if="$DEV" of=/dev/null bs=64 count=1 2>/dev/null
    wait "$WRITER_PID" && pass "blocking write unblocks on read" || fail "writer did not complete after drain"
else
    fail "writer exited before drain — not blocking"
    wait "$WRITER_PID" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Test 5 — Non-blocking read on empty buffer returns EAGAIN (dd stderr shows typical glibc text).
# -----------------------------------------------------------------------------
echo "=== Test 5: O_NONBLOCK empty read -> EAGAIN ==="
reload buffer_size=64

timeout 2 dd if="$DEV" of=/dev/null bs=1 count=1 iflag=nonblock 2>"$TMPDIR/err" || true

if grep -qi "resource temporarily unavailable" "$TMPDIR/err"; then
    pass "non-blocking read returned EAGAIN"
else
    fail "expected EAGAIN message; got: $(cat "$TMPDIR/err")"
fi

# -----------------------------------------------------------------------------
# Test 6 — rmmod runs module exit; misc_deregister should remove $DEV from the filesystem.
# -----------------------------------------------------------------------------
echo "=== Test 6: rmmod + device node gone ==="
if rmmod "$MOD"; then
    [[ ! -e $DEV ]] && pass "module unloaded, $DEV removed" || fail "$DEV persisted after rmmod"
else
    fail "rmmod failed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]