# =============================================================================
# integrate_replay_buf_mep.tcl
#
# Patch script for the MEP SDR block design.
# Source in the Vivado TCL console AFTER the MEP block_design.tcl has been
# sourced and the design is open.
#
# Usage:
#   source /path/to/block_design.tcl
#   source /path/to/integrate_replay_buf_mep.tcl
#
# What this script adds:
#   1.  axi_dma_tx         MM2S-only DMA, 128-bit stream, 64-bit address
#   2.  axi_mem_intercon   DMA memory master -> S_AXI_HP2_FPD
#   3.  replay_buf         IQ replay buffer IP (custom IP)
#   4.  axis_switch_dac0   2-to-1 stream mux:
#                            S00 <- replay_buf  (arbitrary IQ waveform)
#                            S01 <- function_gen_to_dac_B  (CW tone fallback)
#                            M00 -> rfdc/s00_axis
#   5.  ps8_0_axi_periph   expanded from 8 to 11 masters:
#                            M08 -> axi_dma_tx/S_AXI_LITE
#                            M09 -> replay_buf/S_AXI
#                            M10 -> axis_switch_dac0/S_AXI_CTRL
#
# Address map additions:
#   0xA00D0000  axi_dma_tx S_AXI_LITE      (64 KB)
#   0xA00E0000  replay_buf S_AXI           (64 KB)
#   0xA00F0000  axis_switch_dac0 S_AXI_CTRL (64 KB)
#
# Prerequisites:
#   replay_buf_top packaged as Vivado IP, VLNV user.org:user:replay_buf_top:1.0
#   IP generics: TDATA_WIDTH=128, BRAM_DEPTH=65536, FORWARD_TLAST=false
# =============================================================================
current_bd_instance .
set_property CONFIG.NUM_MI {11} [get_bd_cells ps8_0_axi_periph]

# 1. Create a clean, standard 64-bit AXI DMA
set axi_dma_tx [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_tx]
set_property -dict [list \
    CONFIG.c_include_mm2s            {1}   \
    CONFIG.c_include_s2mm            {0}   \
    CONFIG.c_include_sg              {0}   \
    CONFIG.c_addr_width              {64}  \
    CONFIG.c_m_axis_mm2s_tdata_width {64}  \
    CONFIG.c_mm2s_burst_size         {256} \
    CONFIG.c_include_mm2s_dre        {0}   \
] [get_bd_cells axi_dma_tx]

# 2. Create the Memory Interconnect
set axi_mem_intercon [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_mem_intercon]
set_property -dict [list \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI {1} \
] $axi_mem_intercon

# 3. Create Custom Replay Buffer Component (Package fixed)
set replay_buf [create_bd_cell -type ip \
    -vlnv user.org:user:replay_buf_top:1.0 replay_buf]

# 4. Create 64-bit AXI Stream Switch
set axis_sw [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_switch:1.1 axis_switch_dac0]
set_property -dict [list \
    CONFIG.NUM_SI          {2}  \
    CONFIG.NUM_MI          {1}  \
    CONFIG.TDATA_NUM_BYTES {8}  \
    CONFIG.HAS_TLAST       {0}  \
    CONFIG.ARB_ON_TLAST    {0}  \
    CONFIG.ARB_ALGORITHM   {3}  \
    CONFIG.ROUTING_MODE    {1}  \
    CONFIG.DECODER_REG     {1}  \
] $axis_sw

# =========================================================================
# INTERFACE CONNECTIONS
# =========================================================================
delete_bd_objs [get_bd_intf_nets function_gen_to_dac_B_M00_AXIS]

# Stream path: DMA -> Replay Buffer -> Switch -> RFDC
connect_bd_intf_net [get_bd_intf_pins axi_dma_tx/M_AXIS_MM2S] [get_bd_intf_pins replay_buf/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins replay_buf/M_AXIS] [get_bd_intf_pins axis_switch_dac0/S00_AXIS]
connect_bd_intf_net [get_bd_intf_pins function_gen_to_dac_B/M00_AXIS] [get_bd_intf_pins axis_switch_dac0/S01_AXIS]
connect_bd_intf_net [get_bd_intf_pins axis_switch_dac0/M00_AXIS] [get_bd_intf_pins rfdc/s00_axis]

# Control paths
connect_bd_intf_net [get_bd_intf_pins ps8_0_axi_periph/M08_AXI] [get_bd_intf_pins axi_dma_tx/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ps8_0_axi_periph/M09_AXI] [get_bd_intf_pins replay_buf/S_AXI]
connect_bd_intf_net [get_bd_intf_pins ps8_0_axi_periph/M10_AXI] [get_bd_intf_pins axis_switch_dac0/S_AXI_CTRL]

# Memory Interconnect Path
connect_bd_intf_net [get_bd_intf_pins axi_dma_tx/M_AXI_MM2S] [get_bd_intf_pins axi_mem_intercon/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_mem_intercon/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP2_FPD]

