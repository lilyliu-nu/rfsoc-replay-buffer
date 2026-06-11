-- =============================================================================
-- axi_slave.vhd
--
-- AXI-Lite slave register file.  Exposes control and status registers to the
-- PS (PYNQ) and presents clean registered signals to the BRAM datapath.
--
-- Clock domains (MEP overlay):
--   s_axi_aclk    : pl_clk0 (~96 MHz)  — AXI-Lite bus and register storage
--   ctrl outputs  : emitted on s_axi_aclk, crossed to clk_dac0 by cdc_sync
--   stat inputs   : driven from clk_dac0 domain, crossed by cdc_sync before
--                   arriving here — so they are already in s_axi_aclk domain
--
-- Register map (byte-addressed, 32-bit):
--
--   0x00  CTRL       [R/W]
--           bit[0]  mode       0=passthrough  1=replay
--           bit[1]  infinite   0=finite       1=loop forever
--           bit[31:2] reserved
--
--   0x04  REP_COUNT  [R/W]
--           bit[31:0]  replay count (ignored when infinite=1)
--                      must be written BEFORE writing CTRL mode=1
--
--   0x08  STATUS     [R]
--           bit[0]  busy   1 while replay running
--           bit[1]  done   1 when finite replay complete
--
--   0x0C  REP_DONE   [R]
--           bit[31:0]  replays completed in current/last run
--
-- ctrl_written pulses for one s_axi_aclk cycle on every CTRL write.
-- REP_COUNT writes do NOT pulse ctrl_written.
-- stat_busy / stat_done / stat_rep_done are presented live on s_axi_aclk
-- (after CDC) — no additional latching here.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_slave is
  generic (
    C_S_AXI_ADDR_WIDTH : integer := 5;
    C_S_AXI_DATA_WIDTH : integer := 32
  );
  port (
    -- AXI-Lite clock / reset  (pl_clk0 domain)
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;

    -- AXI-Lite write address channel
    s_axi_awaddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;

    -- AXI-Lite write data channel
    s_axi_wdata   : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    s_axi_wstrb   : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;

    -- AXI-Lite write response channel
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;

    -- AXI-Lite read address channel
    s_axi_araddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;

    -- AXI-Lite read data channel
    s_axi_rdata   : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    -- -------------------------------------------------------------------------
    -- Control outputs  →  cdc_sync  →  replay_ctrl_bram
    -- All on s_axi_aclk.  cdc_sync re-times them into clk_dac0.
    -- -------------------------------------------------------------------------
    ctrl_mode      : out std_logic;
    ctrl_infinite  : out std_logic;
    ctrl_rep_count : out unsigned(31 downto 0);
    ctrl_written   : out std_logic;
      -- One-cycle pulse on s_axi_aclk whenever CTRL register is written.
      -- cdc_sync converts this to a one-cycle pulse on clk_dac0.

    -- -------------------------------------------------------------------------
    -- Status inputs  ←  cdc_sync  ←  replay_ctrl_bram
    -- These arrive already synchronised into s_axi_aclk by cdc_sync.
    -- -------------------------------------------------------------------------
    stat_busy      : in  std_logic;
    stat_done      : in  std_logic;
    stat_rep_done  : in  unsigned(31 downto 0)
  );
end entity axi_slave;

architecture rtl of axi_slave is

  signal reg_ctrl      : std_logic_vector(31 downto 0) := (others => '0');
  signal reg_rep_count : std_logic_vector(31 downto 0) := (others => '0');

  signal aw_ready    : std_logic := '0';
  signal w_ready     : std_logic := '0';
  signal b_valid     : std_logic := '0';
  signal aw_addr_lat : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal aw_pending  : std_logic := '0';

  signal ar_ready    : std_logic := '0';
  signal r_valid     : std_logic := '0';
  signal r_data      : std_logic_vector(31 downto 0) := (others => '0');
  signal ar_addr_lat : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');

  signal ctrl_wr_pulse : std_logic := '0';

