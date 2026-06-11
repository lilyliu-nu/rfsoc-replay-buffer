# IQ Replay Buffer — Usage Guide

## Overview

The IQ replay buffer is a programmable logic IP block that sits between an AXI DMA and the RF data converter (rfdc) transmit chain. It allows arbitrary IQ waveform data to be loaded once from DDR4 memory and then replayed continuously from on-chip BRAM without further CPU involvement.

```
SD card / Python
      │
      ▼
DDR4 (PYNQ allocate)
      │
      ▼  AXI DMA (MM2S, fires once)
      │
      ▼
replay_buf_top              ← this IP
  ├─ passthrough: DMA stream → BRAM write + stream out to rfdc
  └─ replay:      BRAM read → stream out to rfdc (DMA idle)
      │
      ▼
rfdc / DAC → RF output
```

---

## Register Map

Base address: assigned in block design (default `0xA00E0000`).  
All registers are 32-bit, 4-byte aligned.

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x00` | CTRL | R/W | Control register |
| `0x04` | REP_COUNT | R/W | Target repetition count |
| `0x08` | STATUS | R | Status register |
| `0x0C` | REP_DONE | R | Completed repetitions |

### CTRL — `0x00`

| Bit | Name | Description |
|-----|------|-------------|
| 0 | mode | `0` = passthrough, `1` = replay |
| 1 | infinite | `0` = finite (use REP_COUNT), `1` = loop forever |
| 31:2 | — | Reserved, write 0 |

**Write ordering requirement:** Always write `REP_COUNT` before writing `CTRL` when starting a finite replay. The RTL samples `REP_COUNT` at the moment `CTRL` is written.

### REP_COUNT — `0x04`

Number of complete waveform replays to perform in finite mode. Ignored when `CTRL[1]` (infinite) is set. Write this register before writing `CTRL[0]` to start replay.

### STATUS — `0x08`

| Bit | Name | Description |
|-----|------|-------------|
| 0 | busy | `1` while replay is active |
| 1 | done | `1` when finite replay has completed. Cleared when `CTRL` is written again |
| 31:2 | — | Reserved |

### REP_DONE — `0x0C`

Read-only running count of complete waveform replays in the current or most recent run. Reset to 0 when `CTRL` is written.

---

## Operating Modes

### Passthrough (default after reset)

`CTRL = 0x00000000`

The DMA stream passes directly through to the rfdc. Every incoming beat is simultaneously written to BRAM. When the DMA asserts TLAST, the buffer length is latched internally. The rfdc receives one copy of the waveform during this transfer.

This is the mode to be in when calling `dma.sendchannel.transfer()`.

### Finite Replay

```
Write REP_COUNT = N
Write CTRL      = 0x00000001
```

The BRAM contents are driven to the rfdc N times. The stream is gapless between repetitions — no inter-repetition silence. When complete, `STATUS[1]` (done) is set and an interrupt is optionally raised. The IP returns to an idle state but CTRL remains at `0x01` until the PS writes it again.

Poll `STATUS[1]` or wait for the interrupt before issuing the next command.

### Infinite Replay

```
Write CTRL = 0x00000003
```

The BRAM contents are driven to the rfdc indefinitely. `REP_DONE` increments on each pass. Write `CTRL = 0x00000000` to stop.

---

## Operational Flow

```
1. Ensure CTRL = 0x00000000  (passthrough)
2. Allocate DMA buffer, fill with IQ samples
3. Fire DMA transfer — waveform plays once, BRAM is loaded
4. Write REP_COUNT (finite mode only)
5. Write CTRL to start replay
6. Poll STATUS[1] or wait for IRQ (finite mode)
7. Write CTRL = 0x00000000 to return to passthrough
```

---

## Hardware Parameters

| Generic | Default | Description |
|---------|---------|-------------|
| `TDATA_WIDTH` | 128 | AXI4-Stream data width in bits. Must match rfdc `s00_axis` width |
| `BRAM_DEPTH` | 65536 | BRAM capacity in `TDATA_WIDTH`-wide words. Must be a power of 2 |
| `FORWARD_TLAST` | false | `false` for rfdc targets (rfdc ignores TLAST). `true` for strath-sdr transmitter IP |

### BRAM capacity reference (TDATA_WIDTH=128, clk_dac0=32 MHz)

| BRAM_DEPTH | Capacity | Waveform duration |
|------------|----------|-------------------|
| 16,384 | 256 KB | 512 µs |
| 65,536 | 1 MB | 2 ms |
| 131,072 | 2 MB | 4 ms |

### DMA transfer size limit

The AXI DMA `c_sg_length_width` parameter controls the maximum single transfer size. With the default setting of 23 bits, the maximum is 2²³ − 1 = 8,388,607 bytes (~8 MB). The buffer loaded into BRAM is limited to the smaller of this value and `BRAM_DEPTH × (TDATA_WIDTH / 8)`.

---

## Clock Domains

| Domain | Source | Used by |
|--------|--------|---------|
| `s_axi_aclk` | `pl_clk0` (~96 MHz) | AXI-Lite register file |
| `aclk` | `clk_dac0` (~32 MHz) | BRAM datapath, stream interfaces |

Control signals are crossed between domains using a toggle synchroniser (`ctrl_written` pulse) and two-flop synchronisers (level signals). The `ASYNC_REG` attribute is applied to all synchroniser flip-flops.

---

## Interrupt

The IP asserts a one-cycle pulse on `irq` when a finite replay completes. This is connected to the PS GIC via `xlconcat` in the block design. The interrupt is in the `clk_dac0` domain.

To use the interrupt from PYNQ:

```python
# Not yet implemented in the driver — poll STATUS[1] instead
while not (rb._mmio.read(0x08) & 0x02):
    time.sleep(0.01)
