# Scatter-Gather DMA Extension Guide

## Why SG DMA for Large Waveforms

The Simple DMA used in the current design is limited to one transfer of
2²³ - 1 bytes (~8 MB) per transaction. For waveforms larger than this,
or for truly gapless replay from DDR4 without an on-chip BRAM buffer,
Scatter-Gather (SG) DMA with a **cyclic buffer descriptor ring** is the
correct solution.

With a cyclic BD ring:
- The DMA hardware loops through a list of buffer descriptors automatically
- When it reaches the last descriptor it wraps back to the first
- No CPU involvement between repetitions — zero inter-repetition gap
- The waveform size is limited only by DDR4 (4 GB on RFSoC 4x2)

---

## What Changes vs the Current Design

### In Vivado

The `axi_dma_tx` IP needs to be reconfigured with Scatter-Gather enabled:

```tcl
set_property -dict [list \
    CONFIG.c_include_sg       {1}    \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_include_mm2s     {1}    \
    CONFIG.c_include_s2mm     {0}    \
    CONFIG.c_addr_width       {64}   \
    CONFIG.c_m_axis_mm2s_tdata_width {128} \
    CONFIG.c_sg_length_width  {23}   \
    CONFIG.c_mm2s_burst_size  {256}  \
] [get_bd_cells axi_dma_tx]
```

SG mode requires an additional AXI master port for the DMA to fetch
buffer descriptors from memory. This is the `M_AXI_SG` port — it needs
its own path to DDR4, separate from `M_AXI_MM2S`:

```tcl
# Add a second memory interconnect for SG descriptor fetch
set axi_sg_intercon [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_sg_intercon]
set_property -dict [list \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI {1} \
] $axi_sg_intercon

# Connect DMA SG port -> HP2 (or another free HP port)
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_tx/M_AXI_SG] \
    [get_bd_intf_pins axi_sg_intercon/S00_AXI]
connect_bd_intf_net \
    [get_bd_intf_pins axi_sg_intercon/M00_AXI] \
    [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP2_FPD]

# SG uses pl_clk0 (same as AXI-Lite control)
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins axi_dma_tx/m_axi_sg_aclk] \
    [get_bd_pins axi_sg_intercon/ACLK] \
    [get_bd_pins axi_sg_intercon/S00_ACLK] \
    [get_bd_pins axi_sg_intercon/M00_ACLK] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp2_fpd_aclk]

connect_bd_net [get_bd_pins rst_ps8_0_96M/peripheral_aresetn] \
    [get_bd_pins axi_sg_intercon/ARESETN] \
    [get_bd_pins axi_sg_intercon/S00_ARESETN] \
    [get_bd_pins axi_sg_intercon/M00_ARESETN]

# Address for SG port
assign_bd_address \
    -target_address_space \
        [get_bd_addr_spaces axi_dma_tx/Data_SG] \
    [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP4/HP2_DDR_LOW] \
    -force
```

### replay_buf_top IP

Simply keep the buffer in passthrough mode permanently and let the SG ring handle repetition.

---

## How a Cyclic BD Ring Works

A Buffer Descriptor (BD) is a 64-byte data structure in DDR4 memory that
tells the DMA:
- Where in DDR4 to read from (`BUFFER_ADDRESS`)
- How many bytes to transfer (`CONTROL.buffer_len`)
- Where the next BD is (`NEXT_DESC`)
- Status bits (set by DMA after transfer completes)

A cyclic ring is a linked list where the last BD's `NEXT_DESC` points
back to the first BD:

```
BD[0] → BD[1] → BD[2] → BD[3] ─┐
  ↑                              │
  └──────────────────────────────┘
```

The DMA fetches BD[0], transfers that buffer, fetches BD[1], etc. When
it reaches BD[3] and sees `NEXT_DESC` pointing to BD[0], it loops. No
CPU write needed between repetitions.

### BD Memory Layout (64 bytes each, 64-byte aligned)

```
Offset  Size  Field
0x00    8     NEXT_DESC      physical address of next BD (64-bit)
0x08    8     BUFFER_ADDRESS physical address of IQ data (64-bit)
0x10    4     CONTROL        bits[22:0] = byte count, bit[26] = TXSOF, bit[27] = TXEOF
0x14    4     STATUS         written by DMA on completion (do not write)
0x18    44    reserved / app fields
```

---

## Python Implementation

### BD Ring Driver

