# Simplified TileLink Multi-Core Cache Coherence Hierarchy

A personal project to learn how the memory hierarchy in a modern multi-core processor works by building one from scratch in SystemVerilog: private L1 data caches, an interconnect, a shared coherent L2, and main memory. All of them talk over a simplified version of the **TileLink** protocol.

The goal is understanding, not raw performance. The design keeps the parts that make coherence hard (several caches holding the same line, permissions moving between them, dirty data being written back while other requests are in flight) and simplifies the rest.

---

## Table of Contents

1. [Block Diagram](#block-diagram)
2. [What is TileLink?](#what-is-tilelink)
3. [Why TileLink?](#why-tilelink)
4. [My Simplified TileLink](#my-simplified-tilelink)
5. [System Architecture](#system-architecture)
6. [Example Transactions](#example-transactions)
7. [Repository Layout](#repository-layout)
8. [Verification](#verification)
9. [Design Limitations](#design-limitations)

---

## Block Diagram

<!-- Block diagram to be added -->

---

## What is TileLink?

**TileLink** is an open, chip-scale interconnect standard created by SiFive and the UC Berkeley architecture group. It came out of the RISC-V ecosystem (it's used throughout Rocket Chip and many SiFive cores) and is designed for connecting processors, caches, accelerators and memories on a single chip.

TileLink defines communication between **agents**:

- A **master** (also called a *client*) starts requests, for example an L1 cache asking for a line.
- A **slave** (also called a *manager*) answers them, for example the L2 or main memory.

The same block can be both. The L2 is a slave to the L1s above it and a master to main memory below it.

### Conformance levels

TileLink has three levels, and each one adds to the one before it:

| Level | Name | What it adds |
|-------|------|--------------|
| **TL-UL** | Uncached Lightweight | Simple reads and writes (`Get`, `PutFullData`, `PutPartialData`), one beat each |
| **TL-UH** | Uncached Heavyweight | Multi-beat bursts, atomics, and prefetch hints |
| **TL-C**  | Cached | Coherence: masters can keep cached copies of data, and the slave can take permissions back |

A plain memory only needs TL-UL or TL-UH. A cache that has to stay coherent with other caches needs **TL-C**.

### The five channels

TileLink splits traffic across up to five independent channels. Each one is a separate bundle of wires with its own `valid`/`ready` handshake:

| Channel | Direction | Purpose | Messages |
|---------|-----------|---------|----------|
| **A** | master → slave | Requests | `Get`, `PutFullData`, `AcquireBlock`, `AcquirePerm` |
| **B** | slave → master | Probes (the slave asks a master to give up permissions) | `ProbeBlock`, `ProbePerm` |
| **C** | master → slave | Probe responses and voluntary writebacks | `ProbeAck`, `ProbeAckData`, `Release`, `ReleaseData` |
| **D** | slave → master | Responses | `AccessAck`, `AccessAckData`, `Grant`, `GrantData`, `ReleaseAck` |
| **E** | master → slave | Final acknowledgement of a Grant | `GrantAck` |

TL-UL and TL-UH only use channels **A** and **D**. TL-C adds **B**, **C** and **E**.

### Permissions

TL-C tracks coherence as a **permission** each master holds on each cache line. There are three levels:

| Permission | Meaning | Rough MESI equivalent |
|------------|---------|-----------------------|
| **T** (Trunk / Tip) | Read and write. This master is the only one with the line, and its copy may be dirty | M / E |
| **B** (Branch) | Read only. Other masters may also hold B | S |
| **N** (None) | No permission. The copy, if any, can't be used | I |

Every message that changes permissions carries a `param` field describing the change:

- **Grow** (on A): `NtoB`, `NtoT`, `BtoT`. What an Acquire asks for.
- **Cap** (on B and D): `toT`, `toB`, `toN`. The most a master may keep after a probe, or what a Grant gives.
- **Shrink** (on C): `TtoB`, `TtoN`, `BtoN`. A master reporting that it gave up permission.
- **Report** (on C): `TtoT`, `BtoB`, `NtoN`. A master reporting that nothing changed.

### The handshake

On every channel, the sender drives `valid` together with the message, and the receiver drives `ready`. A beat transfers on any clock edge where both are high. Once a sender raises `valid`, it has to hold `valid` and the payload steady until the beat is accepted. Multi-beat messages (anything carrying a full cache line) send one data word per beat, and their beats can't be interleaved with another message on the same channel.

---

## Why TileLink?

1. **Coherence is part of the protocol.** Many bus standards (AXI, Wishbone, APB) only describe reads and writes, and coherence is bolted on as an extension. TL-C defines permissions, probes and writebacks as first-class messages, which makes it a good vehicle for *learning* coherence.

2. **Channels are separated so the system can't deadlock.** TileLink orders the channels by priority, **A < B < C < D < E**, and requires that a message on one channel can only ever wait for messages on *higher* channels. A `Grant` (D) never waits for an `Acquire` (A), so a chain of dependencies always ends. This is a big part of why the protocol is provably deadlock-free, and the interconnect in this project is built around exactly this rule.

3. **The same interface at every level.** Agents only see TileLink messages, so a cache doesn't care whether the thing below it is another cache, an interconnect or a memory. The L1s here were developed against a behavioural L2 model, and the real L2 dropped in behind the same ports.

4. **It's open and well documented.** The spec is free, and there are real silicon implementations (Rocket Chip, SiFive cores, Chipyard) to compare against.

5. **It scales down.** Because the levels build on each other, a simple device such as the main memory here can speak only TL-UL/UH while the caches speak TL-C, all on the same message format.

---

## My Simplified TileLink

This project implements a **subset** of TL-C. Everything is defined in [`RTL/tilelink_pkg.sv`](RTL/tilelink_pkg.sv).

### Bus parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| `ADDR_WIDTH` | 16 bits | 64 KB physical address space |
| `DATA_WIDTH` | 32 bits | One 4-byte word per beat |
| `LINE_BYTES` | 16 bytes | Cache line size |
| `BEATS` | 4 | Beats per full-line transfer (16 / 4) |
| `SOURCE_WIDTH` | 2 bits | Up to 4 L1 masters (source IDs 0–3) |
| `SINK_WIDTH` | 2 bits | Grant tag echoed back on E |
| `size` | always `log2(16) = 4` | Every transfer moves exactly one whole line |

### Messages that are implemented

| Channel | Messages used | Used between |
|---------|---------------|--------------|
| A | `AcquireBlock`, `AcquirePerm` | L1 → L2 |
| A | `Get`, `PutFullData` | L2 → main memory |
| B | `ProbeBlock` | L2 → L1 |
| C | `ProbeAck`, `ProbeAckData`, `Release`, `ReleaseData` | L1 → L2 |
| D | `Grant`, `GrantData`, `ReleaseAck` | L2 → L1 |
| D | `AccessAck`, `AccessAckData` | main memory → L2 |
| E | `GrantAck` | L1 → L2 |

So the L1 ↔ L2 link is **TL-C**, and the L2 ↔ memory link is a small **TL-UH** subset (whole-line `Get` and `PutFullData` bursts only).

### What I simplified

- **Whole-line transfers only.** Every data message is a full 16-byte, 4-beat burst. There are no partial writes (`PutPartialData`), so `mask` is unused.
- **No atomics, hints or arithmetic/logical operations** (`ArithmeticData`, `LogicalData`, `Intent`).
- **No `ProbePerm`.** The L2 always sends `ProbeBlock`, so a dirty holder always returns its data.
- **`corrupt` and `denied` are always 0.** No error reporting.
- **One outstanding transaction per source.** Each L1 has a single source ID and only one Acquire in flight at a time, so `sink` isn't needed to tell Grants apart (the L2 always sends `sink = 0`).
- **Simplified Grant policy.** The L2 grants exactly what was asked for (`NtoB` → `toB`, `NtoT`/`BtoT` → `toT`). It doesn't give a lone reader T on a read (no MESI "Exclusive" state).
- **`AcquirePerm` fallback.** If an L1's `AcquirePerm` (`BtoT`) is waiting while that same L1 gets probed to N, the L2 answers with `GrantData` instead of `Grant`, because the requester no longer has valid data. The L1s accept either response.

---

## System Architecture

### CPU interface

Each L1 has a simple non-blocking CPU port (`cpu_req_t` / `cpu_resp_t` in the package):

- A request carries `valid`, `opcode` (0 = load, 1 = store), an `id`, `addr` and `st_data`.
- A response carries a one-cycle `valid` pulse, the matching `id`, and `rdata` (0 for stores).
- `stall` tells the CPU to hold its request because the request buffer is full.
- Responses can come back **out of order**, tagged by `id`. The CPU must not reuse an `id` that's still waiting for its response.
- Accesses are 32-bit words. Bits `[3:2]` of the address pick the word within the line.

### L1 data caches — [`RTL/L1D_1.sv`](RTL/L1D_1.sv), [`RTL/L1D_2.sv`](RTL/L1D_2.sv)

Two private L1 data caches, `L1_cache1` (TileLink source ID **1**) and `L1_cache2` (source ID **2**). They're written separately but behave the same.

| Property | Value |
|----------|-------|
| Size | 256 bytes (8 sets × 2 ways × 16 B) |
| Associativity | 2-way set associative |
| Replacement | Round-robin per set |
| Write policy | Write-back, write-allocate |
| Per-line state | tag, valid, dirty, permission (`N`/`B`/`T`) |

Main features:

- **Non-blocking with hit-under-miss.** A 4-entry request buffer holds requests that can't finish right away (misses, requests to a line that's busy, or requests waiting behind an older one to the same line). While a miss is outstanding, new requests to other lines can still hit.
- **Miss handling (MSHR).** One miss at a time. If the victim way holds a valid line, the cache first writes it back with `Release` (clean) or `ReleaseData` (dirty) and waits for `ReleaseAck`. Then it sends the `Acquire`, takes in the `Grant`/`GrantData` beats, sends `GrantAck` on E, and finally commits the new tag and permission.
- **Permission upgrades.** A store to a line held in B sends `AcquirePerm` (`BtoT`) instead of refetching the data.
- **Probe handling.** A separate probe FSM answers `ProbeBlock`, sending `ProbeAckData` if the line is dirty and `ProbeAck` otherwise, with the correct shrink/report `param`. Probe responses get priority over the cache's own `Release` on channel C. CPU accesses to a line being probed are held off so a store can't slip in after the probe has sampled the line.
- **Always ready on B and D**, so a probe or response can never be blocked by the cache's own pending work.

### L2 controller / interconnect — [`RTL/L2_controller.sv`](RTL/L2_controller.sv)

`l2_controller` connects up to four L1 ports (`N_L1 = 2^SOURCE_WIDTH`) to the L2's single set of channels. Port *i* belongs to the L1 whose source ID is *i*.

- **A, C, E (many L1s → one L2).** Each channel has a **round-robin arbiter** (`tl_rr_arbiter`). It picks the next L1 starting after the last winner, so no cache can starve the others.
- **B, D (one L2 → many L1s).** Each channel has a **router** (`tl_router`) that sends the message to the L1 named in its `source` field.
- **Bursts stay together.** Once a multi-beat message (`ReleaseData`, `ProbeAckData`, `GrantData`, `AccessAckData`) starts, the arbiter or router keeps that path until the last beat, so beats from different L1s never mix.
- **Grants are sticky.** Once a message is presented it isn't withdrawn, and its payload doesn't change until it's accepted, as TileLink requires.
- **Channel priority E > D > C > B > A.** A channel can only *start* a new message while no higher-priority channel has one waiting. This puts TileLink's forward-progress rule directly into the interconnect.

### Shared L2 cache — [`RTL/L2.sv`](RTL/L2.sv)

`l2_cache` is the point of coherence for the whole system.

| Property | Value |
|----------|-------|
| Size | 1 KB (32 sets × 2 ways × 16 B) |
| Associativity | 2-way set associative |
| Inclusion | **Inclusive** of all L1s |
| Write policy | Write-back to main memory |
| Per-line state | tag, valid, dirty, presence bit per L1, tip bit |
| Data storage | BRAM, one 32-bit beat per word, 1-cycle read latency |

**Directory-based coherence.** Each L2 line records which L1s hold it (one presence bit per source ID) and whether its one holder has T (the tip bit). The directory has to be exact, because an L1 assumes any probe it receives is for a line it really holds. It's kept exact by:

- `Grant` → sets the requester's presence bit (and the tip bit for T)
- `ProbeAck` / `ProbeAckData` → applies the permission the L1 reports keeping
- `Release` / `ReleaseData` → clears the releaser's presence bit

**Handling an Acquire** (one at a time):

1. **Hit, coherence actions.**
   - A request for **T** probes every *other* holder down to N.
   - A request for **B** only probes a T holder, down to B. Other B sharers keep their copies.
   - Dirty data returned on `ProbeAckData` is written into the L2, and the line is marked dirty.
2. **Miss, eviction.** The victim way is chosen in this order: an invalid way, then a way no L1 holds (to avoid probing anyone), then the least recently granted way. If the victim is still held by any L1, the L2 first probes those L1s to N (**back-invalidation**, required for inclusion). If the victim is dirty, it's written back to memory with `PutFullData`, and the L2 waits for `AccessAck`.
3. **Miss, fill.** `Get` the requested line from memory and write the four `AccessAckData` beats into the L2. Because of inclusion, no L1 can hold a line the L2 just missed on, so no probes are needed.
4. **Grant.** Read the line into a line buffer and send `GrantData` (or a dataless `Grant` for an `AcquirePerm` whose requester still holds the line). Then wait for `GrantAck` on E before accepting the next Acquire.

**Handling Releases.** Voluntary writebacks are handled by a separate small FSM, so they're accepted both while the L2 is idle and while it's waiting for probe acknowledgements. Without this the system could deadlock: an L1 in the middle of an eviction can't answer anything else until its `Release` is acknowledged. `ReleaseData` is only kept if the sender is still a holder in the directory. If a probe already took the line to N, the release data is stale (another L1 may have written the line since), so it's dropped.

### Main memory — [`RTL/main_memory.sv`](RTL/main_memory.sv)

- 64 KB of BRAM (16 K × 32-bit words), loaded at startup from `RTL/initial_ram.hex` with `$readmemh`.
- Serves `Get` with four `AccessAckData` beats, and `PutFullData` (four beats in) with a single `AccessAck`.
- Handles one request at a time with a small FSM (`IDLE → READ ⇄ RESPOND` for reads, `IDLE → WRITE → ACK` for writes). The one-cycle BRAM read latency is covered by the `READ` state.

---

## Example Transactions

### Read miss, line not cached anywhere

```
L1_1  --A: AcquireBlock(NtoB)-->  L2      (L2 miss, victim clean, no L1 holders)
L2    --A: Get---------------->   MEM
MEM   --D: AccessAckData x4--->   L2      (fill L2)
L2    --D: GrantData(toB) x4-->   L1_1
L1_1  --E: GrantAck----------->   L2      (directory: L1_1 present, B)
```

### Write to a line another L1 holds dirty

```
L1_2  --A: AcquireBlock(NtoT)-->  L2      (L2 hit, directory: L1_1 holds T)
L2    --B: ProbeBlock(toN)--->    L1_1
L1_1  --C: ProbeAckData(TtoN) x4-> L2     (L2 takes the dirty data, marks line dirty)
L2    --D: GrantData(toT) x4-->   L1_2
L1_2  --E: GrantAck----------->   L2      (directory: only L1_2 present, T)
```

### Upgrade from shared to exclusive

```
L1_1  --A: AcquirePerm(BtoT)-->   L2      (directory: L1_1 and L1_2 hold B)
L2    --B: ProbeBlock(toN)--->    L1_2
L1_2  --C: ProbeAck(BtoN)----->   L2
L2    --D: Grant(toT)--------->   L1_1    (no data, L1_1 already has it)
L1_1  --E: GrantAck----------->   L2
```

### L1 eviction of a dirty line

```
L1_1  --C: ReleaseData(TtoN) x4-> L2      (L2 writes the data, clears L1_1's presence bit)
L2    --D: ReleaseAck-------->    L1_1
L1_1  --A: AcquireBlock(...)-->   L2      (now fetch the line that caused the eviction)
```

---

## Repository Layout

```
RTL/
  tilelink_pkg.sv       Bus parameters, opcodes, permission/param encodings, channel structs, CPU structs
  L1D_1.sv              L1 data cache, TileLink source ID 1
  L1D_2.sv              L1 data cache, TileLink source ID 2
  L2_controller.sv      Interconnect: round-robin arbiters (A/C/E) and source routers (B/D)
  L2.sv                 Shared inclusive L2 with directory-based coherence
  main_memory.sv        64 KB BRAM main memory (Get / PutFullData)
  initial_ram.hex       Main memory initial contents

TB/
  tb_L1D_1.sv           L1_cache1 in isolation against a behavioural L2 model
  tb_L1D_2.sv           L1_cache2 in isolation (mirrors tb_L1D_1)
  tb_L2_controller.sv   Interconnect unit test with scripted L1/L2 drivers
  tb_L1s_L2_controller.sv  Both real L1s through the real interconnect into the L2 model
  l1d_bfm.sv            Behavioural L2 model (l2_bfm) used by the tests above
  l1d_internal_checks.sv  Internal L1 invariants, bound into the L1 testbenches
  tl_chan_checker.sv    Assertions for TileLink valid/ready/payload rules on every channel
```

---

## Verification

Testing was built up from the bottom:

1. **Each L1 in isolation** (`tb_L1D_1`, `tb_L1D_2`). Each cache talks to `l2_bfm`, a behavioural L2 that can inject probes on exact cycles, for example in the middle of an eviction, and insert random stalls on every channel.
2. **The interconnect alone** (`tb_L2_controller`). Scripted drivers on both sides check round-robin rotation, sticky grants, burst locking, channel priority and routing by source.
3. **Both L1s through the interconnect** (`tb_L1s_L2_controller`). The real caches run eviction-heavy traffic at the same time through the real interconnect into `l2_bfm`.
4. **Full system.** Both L1s, the interconnect, the real L2 and main memory have been run together with a reference model checking every load: directed sharing, upgrade and ping-pong cases, followed by concurrent random loads and stores from both CPUs to a small set of addresses that forces constant L2 evictions and back-invalidations. *(This full-system testbench hasn't been added to `TB/` yet.)*

Every channel in the unit and integration testbenches is covered by `tl_chan_checker` assertions: `valid` may not drop before `ready`, the payload may not change while waiting, and nothing may be X.

The simulations were run in **Questa**. Compile `RTL/tilelink_pkg.sv` first, since every other file imports it.

---

## Design Limitations

These are deliberate simplifications or known gaps, not hidden bugs.

### Protocol

- **Subset of TL-C.** No `PutPartialData`, atomics, hints, `ProbePerm`, or error reporting (`corrupt`/`denied`). Every transfer is exactly one 16-byte line.
- **One transaction per master.** Each L1 has a single source ID, so it can have only one Acquire outstanding. Hit-under-miss is supported, but not miss-under-miss.
- **No Exclusive (E) state.** A read always gets B, even when no other cache holds the line, so the first store to a line that was read first always needs an `AcquirePerm` round trip.
- **`AcquirePerm` may be answered with `GrantData`** (see [What I simplified](#what-I-simplified)). Strict TileLink only allows `Grant` there.

### L2 and memory performance

- **The L2 is blocking.** It handles one Acquire at a time from start to finish (including probes, writeback, fill and `GrantAck`). Requests from other L1s wait, even for unrelated lines. Only Releases are handled alongside.
- **Probes go out one at a time**, one target L1 per probe message.
- **Main memory is slow and serial.** One request at a time, about 3 cycles per read beat (roughly 12 cycles for a line fill), and no pipelining.
- **Small, fixed caches.** 256 B per L1 and 1 KB of L2, both 2-way. The L2's way-select logic assumes exactly 2 ways, so changing `L2_WAYS` needs code changes.

### System scope

- **Two L1s in practice.** The interconnect and L2 directory support four source IDs, but only two L1 data caches exist. Ports 0 and 3 are tied off in the testbenches.
- **No instruction caches**, and no processor core. The CPU side is driven directly by testbenches.
- **No top-level wrapper** connects the full system yet, and there's no full-system testbench in `TB/` yet either.
- **The two L1s are separate, hand-written modules** (`L1_cache1`, `L1_cache2`) rather than one module with a parameter. Changes have to be made in both.
- **`initial_ram.hex` is currently empty**, so main memory reads return X until an address is written. Fill it before running anything that reads memory it didn't write first.
- **Inclusion costs capacity.** Because the L2 is inclusive, evicting an L2 line forces any L1 copies out too, and L1 contents always use up L2 space.

### L1 behaviour the L2 relies on

- An L1 assumes every probe it receives is for a line it actually holds. It doesn't check for a miss, so a probe for a line it doesn't hold would downgrade whatever happens to be in way 0. The L2's exact directory is what keeps this safe.
- An L1 that was probed down to N keeps that line marked valid until it's replaced. When it's evicted, the L1 still sends a `Release` (`BtoN`) for it, and the L2 acknowledges it without changing its directory.
