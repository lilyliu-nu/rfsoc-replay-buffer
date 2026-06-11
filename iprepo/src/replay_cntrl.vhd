--- Replay Control
-- puts 1 cycle delay between TX and DMA
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity replay_cntrl is 
    generic (
        AXIS_TDATA_WIDTH : integer range 8 to 1024 := 8;
        BRAM_ADDR_WIDTH: integer range 8 to 1024 := 16;
        FORWARD_TLAST: boolean := true
    );
    port(
        aclk: in std_logic;
        aresetn: in std_logic;

        -- control from ps to axi slave
        cntrl_mode: in std_logic;
        cntrl_infi: in std_logic;
        cntrl_reps: in unsigned(31 downto 0);
        cntrl_written: in std_logic; 
        
        -- status to axi slave
        stat_busy      : out std_logic;
        stat_done      : out std_logic;
        stat_rep_done  : out unsigned(31 downto 0);
        
         --- MM2S Stream from DMA
        s_axis_tdata : in std_logic_vector (AXIS_TDATA_WIDTH-1 downto 0);
        s_axis_tvalid : in std_logic;
        s_axis_tlast : in std_logic;

        s_axis_tready : out std_logic;

        --- MM2S Stream to Transmitter
        m_axis_tdata : out std_logic_vector (AXIS_TDATA_WIDTH-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tlast : out std_logic;

        m_axis_tready : in std_logic
        
    );
end entity replay_cntrl;

architecture behavioral of replay_cntrl is
    -- signals
    -- FSM signals
    type state_t is (    
        REPLAY,
        IDLE
    );
    signal state_next    : state_t := IDLE;
    signal state : state_t;
    
    -- combinational axi4-stream output signals
    signal m_axis_tlast_comb : std_logic;

    -- replay rep counters
    signal count, count_comb, reps, reps_comb : unsigned(31 downto 0);
    signal rdone, rdone_comb, infi, infi_comb : std_logic;

    signal raddr_bram, waddr_bram, waddr_comb, raddr_comb : std_logic_vector(BRAM_ADDR_WIDTH-1 downto 0);
    signal last_addr, last_addr_comb : std_logic_vector(BRAM_ADDR_WIDTH-1 downto 0);
    signal bram_out, bram_in : std_logic_vector(AXIS_TDATA_WIDTH-1 downto 0);
    signal we_bram, rvalid, rvalid_comb: std_logic; -- combinationally driven
    component bram is 
        generic(
            BRAM_DATA_WIDTH : integer;
            BRAM_ADDR_WIDTH : integer
        );
        port (
            q : out std_logic_vector(BRAM_DATA_WIDTH-1 downto 0);
            d : in std_logic_vector(BRAM_DATA_WIDTH-1 downto 0);
            raddr : in std_logic_vector(BRAM_ADDR_WIDTH-1 downto 0);
            waddr : in std_logic_vector(BRAM_ADDR_WIDTH-1 downto 0);
            we : in std_logic;
            clk : in std_logic
        );
    end component;
begin
    buff : bram 
    generic map (
        BRAM_DATA_WIDTH => AXIS_TDATA_WIDTH,
        BRAM_ADDR_WIDTH => BRAM_ADDR_WIDTH
    )
    port map (
        q => bram_out,
        d => bram_in,--s_axis_tdata,
        raddr => raddr_bram, -- remember to toggle m_tvalid
        waddr => waddr_bram,
        we => we_bram,--s_axis_tvalid, -- we always when tvalid
        clk => aclk
    );

    process (aclk)
    begin
        if (aclk'event and aclk = '1') then
            if (aresetn = '0') then
                count <= (others => '0');
                waddr_bram <= (others => '0');
                raddr_bram <= (others => '0');
                last_addr <= (others => '0');
                rvalid <= '0';
                state <= IDLE;
                rdone <= '0';
                reps <= (others=> '0');
                infi <= '0';
            else 
                state <= state_next;
                last_addr <= last_addr_comb;
                waddr_bram <= waddr_comb;
                raddr_bram <= raddr_comb;
                count <= count_comb;
                rvalid <= rvalid_comb;
                rdone <= rdone_comb;
                reps <= reps_comb;
                infi <= infi_comb;
            end if;
        end if;
    end process;

    fsm_logic: process (state, s_axis_tdata, s_axis_tvalid, s_axis_tlast, m_axis_tready, 
        waddr_bram, raddr_bram, last_addr, count, cntrl_mode, cntrl_written, cntrl_infi, cntrl_reps) 
    begin
        state_next <= state;
        
        count_comb <= count;
        
        -- allows signals to pass through in all other states
        m_axis_tlast_comb <= s_axis_tlast;

        --other comb sigs
        waddr_comb <= waddr_bram;
        raddr_comb <= raddr_bram;
        last_addr_comb <= last_addr;
        we_bram <= '0';
        bram_in <= s_axis_tdata;
        
        rvalid_comb <= '0';
        reps_comb <= reps;
        rdone_comb <= rdone;
        infi_comb <= infi;
        case(state) is
            when IDLE => 
                if (s_axis_tvalid = '1') then
                    -- we is tvalid, so we are writing rn
                    bram_in <= s_axis_tdata;
                    we_bram <= '1';
                    waddr_comb <= std_logic_vector(unsigned(waddr_bram) + 1); 
                    if (s_axis_tlast = '1') then
                        last_addr_comb <= waddr_bram; -- maybe even asafety check if fill not completed for replay
                        waddr_comb <= (others => '0');
                    end if;
                end if;
                    
                if (cntrl_written = '1'and cntrl_mode = '1') then
                    state_next <= REPLAY;
                    reps_comb <= cntrl_reps;
                    infi_comb <= cntrl_infi;
                    raddr_comb <= (others => '0');
                    count_comb <= (others => '0');
                    rdone_comb <='0';
                end if;
--                if (cntrl_mode = '1' and rdone = '0') then
--                    state_next <= REPLAY;
--                end if;
            when REPLAY =>
                -- increment couunter, and m_tvalid
                if (m_axis_tready = '1') then   --input
                    raddr_comb <= std_logic_vector(unsigned(raddr_bram) + 1);
                    rvalid_comb <= '1'; -- one cycle dela
                    if (raddr_bram = std_logic_vector(unsigned(last_addr) +1)) then -- at last addr
                        m_axis_tlast_comb <= '1';
                        raddr_comb <= (others => '0');
                        rvalid_comb <='0';
                        count_comb <= count + 1;
                    end if;           
                end if;
                if (infi = '0' and count = reps) then
                    state_next <= IDLE;
                    rdone_comb <= '1';
                    last_addr_comb <= (others =>'0');
                end if;
                if (cntrl_written = '1' and cntrl_mode = '0')then
                    state_next <= IDLE;
                end if;
            when others => state_next <= IDLE; 
        end case; 
    end process fsm_logic;

    -- combinational 
    m_axis_tdata <= bram_out when (STATE = REPLAY) else s_axis_tdata;-- m_axis_tdata_comb; 
    m_axis_tvalid <= rvalid when (STATE=REPLAY) else s_axis_tvalid;
    m_axis_tlast <=  m_axis_tlast_comb when (FORWARD_TLAST) else '0';
    s_axis_tready <= m_axis_tready;
    
    stat_busy <= '1' when (STATE=REPLAY) else '0';
    stat_done <= rdone;
    stat_rep_done <= count;

end architecture behavioral;