```python
import numpy as np
from pynq import allocate, MMIO

# =============================================================================
# AXI DMA SG register offsets (MM2S channel)
# =============================================================================
MM2S_DMACR      = 0x00   # control:  bit0=RS, bit12=IOC_IrqEn, bit14=Err_IrqEn
MM2S_DMASR      = 0x04   # status:   bit1=Idle, bit12=IOC_Irq
MM2S_CURDESC    = 0x08   # current BD address low
MM2S_CURDESC_MSB= 0x0C   # current BD address high
MM2S_TAILDESC   = 0x10   # tail BD address low  (writing this starts the engine)
MM2S_TAILDESC_MSB=0x14   # tail BD address high

# BD field offsets within each 64-byte descriptor
BD_NEXT_LO      = 0x00
BD_NEXT_HI      = 0x04
BD_BUF_LO       = 0x08
BD_BUF_HI       = 0x0C
BD_CONTROL      = 0x18
BD_STATUS       = 0x1C

BD_SIZE         = 64     # bytes, must be 64-byte aligned
BD_TXSOF        = (1 << 26)
BD_TXEOF        = (1 << 27)


class SGDMACyclicRing:
    """
    Scatter-Gather DMA cyclic buffer descriptor ring for gapless IQ replay.

    Sets up N buffer descriptors pointing to equally-sized chunks of a
    large IQ buffer.  The tail BD points back to the first, creating a
    hardware loop.  Once started, the DMA replays the waveform indefinitely
    with no CPU intervention and zero inter-repetition gap.

    Parameters
    ----------
    overlay     : pynq.Overlay
    dma_name    : str    name of axi_dma IP in overlay (must have SG enabled)
    n_desc      : int    number of buffer descriptors in the ring.
                         More descriptors = smoother operation but more overhead.
                         Recommended: 4–16.
    """

    def __init__(self, overlay, dma_name='axi_dma_tx', n_desc=8):
        dma_base   = overlay.ip_dict[dma_name]['phys_addr']
        self._mmio = MMIO(dma_base, length=0x100)
        self._n    = n_desc

        # Allocate physically contiguous memory for the BD ring
        # Each BD is 64 bytes, must be 64-byte aligned
        bd_bytes        = n_desc * BD_SIZE
        self._bd_buf    = allocate(shape=(bd_bytes,), dtype=np.uint8)
        self._bd_phys   = self._bd_buf.physical_address

        assert self._bd_phys % 64 == 0, \
            "BD ring not 64-byte aligned — try a fresh allocate()"

        self._iq_buf    = None
        self._running   = False

    def load(self, buf):
        """
        Point the BD ring at a pre-allocated IQ buffer.
        The buffer is divided equally among the N descriptors.
        Call start() after this.

        Parameters
        ----------
        buf : pynq.buffer.PynqBuffer
            Large IQ buffer from pynq.allocate().
            Size should be a multiple of n_desc for even division.
        """
        self._iq_buf  = buf
        chunk         = buf.nbytes // self._n
        remainder     = buf.nbytes  % self._n

        # Build the BD ring in the allocated BD buffer
        bd_array = np.frombuffer(self._bd_buf, dtype=np.uint32)

        for i in range(self._n):
            bd_off_bytes  = i * BD_SIZE
            bd_off_words  = bd_off_bytes // 4

            # Next descriptor: wrap last to first
            next_i        = (i + 1) % self._n
            next_phys     = self._bd_phys + next_i * BD_SIZE

            # IQ data chunk for this descriptor
            chunk_offset  = i * chunk
            chunk_bytes   = chunk if i < self._n - 1 else chunk + remainder
            buf_phys      = buf.physical_address + chunk_offset

            # Write BD fields (32-bit writes)
            bd_array[bd_off_words + BD_NEXT_LO   // 4] = \
                np.uint32(next_phys & 0xFFFFFFFF)
            bd_array[bd_off_words + BD_NEXT_HI   // 4] = \
                np.uint32((next_phys >> 32) & 0xFFFFFFFF)
            bd_array[bd_off_words + BD_BUF_LO    // 4] = \
                np.uint32(buf_phys & 0xFFFFFFFF)
            bd_array[bd_off_words + BD_BUF_HI    // 4] = \
                np.uint32((buf_phys >> 32) & 0xFFFFFFFF)

            # Control: byte count + SOF on first + EOF on last
            ctrl = chunk_bytes & 0x7FFFFF
            if i == 0:
                ctrl |= BD_TXSOF
            if i == self._n - 1:
                ctrl |= BD_TXEOF
            bd_array[bd_off_words + BD_CONTROL // 4] = np.uint32(ctrl)

            # Clear status
            bd_array[bd_off_words + BD_STATUS  // 4] = np.uint32(0)

        print(f"BD ring built: {self._n} descriptors, "
              f"{chunk} bytes each, "
              f"total {buf.nbytes} bytes")

    def start(self):
        """
        Start the cyclic DMA ring.  Runs until stop() is called.
        """
        if self._iq_buf is None:
            raise RuntimeError("No buffer loaded. Call load() first.")

        first_bd = self._bd_phys
        # For cyclic operation, tail = last BD (DMA will loop past it)
        tail_bd  = self._bd_phys + (self._n - 1) * BD_SIZE

        # 1. Set CURDESC to first BD before enabling RS
        self._mmio.write(MM2S_CURDESC,     int(first_bd & 0xFFFFFFFF))
        self._mmio.write(MM2S_CURDESC_MSB, int((first_bd >> 32) & 0xFFFFFFFF))

        # 2. Enable run/stop
        self._mmio.write(MM2S_DMACR, 0x00001001)  # RS=1, IOC_IrqEn=1

        # 3. Write TAILDESC — this starts the DMA
        self._mmio.write(MM2S_TAILDESC,     int(tail_bd & 0xFFFFFFFF))
        self._mmio.write(MM2S_TAILDESC_MSB, int((tail_bd >> 32) & 0xFFFFFFFF))

        self._running = True
        print("SG cyclic DMA started — gapless replay active.")

    def stop(self):
        """
        Halt the DMA engine.
        """
        # Clear RS bit — DMA completes current burst then stops
        dmacr = self._mmio.read(MM2S_DMACR)
        self._mmio.write(MM2S_DMACR, dmacr & ~0x1)
        self._running = False
        print("SG DMA stopped.")

    @property
    def is_running(self):
        return self._running

    def status(self):
        sr = self._mmio.read(MM2S_DMASR)
        return (f"DMASR=0x{sr:08X}  "
                f"idle={bool(sr & 0x2)}  "
                f"halted={bool(sr & 0x1)}")

    def free(self):
        self._bd_buf.freebuffer()
        if self._iq_buf:
            self._iq_buf.freebuffer()
```

