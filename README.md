# IQ Replay Buffer for RFSoC

A programmable logic IP block for the AMD/Xilinx RFSoC platform that enables
arbitrary IQ waveform data to be loaded once from DDR4 memory and replayed
continuously from on-chip BRAM without further CPU involvement.

Developed and tested on the **RFSoC 4x2** development board using the
[strath-sdr/rfsoc_radio](https://github.com/strath-sdr/rfsoc_radio) overlay.
Designed for integration with the
[spectrumx/mep-rfsoc-sdr](https://github.com/spectrumx/mep-rfsoc-sdr) overlay.

---

## Quick Start

### Prerequisites

- RFSoC 4x2 board running PYNQ 3.0+
- MEP SDR overlay built with the integration patch (see [Building the Bitstream](#building-the-bitstream))
- OR strath-sdr overlay for initial testing

### On the board

Drag and Drop via JupyterLab 
1. Open a web browser and navigate to the JupyterLab interface:
   `http://<board_ip_address>:9090/lab` (Default password is `xilinx`).
2. In the Jupyter file browser on the left, navigate to the directory where you want to store your files (e.g., the `jupyter_notebooks` folder or a new subfolder).
3. Open your local file explorer and drag and drop strath_sdr_test.ipynb, replay_buffer.py, replay_rfsoc_radio.bit, and replay_rfsoc_radio.hwh files directly into the JupyterLab file browser window.

Install via Ethernet.  
```bash
# Clone this repo into the Jupyter notebooks directory
cd /home/xilinx/jupyter_notebooks
git clone https://github.com/lilyliu-nu/rfsoc_replay_buffer.git
cd rfsoc_replay_buf

# Install the driver
pip install -e driver/
```

Open JupyterLab at `http://<ip_address>` and navigate to `notebooks/`.

---

## Building the Bitstream

### Requirements

- Vivado 2022.1 (must match PYNQ version on board)
- MEP SDR project cloned and buildable

### Steps

```tcl
# 1. Open Vivado and source the MEP base design
vivado -mode tcl

# 2. In the Vivado TCL console:
source /path/to/mep-rfsoc-sdr/block_design.tcl

# 3. Apply the replay buffer integration patch
source /path/to/rfsoc_replay_buf/boards/RFSoC4x2/integrate_replay_buf_mep.tcl

# 4. Generate bitstream
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
```

Copy the generated `.bit` and `.hwh` files to the board:

```bash
scp your_project.runs/impl_1/design_1_wrapper.bit \
    xilinx@192.168.2.99:/home/xilinx/jupyter_notebooks/rfsoc_replay_buf/boards/RFSoC4x2/bitstream/mep_replay.bit

scp your_project.gen/sources_1/bd/design_1/hw_handoff/design_1.hwh \
    xilinx@192.168.2.99:/home/xilinx/jupyter_notebooks/rfsoc_replay_buf/boards/RFSoC4x2/bitstream/mep_replay.hwh
```

---

## IP Block Overview

```
DDR4 (PYNQ allocate)
      │
      ▼  AXI DMA MM2S (fires once)
      │
      ▼
┌─────────────────────┐
│   replay_buf_top    │  ◄── AXI-Lite (PS control)
│                     │
│  passthrough mode:  │  DMA stream → BRAM write + stream out
│  replay mode:       │  BRAM read → stream out (DMA idle)
└─────────────────────┘
      │
      ▼
rfdc / DAC → RF output
```

### Register Map

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x00` | CTRL | R/W | `bit0`=mode, `bit1`=infinite |
| `0x04` | REP_COUNT | R/W | Target repetition count |
| `0x08` | STATUS | R | `bit0`=busy, `bit1`=done |
| `0x0C` | REP_DONE | R | Completed repetitions |

See [docs/USAGE.md](docs/USAGE.md) for full documentation.

---

## Extending to Scatter-Gather DMA

For waveforms larger than 8MB (the Simple DMA transfer limit), a
Scatter-Gather DMA implementation is required for gapless replay.
See [docs/sg_dma_extension.md](docs/sg_dma_extension.md) for a
complete implementation guide.

---

## Tested Configuration

| Parameter | Value |
|-----------|-------|
| Board | RFSoC 4x2 |
| PYNQ version | 3.0 |
| Vivado version | 2022.1 |
| TDATA width | 128-bit |
| BRAM depth | 65,536 words (1 MB) |
| DAC sample rate | 1.024 GSPS | - Strath-sdr repo
| Fabric clock | 32 MHz (clk_dac0) |
| Max waveform (BRAM) | ~2 ms |
| Max waveform (DMA) | 8 MB per transfer |
