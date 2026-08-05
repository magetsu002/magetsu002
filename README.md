# Aster Kernel v0.5.1 — real IPv4 networking

> **Project status:** experimental educational kernel. Aster runs entirely in ring 0 and is not suitable for real hardware or production use.

Aster is a clean-room educational x86-64 kernel written in freestanding C and assembly. It does not copy Linux source and is not Linux-compatible yet.

## What v0.5 adds

- Legacy PCI configuration-space enumeration
- Realtek RTL8139 PCI Ethernet driver using port I/O and bus-master DMA
- Polling receive ring and four transmit descriptors
- Ethernet II frame transmission and reception
- ARP requests, replies, and a small ARP cache
- Static IPv4 configuration for QEMU user-mode networking
- IPv4 header construction, routing, and checksums
- UDP transmission and reception
- DNS A-record queries through QEMU's DNS proxy
- Real ICMP echo requests and replies
- PIT-calibrated TSC timing for millisecond ping results
- `net` / `ifconfig` interface dashboard
- `ping google.com`, `ping 1.1.1.1`, and other IPv4 hosts
- The original `ping aster` ring-0 self-test remains available

The QEMU profile is:

```text
NIC       RTL8139
MAC       52:54:00:12:34:56
IPv4      10.0.2.15/24
Gateway   10.0.2.2
DNS       10.0.2.3
Backend   QEMU user-mode NAT
```

This is a deliberately small polling stack. It does not yet include DHCP, TCP, sockets, IPv6, fragmentation, or NIC interrupts.

## Repository layout

```text
arch/x86_64/    bootstrap, IDT, and interrupt stubs
include/aster/  kernel interfaces
kernel/         console, shell, timing, PCI, NIC, and network stack
grub/           Multiboot2 boot menu
scripts/        QEMU launcher and build validation
docs/           development roadmap
```

## Current limitations

- single-core and polling-based;
- no userspace, processes, scheduler, or syscall ABI;
- no virtual filesystem or persistent storage;
- static QEMU IPv4 configuration;
- no TCP, DHCP, IPv6, fragmentation, or NIC interrupts;
- intended for QEMU's RTL8139 device, not arbitrary physical hardware.

## Arch Linux / CachyOS dependencies

```bash
sudo pacman -S --needed \
  base-devel clang lld \
  qemu-system-x86 qemu-ui-gtk \
  grub xorriso mtools unzip patch
```

`qemu-ui-sdl` can replace `qemu-ui-gtk`.

## Build and run

```bash
make clean check
make run
```

For a terminal-only session:

```bash
make run-headless
```

The launch script explicitly attaches an RTL8139 card to QEMU's user-mode network backend. Click inside the QEMU window before typing, or type directly in the host terminal in headless mode.

## Try the network

```text
net
ping google.com
ping 1.1.1.1
ping 8.8.8.8
ping aster
```

`ping google.com` performs all of these inside Aster:

1. ARP resolution for the QEMU DNS proxy.
2. A UDP DNS query for an IPv4 A record.
3. ARP resolution for the default gateway.
4. Four genuine ICMP echo requests.
5. ICMP reply parsing and RTT calculation.

## Shell commands

```text
help          Show the command index
clear         Clear and redraw the console
about         Describe the kernel
sysinfo       Show CPU, RAM, addresses, and subsystem status
cpu           Read the CPU vendor through CPUID
mem           Show usable Multiboot2 memory
net           Show NIC, MAC, IPv4, gateway, DNS, and stack status
ifconfig      Alias for net
ping HOST     Resolve and ping a hostname or IPv4 address
echo TEXT     Print text through VGA and COM1
color NAME    Change the prompt accent color
demo          Draw a VGA color demonstration
banner        Redraw the console banner
uname         Print the kernel version
whoami        Print the current ring-0 identity
pwd           Print the current pseudo-path
reboot        Reset through the 8042 controller
halt          Halt the virtual CPU
```

Aster's terminal is still a kernel monitor. Every command executes directly in ring 0; there is no userspace, scheduler, VFS, or process isolation yet.

## Network troubleshooting

If the interface is missing, use the supplied `make run` or `make run-headless` target rather than launching QEMU manually. The `net` command should show `Realtek RTL8139` and `10.0.2.15/24`.

If DNS succeeds but all external ICMP requests time out, inspect the host setting:

```bash
cat /proc/sys/net/ipv4/ping_group_range
```

For a local development machine, a temporary permissive setting is:

```bash
sudo sysctl -w net.ipv4.ping_group_range='0 2147483647'
```

Then restart QEMU and retry.

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the longer architecture plan.

## v0.5.1 CPU-state fix

The long-mode bootstrap now enables x87/SSE state before entering C. This fixes `CPU exception 6` during `net_init()` when Clang vectorizes a memory-clear loop into `xorps`/`movaps`. The kernel also initializes MXCSR to the architectural default (`0x1F80`) before any optimized C code runs.