# =========================================================================
# CLOCK CONNECTIONS
# =========================================================================
# 96MHz Domain (pl_clk0) - Handles control interfaces
connect_bd_net \
    [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins ps8_0_axi_periph/M08_ACLK] \
    [get_bd_pins ps8_0_axi_periph/M09_ACLK] \
    [get_bd_pins ps8_0_axi_periph/M10_ACLK] \
    [get_bd_pins axi_dma_tx/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_tx/m_axi_mm2s_aclk] \
    [get_bd_pins replay_buf/s_axi_aclk] \
    [get_bd_pins axis_switch_dac0/s_axi_ctrl_aclk] \
    [get_bd_pins axi_mem_intercon/ACLK] \
    [get_bd_pins axi_mem_intercon/S00_ACLK] \
    [get_bd_pins axi_mem_intercon/M00_ACLK] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp2_fpd_aclk]

# 32MHz Domain (clk_dac0) - Handles high-speed streaming pipelines
connect_bd_net \
    [get_bd_pins rfdc/clk_dac0] \
    [get_bd_pins replay_buf/aclk] \
    [get_bd_pins axis_switch_dac0/aclk]

# =========================================================================
# RESET CONNECTIONS
# =========================================================================
connect_bd_net \
    [get_bd_pins rst_ps8_0_96M/peripheral_aresetn] \
    [get_bd_pins ps8_0_axi_periph/M08_ARESETN] \
    [get_bd_pins ps8_0_axi_periph/M09_ARESETN] \
    [get_bd_pins ps8_0_axi_periph/M10_ARESETN] \
    [get_bd_pins axi_dma_tx/axi_resetn] \
    [get_bd_pins replay_buf/s_axi_aresetn] \
    [get_bd_pins axis_switch_dac0/s_axi_ctrl_aresetn] \
    [get_bd_pins axi_mem_intercon/ARESETN] \
    [get_bd_pins axi_mem_intercon/S00_ARESETN] \
    [get_bd_pins axi_mem_intercon/M00_ARESETN]

connect_bd_net \
    [get_bd_pins proc_sys_reset_1/peripheral_aresetn] \
    [get_bd_pins replay_buf/aresetn] \
    [get_bd_pins axis_switch_dac0/aresetn]

# =========================================================================
# ADDRESS MAP ASSIGNMENTS
# =========================================================================
assign_bd_address -offset 0xA00D0000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs axi_dma_tx/S_AXI_LITE/Reg] -force
assign_bd_address -offset 0xA00E0000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs replay_buf/S_AXI/reg0] -force
assign_bd_address -offset 0xA00F0000 -range 0x00010000 -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] [get_bd_addr_segs axis_switch_dac0/S_AXI_CTRL/Reg] -force

assign_bd_address -target_address_space [get_bd_addr_spaces axi_dma_tx/Data_MM2S] [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP4/HP2_DDR_LOW] -force

# =========================================================================
# FORCE-ALIGN PROPAGATION OVERRIDES BEFORE VALIDATION
# =========================================================================
# Use get_bd_intf_pins to correctly target the AXI-Stream Bus Interface
set_property CONFIG.CLK_DOMAIN {design_2_rfdc_0_clk_dac0} [get_bd_intf_pins axi_dma_tx/M_AXIS_MM2S]
set_property CONFIG.FREQ_HZ {32000000} [get_bd_intf_pins axi_dma_tx/M_AXIS_MM2S]

validate_bd_design

save_bd_design

puts ""
puts "=================================================================="
puts " MEP replay buffer integration complete."
puts "------------------------------------------------------------------"
puts " IP added:"
puts "   axi_dma_tx       MM2S DMA, 128-bit, 64-bit addr"
puts "   axi_mem_intercon DMA -> S_AXI_HP2_FPD"
puts "   replay_buf       IQ replay buffer (1MB BRAM, ~2ms)"
puts "   axis_switch_dac0 2-to-1 stream mux to rfdc/s00_axis"
puts "------------------------------------------------------------------"
puts " Address map:"
puts "   0xA00D0000  axi_dma_tx   S_AXI_LITE"
puts "   0xA00E0000  replay_buf   S_AXI"
puts "   0xA00F0000  axis_switch  S_AXI_CTRL"
puts "------------------------------------------------------------------"
puts " Stream path:"
puts "   replay_buf/M_AXIS         -> axis_switch/S00  (default)"
puts "   function_gen_to_dac_B     -> axis_switch/S01  (fallback)"
puts "   axis_switch/M00           -> rfdc/s00_axis"
puts "------------------------------------------------------------------"
puts " Interrupts:"
puts "   axi_dma_tx/mm2s_introut  -> xlconcat_0/In${dma_irq_idx}"
puts "   replay_buf               no irq port (poll STATUS bit1 from Python)"
puts "------------------------------------------------------------------"
puts " Switch control (from Python):"
puts "   MMIO(0xA00F0000).write(0x40, 0x00000000)  # S00 replay_buf"
puts "   MMIO(0xA00F0000).write(0x40, 0x00000001)  # S01 function_gen"
puts "   MMIO(0xA00F0000).write(0x00, 0x00000002)  # commit"
puts "=================================================================="