### Usage

```python
from pynq import Overlay, allocate
import numpy as np
from sg_dma_ring import SGDMACyclicRing

ol  = Overlay('mep_replay_sg.bit')
sg  = SGDMACyclicRing(ol, dma_name='axi_dma_tx', n_desc=8)

# Load large waveform from SD card
raw = np.fromfile('/media/sd-mmcblk0p1/large_waveform.bin', dtype=np.int16)
buf = allocate(shape=raw.shape, dtype=np.int16)
buf[:] = raw

sg.load(buf)
sg.start()

import time
try:
    while True:
        print(sg.status(), end='\r')
        time.sleep(1.0)
except KeyboardInterrupt:
    pass

sg.stop()
buf.freebuffer()
```

---

## Key Differences from Simple DMA

| | Simple DMA (current) | SG DMA (extension) |
|---|---|---|
| Max waveform size | 8 MB | 4 GB (full DDR4) |
| Gap between reps | Zero (BRAM) / 1–10 µs (software) | Zero (hardware ring) |
| CPU involvement during replay | None (BRAM) / high (software) | None |
| BRAM required | Yes (on-chip buffer) | No |
| Vivado complexity | Low | Medium (extra AXI port) |
| Python complexity | Low | Medium (BD ring setup) |
| `replay_buf_top` IP | Used for BRAM replay | Passthrough only (or removed) |

---

## Important Notes

### BD alignment
Buffer descriptors must be aligned to 64-byte boundaries in physical
memory. `pynq.allocate()` returns page-aligned buffers (typically 4KB
aligned) so this is satisfied automatically.

### IQ buffer alignment
Each chunk pointed to by a BD must be aligned to the DMA's
`c_mm2s_burst_size × (TDATA_WIDTH/8)` boundary. With burst=256 and
128-bit data that is 256 × 16 = 4096 bytes. Divide your buffer into
chunks that are multiples of 4096 bytes.

### TAILDESC and cyclic behaviour
In SG mode, writing TAILDESC tells the DMA which is the last BD to
process before raising an interrupt. For cyclic operation you still
write it once at start — the DMA raises an IOC interrupt when it
reaches the tail, but if RS=1 it immediately continues to
`NEXT_DESC` of the tail (which is BD[0]) and keeps going. The
interrupt fires once per full loop, which you can use as a loop
counter if needed.

### Testing before hardware
Xilinx's AXI DMA product guide (PG021) includes a simulation example
project for SG mode. Run that first to verify your BD ring structure
before putting it on hardware.
