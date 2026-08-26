# GPUDirect TCP

**NIC-to-GPU DMA for a fully GPU-resident TCP/IP stack.**

`gdrtcp` lets a NIC DMA incoming packets straight into GPU VRAM and runs the entire
TCP/IP stack in CUDA device code, so a GPU workload can talk to a remote TCP peer with
the CPU off the data path.

Normally a GPU-bound network workload keeps the CPU on the critical path: packets DMA
into system RAM, the kernel runs TCP/IP, and the data is then copied to the GPU. That
costs extra copies, memory bandwidth, cache pollution and CPU time. GPUDirect TCP
removes those steps.

It has two halves:

- **A modified `e1000e` kernel module** that programs the NIC's receive descriptors with
  DMA addresses inside GPU memory (via GPUDirect RDMA), and redirects packets that
  belong to host applications back into the kernel networking stack.
- **A CUDA library** exposing socket-like primitives callable from device code, backed by
  a persistent TCP/IP kernel.

Built as a course project for Linux Kernel Programming (CS730/CS730A), IIT Kanpur.
See [`report.pdf`](report.pdf) for the full design, and [`SETUP.md`](SETUP.md) to build
and reproduce the benchmarks.

## Results

Tested on Linux 6.1.4 with an Intel I219-LM (`e1000e`), an Intel I210 (`igb`) and an
NVIDIA Quadro P620. Line rate for this setup is 949 Mbps (1460 MSS / 1538 frame).

| | Baseline (CPU TCP) | GPU TCP stack | Redirect stress |
|---|---|---|---|
| Throughput | line rate | line rate | line rate |
| RTT | 2100 µs | 2800 µs | 2000–5000 µs |
| Total CPU | 25% | 33% | 102% |
| ksoftirq CPU | 0% | 0% | 0% |

Correctness was checked with position-weighted checksums over 32 GB of randomised data.

The headline result is feasibility, not speedup: at 1 Gbps the NIC is the bottleneck, so
the baseline already saturates the wire and there is no headroom for the GPU path to win
in. What the benchmarks do show is that kernel network processing leaves the CPU entirely
(`ksoftirq` at 0% throughout), and that the CPU time which remains is spent in the
userspace relay — a workaround forced by not being able to modify the proprietary GPU
driver, not by TCP processing. With a driver that can DMA directly into kernel memory the
relay disappears; see §IX.D of the report.

## Design

The report covers four parts:

1. **NIC to GPU DMA** — packet memory (`PMEM`) is pinned in VRAM and exposed over PCI
   BARs with `nvidia_p2p_get_pages`; `e1000_alloc_rx_buffers` is rewritten to hand those
   DMA addresses to the NIC. Completions are published to the GPU through a lock-free
   SPSC ring in a second GPU region (`CMEM`).
2. **Packet redirection from GPU to CPU** — traffic belonging to host applications is
   pushed to a redirect ring, copied back to kernel memory by a userspace relay using
   batched `cudaMemcpyAsync`, and reinjected inside the NAPI poll callback.
3. **Transmitting from the GPU** — the GPU builds complete IPv4 packets and posts
   descriptors to a TX ring; the relay sends them via raw sockets.
4. **The GPU TCP/IP stack** — a persistent kernel with a receive warp that processes 32
   packets in parallel and a serial send thread, plus a zero-copy device-side API
   (`recv_slice` / `recv_release`, `send_reserve` / `send_complete`) that hands callers
   pointers directly into the socket ring buffers.

## Known limitations

- Concurrent kernel launch does not work: the user kernel is never scheduled while the
  persistent TCP/IP kernel runs (reproduced on a Quadro P620 and an RTX 3050). Worked
  around by launching both as separate thread blocks of one kernel.
- Multiple simultaneous GPU connections are designed for but not functional — the
  submission and completion queues are SPSC in practice.
- No congestion control, and no path MTU discovery (fixed 536-byte payloads).
- Overlapping TCP segments are not handled; stale out-of-order segments are dropped.
- The PCI ordering race between the NIC's Descriptor Done bit and the DMA write to GPU
  memory is mitigated with a magic value the GPU spins on, not eliminated.

## Layout

| Path | Contents |
|---|---|
| `e1000e/` | The three files to drop into the kernel source tree |
| `e1000e_complete/` | Full `e1000e` driver including our modifications |
| `e1000e.patch` | The same changes as a patch |
| `gdrtcp/main/` | CUDA library |
| `gdrtcp/benchmarks/` | Benchmark clients and the common TCP server |
| `gdrtcp/data/` | Captured CSVs and plotting scripts |
| `scripts/` | Build and network-namespace helpers |

## Authors

Ashish Ahuja, Aujasvit Datta, Darshan Dinesh Sethia, Divyansh Garg and Ritvik Goyal —
equal contribution.

## Licence

The `e1000e` driver code is a derivative of the Linux kernel driver and remains
GPL-2.0; see [`LICENSE`](LICENSE). `nv-p2p.h` is redistributed from NVIDIA's driver
package and is covered by NVIDIA's own licence terms — prefer the copy shipped with your
driver version.

AI tools were used to generate plotting code and scripts. Portions of `helpers.cuh`
(byte-order conversion, TCP/IP checksum calculation, and unpacked header conversions)
are adapted from external sources; everything else was written by the authors.
