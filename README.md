miscfifo — misc character device (kfifo)
========================================

Out-of-tree Linux kernel module that implements a misc device at `/dev/miscfifo0` backed by a bounded `kfifo`. Read and write operations are protected by a mutex. Blocking uses `wait_event_interruptible` and `wake_up_interruptible`. Read/write with `O_NONBLOCK` set on the file results in `-EAGAIN` when the FIFO would block (empty on read, full on write). The device represents a byte-stream interface. Hence, `llseek` is wired to `no_llseek`.

What it demonstrates
--------------------
- miscdevice registration
- `kfifo` and module parameter for buffer size at `insmod`
- concurrency: mutex, wait queues, non-blocking path
- out-of-tree kbuild (Makefile)

Requirements (typical Debian/Ubuntu)
------------------------------------
- `build-essential` (or your distro’s gcc/make)
- kernel headers for the kernel you boot:

    ```bash
    sudo apt install linux-headers-$(uname -r)
    ```

- Root for loading the module and running `test.sh`

Build
-----
```bash
make
```

Produces `miscfifo.ko` in this directory.

```bash
make clean
```

Remove build products.

Module parameter
----------------
- `buffer_size` - FIFO size in bytes at `insmod` only (`module_param` is `0444`).
  Default `1024`, maximum `1 MiB`.

Examples:

```bash
sudo insmod ./miscfifo.ko
sudo insmod ./miscfifo.ko buffer_size=4096
```

Load / unload
-------------
Load the module, confirm `/dev/miscfifo0` exists (mode `0666` in this driver), then remove it:

```bash
sudo insmod ./miscfifo.ko
ls -l /dev/miscfifo0
sudo rmmod miscfifo
```

Tests
-----
Black-box script. Must run after `make` and as root (`insmod`/`rmmod`).

```bash
chmod +x test.sh
sudo ./test.sh
```
The test reloads the module with `buffer_size=64` for several cases, verifies write/read behavior, blocking read and blocking write behavior, and a non-blocking read on an empty FIFO, then unloads the module.

Cross-compilation (e.g. Jetson / arm64)
---------------------------------------
Use a `KDIR` that points to a kernel build tree matching the target kernel.

```bash
sudo apt install gcc-aarch64-linux-gnu

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  KDIR=/path/to/your/target/kernel/source
```

Layout
------
```text
miscfifo.c   - module source
Makefile     — kbuild wrapper
test.sh      — automated tests
README.md    — this file
```