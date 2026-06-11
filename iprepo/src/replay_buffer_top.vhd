-- =============================================================================
-- replay_buf_top.vhd
--
-- Top-level structural wrapper for the IQ replay buffer IP.
-- Connects replay_ctrl_axi, cdc_sync, and replay_ctrl_bram.
--
-- This is the entity you package as a Vivado IP and instantiate in the
-- MEP block design.
--
-- Port summary:
--
--   AXI-Lite slave   ← ps8_0_axi_periph/M09_AXI  (pl_clk0, ~96 MHz)
--   AXI4-Stream in   ← axi_dma_tx/M_AXIS_MM2S     (clk_dac0, ~32 MHz)
--   AXI4-Stream out  → rfdc/s00_axis               (clk_dac0, ~32 MHz)
--   irq              → xlconcat/InN
--
--   s_axi_aclk   : pl_clk0   (AXI-Lite control clock)
--   aclk         : clk_dac0  (stream / BRAM clock)
--   s_axi_aresetn: rst_ps8_0_96M/peripheral_aresetn
--   aresetn      : proc_sys_reset_1/peripheral_aresetn
--
-- Internal architecture:
--
--   PS (AXI-Lite, pl_clk0)
--         │
--   replay_ctrl_axi        — register file on pl_clk0
--         │  ctrl_* (pl_clk0)          stat_* (pl_clk0, from cdc)
--         │
--   cdc_sync               — crosses pl_clk0 ↔ clk_dac0
--         │  ctrl_* (clk_dac0)         stat_* (clk_dac0, from bram)
--         │
--   replay_ctrl_bram       — datapath on clk_dac0
--         │  S_AXIS_IN (from DMA)      M_AXIS_OUT (to rfdc)
-- =============================================================================


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity replay_buf_top is
  generic (
    TDATA_WIDTH : integer := 128;    -- must match rfdc s00_axis TDATA width
    BRAM_ADDR_WIDTH : integer := 16;  -- 1 MB default
    INCLUDE_CDC     : boolean := true;  -- cdc for mep;
    FORWARD_TLAST : boolean := true     -- no tlast for mep
  );
  port (
    -- AXI-Lite clock / reset  (pl_clk0)
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;

    -- Stream / BRAM clock / reset  (clk_dac0)
    aclk          : in  std_logic;
    aresetn       : in  std_logic;

    -- ---- AXI-Lite slave  (from ps8_0_axi_periph M09) ----------------------
    s_axi_awaddr  : in  std_logic_vector(4 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(4 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    -- ---- AXI4-Stream slave  (from axi_dma_tx M_AXIS_MM2S) -----------------
    s_axis_tdata  : in  std_logic_vector(TDATA_WIDTH-1 downto 0);
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;
    s_axis_tlast  : in  std_logic;

    -- ---- AXI4-Stream master  (to rfdc/s00_axis) ----------------------------
    m_axis_tdata  : out std_logic_vector(TDATA_WIDTH-1 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic--;

    -- -- ---- Interrupt  (to xlconcat) ------------------------------------------
  --  irq           : out std_logic
  );
end entity replay_buf_top;

architecture structural of replay_buf_top is

    -- cdc instantiation
    component cdc_sync is 
    port (
        axi_clk : in std_logic;
        axi_resetn : in std_logic; 
        dac_clk : in std_logic;
        dac_resetn : in std_logic;

        src_mode : in std_logic;
        src_infinite : in std_logic;
        src_rep_count : in unsigned(31 downto 0);
        src_written : in std_logic;   

        dst_mode : out std_logic;
        dst_infinite : out std_logic;
        dst_rep_count : out unsigned(31 downto 0);
        dst_written : out std_logic;  

        src_busy : in std_logic;
        src_done : in std_logic;
        src_rep_done : in unsigned(31 downto 0);

        dst_busy : out std_logic;
        dst_done : out std_logic;
        dst_rep_done : out unsigned(31 downto 0)
    );
    end component;

  -- ---------------------------------------------------------------------------
  -- Internal signals: axi_clk domain (pl_clk0)
  -- ---------------------------------------------------------------------------
  signal axi_ctrl_mode      : std_logic;
  signal axi_ctrl_infinite  : std_logic;
  signal axi_ctrl_rep_count : unsigned(31 downto 0);
  signal axi_ctrl_written   : std_logic;

  signal axi_stat_busy      : std_logic;
  signal axi_stat_done      : std_logic;
  signal axi_stat_rep_done  : unsigned(31 downto 0);

  -- ---------------------------------------------------------------------------
  -- Internal signals: dac_clk domain (clk_dac0)
  -- ---------------------------------------------------------------------------
  signal dac_ctrl_mode      : std_logic;
  signal dac_ctrl_infinite  : std_logic;
  signal dac_ctrl_rep_count : unsigned(31 downto 0);
  signal dac_ctrl_written   : std_logic;

  signal dac_stat_busy      : std_logic;
  signal dac_stat_done      : std_logic;
  signal dac_stat_rep_done  : unsigned(31 downto 0);
 -- signal dac_irq_pulse      : std_logic;

begin

  -- ===========================================================================
  -- AXI-Lite register file  (pl_clk0)
  -- ===========================================================================
  u_axi : entity work.axi_slave
    port map (
      s_axi_aclk    => s_axi_aclk,
      s_axi_aresetn => s_axi_aresetn,

      s_axi_awaddr  => s_axi_awaddr,
      s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => s_axi_awready,

      s_axi_wdata   => s_axi_wdata,
      s_axi_wstrb   => s_axi_wstrb,
      s_axi_wvalid  => s_axi_wvalid,
      s_axi_wready  => s_axi_wready,

      s_axi_bresp   => s_axi_bresp,
      s_axi_bvalid  => s_axi_bvalid,
      s_axi_bready  => s_axi_bready,

      s_axi_araddr  => s_axi_araddr,
      s_axi_arvalid => s_axi_arvalid,
      s_axi_arready => s_axi_arready,

      s_axi_rdata   => s_axi_rdata,
      s_axi_rresp   => s_axi_rresp,
      s_axi_rvalid  => s_axi_rvalid,
      s_axi_rready  => s_axi_rready,

      -- To CDC (axi_clk side)
      ctrl_mode      => axi_ctrl_mode,
      ctrl_infinite  => axi_ctrl_infinite,
      ctrl_rep_count => axi_ctrl_rep_count,
      ctrl_written   => axi_ctrl_written,

      -- From CDC (axi_clk side, already synchronised)
      stat_busy      => axi_stat_busy,
      stat_done      => axi_stat_done,
      stat_rep_done  => axi_stat_rep_done
    );

  -- ===========================================================================
  -- Clock domain crossing  (pl_clk0 ↔ clk_dac0)
  -- ===========================================================================
  gen_with_cdc: if INCLUDE_CDC generate
  u_cdc : cdc_sync
    port map (
      axi_clk       => s_axi_aclk,
      axi_resetn    => s_axi_aresetn,
      dac_clk       => aclk,
      dac_resetn    => aresetn,

      -- Forward path (axi_clk → dac_clk)
      src_mode      => axi_ctrl_mode,
      src_infinite  => axi_ctrl_infinite,
      src_rep_count => axi_ctrl_rep_count,
      src_written   => axi_ctrl_written,

      dst_mode      => dac_ctrl_mode,
      dst_infinite  => dac_ctrl_infinite,
      dst_rep_count => dac_ctrl_rep_count,
      dst_written   => dac_ctrl_written,

      -- Reverse path (dac_clk → axi_clk)
      src_busy      => dac_stat_busy,
      src_done      => dac_stat_done,
      src_rep_done  => dac_stat_rep_done,

      dst_busy      => axi_stat_busy,
      dst_done      => axi_stat_done,
      dst_rep_done  => axi_stat_rep_done
    );
   end generate gen_with_cdc;
   
   gen_no_cdc: if not INCLUDE_CDC generate
    -- Direct wire pass-through from axi side to dac side
    dac_ctrl_mode      <= axi_ctrl_mode;
    dac_ctrl_infinite  <= axi_ctrl_infinite;
    dac_ctrl_rep_count <= axi_ctrl_rep_count;
    dac_ctrl_written   <= axi_ctrl_written;

    -- Direct wire pass-through from dac side back to axi side
    axi_stat_busy      <= dac_stat_busy;
    axi_stat_done      <= dac_stat_done;
    axi_stat_rep_done  <= dac_stat_rep_done;
  end generate gen_no_cdc;
  -- ===========================================================================
  -- BRAM write / replay datapath  (clk_dac0)
  -- ===========================================================================
  u_bram : entity work.replay_cntrl
    generic map (
      AXIS_TDATA_WIDTH => TDATA_WIDTH,
      BRAM_ADDR_WIDTH  => BRAM_ADDR_WIDTH,
      FORWARD_TLAST => FORWARD_TLAST
    )
    port map (
      aclk    => aclk,
      aresetn => aresetn,

      -- Control from CDC (dac_clk domain)
      cntrl_mode      => dac_ctrl_mode,
      cntrl_infi  => dac_ctrl_infinite,
      cntrl_reps => dac_ctrl_rep_count,
      cntrl_written   => dac_ctrl_written,

      -- Status to CDC (dac_clk domain)
      stat_busy      => dac_stat_busy,
      stat_done      => dac_stat_done,
      stat_rep_done  => dac_stat_rep_done,
      --irq_pulse      => dac_irq_pulse,

      -- Stream interfaces
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      s_axis_tlast  => s_axis_tlast,

      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      m_axis_tlast  => m_axis_tlast
    );

  -- IRQ comes directly from BRAM datapath (dac_clk pulse)
  -- Wire to xlconcat in the block design
--  irq <= dac_irq_pulse;

end architecture structural;