begin

  -- ===========================================================================
  -- WRITE PATH
  -- ===========================================================================
  process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        aw_ready      <= '0';
        w_ready       <= '0';
        b_valid       <= '0';
        aw_pending    <= '0';
        aw_addr_lat   <= (others => '0');
        reg_ctrl      <= (others => '0');
        reg_rep_count <= (others => '0');
        ctrl_wr_pulse <= '0';
      else
        ctrl_wr_pulse <= '0';
        aw_ready      <= '0';
        w_ready       <= '0';

        -- AW channel: latch address
        if s_axi_awvalid = '1' and aw_pending = '0' and aw_ready = '0' then
          aw_ready    <= '1';
          aw_addr_lat <= s_axi_awaddr;
          aw_pending  <= '1';
        end if;

        -- W channel: write register once address is held
        if s_axi_wvalid = '1' and aw_pending = '1' and w_ready = '0' then
          w_ready    <= '1';
          aw_pending <= '0';

          case aw_addr_lat(3 downto 2) is
            when "00" =>  -- 0x00 CTRL
              if s_axi_wstrb(0) = '1' then reg_ctrl( 7 downto  0) <= s_axi_wdata( 7 downto  0); end if;
              if s_axi_wstrb(1) = '1' then reg_ctrl(15 downto  8) <= s_axi_wdata(15 downto  8); end if;
              if s_axi_wstrb(2) = '1' then reg_ctrl(23 downto 16) <= s_axi_wdata(23 downto 16); end if;
              if s_axi_wstrb(3) = '1' then reg_ctrl(31 downto 24) <= s_axi_wdata(31 downto 24); end if;
              ctrl_wr_pulse <= '1';

            when "01" =>  -- 0x04 REP_COUNT  (no ctrl_written pulse)
              if s_axi_wstrb(0) = '1' then reg_rep_count( 7 downto  0) <= s_axi_wdata( 7 downto  0); end if;
              if s_axi_wstrb(1) = '1' then reg_rep_count(15 downto  8) <= s_axi_wdata(15 downto  8); end if;
              if s_axi_wstrb(2) = '1' then reg_rep_count(23 downto 16) <= s_axi_wdata(23 downto 16); end if;
              if s_axi_wstrb(3) = '1' then reg_rep_count(31 downto 24) <= s_axi_wdata(31 downto 24); end if;

            when others => null;  -- 0x08 STATUS, 0x0C REP_DONE are read-only
          end case;
        end if;

        -- B channel: response
        if w_ready = '1' then
          b_valid <= '1';
        elsif s_axi_bready = '1' and b_valid = '1' then
          b_valid <= '0';
        end if;
      end if;
    end if;
  end process;

  -- ===========================================================================
  -- READ PATH
  -- STATUS and REP_DONE wired live from stat_* inputs (already in this domain)
  -- ===========================================================================
  process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        ar_ready    <= '0';
        r_valid     <= '0';
        r_data      <= (others => '0');
        ar_addr_lat <= (others => '0');
      else
        ar_ready <= '0';

        if s_axi_arvalid = '1' and ar_ready = '0' and r_valid = '0' then
          ar_ready    <= '1';
          ar_addr_lat <= s_axi_araddr;
        end if;

        if ar_ready = '1' then
          r_valid <= '1';
          case ar_addr_lat(3 downto 2) is
            when "00"   => r_data <= reg_ctrl;
            when "01"   => r_data <= reg_rep_count;
            when "10"   => r_data <= (31 downto 2 => '0') & stat_done & stat_busy;
            when "11"   => r_data <= std_logic_vector(stat_rep_done);
            when others => r_data <= (others => '0');
          end case;
        elsif s_axi_rready = '1' and r_valid = '1' then
          r_valid <= '0';
        end if;
      end if;
    end if;
  end process;

  -- ===========================================================================
  -- Port assignments
  -- ===========================================================================
  s_axi_awready <= aw_ready;
  s_axi_wready  <= w_ready;
  s_axi_bresp   <= "00";
  s_axi_bvalid  <= b_valid;
  s_axi_arready <= ar_ready;
  s_axi_rdata   <= r_data;
  s_axi_rresp   <= "00";
  s_axi_rvalid  <= r_valid;

  ctrl_mode      <= reg_ctrl(0);
  ctrl_infinite  <= reg_ctrl(1);
  ctrl_rep_count <= unsigned(reg_rep_count);
  ctrl_written   <= ctrl_wr_pulse;

end architecture rtl;