```

---

## Python Driver

See `replay_buffer.py`. Quick reference:

```python
from pynq import Overlay, allocate
import numpy as np
from replay_buffer import ReplayBuffer

ol = Overlay('mep_replay.bit')
rb = ReplayBuffer(ol, ip_name='replay_buf', dma_name='axi_dma_tx')

# Load from file
buf = rb.load_from_file('/media/sd-mmcblk0p1/waveform.bin')

# Finite replay
rb.replay_finite(100)
rb.wait()

# Infinite replay
rb.replay_infinite()
time.sleep(5)
rb.stop()

# Manual load and replay
buf = allocate(shape=(N,), dtype=np.int16)
buf[:] = your_iq_data
rb.load(buf)
rb.replay_finite(10)
rb.wait()
rb.stop()
```

---

## Block Design Integration (MEP SDR)

Run `integrate_replay_buf_mep.tcl` in the Vivado TCL console after sourcing the MEP `block_design.tcl`:

```tcl
source /path/to/block_design.tcl
source /path/to/integrate_replay_buf_mep.tcl
```

Then generate the bitstream normally. The script adds:
- `axi_dma_tx` IP (MM2S, 128-bit, 64-bit address)
- `axi_mem_intercon` connecting DMA to `S_AXI_HP1_FPD`
- `replay_buf` IP between DMA stream output and `rfdc/s00_axis`
- Two additional master ports on `ps8_0_axi_periph`
- All clock, reset, and address assignments

### Address map additions

| IP | Register base | Range |
|----|--------------|-------|
| `axi_dma_tx` S_AXI_LITE | `0xA00D0000` | 64 KB |
| `replay_buf` S_AXI | `0xA00E0000` | 64 KB |

---

## File List

| File | Description |
|------|-------------|
| `replay_buf_top.vhd` | Top-level IP wrapper |
| `replay_ctrl_axi.vhd` | AXI-Lite slave register file |
| `cdc_sync.v` | Clock domain crossing (pl_clk0 ↔ clk_dac0) |
| `replay_ctrl_bram.vhd` | BRAM write/replay datapath |
| `integrate_replay_buf_mep.tcl` | Vivado block design patch script |
| `replay_buffer.py` | PYNQ Python driver |
| `replay_buffer_test.py` | Jupyter notebook test cells |
| `USAGE.md` | This document |
