library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
--  change declarations
entity bram is
    generic(
        BRAM_DATA_WIDTH : integer range 8 to 1024 := 8;
        BRAM_ADDR_WIDTH : integer range 8 to 1024 := 32
    );
    port (
        q : out std_logic_vector(BRAM_DATA_WIDTH-1 downto 0);
        d : in std_logic_vector(BRAM_DATA_WIDTH-1 downto 0);
        raddr : in std_logic_vector(BRAM_ADDR_WIDTH-1 downto 0);
        waddr : in std_logic_vector(BRAM_ADDR_WIDTH-1 downto 0);
        we : in std_logic;
        clk : in std_logic
    );
end bram;
architecture rtl of bram is
    type mem_type is array (0 to 2**BRAM_ADDR_WIDTH-1) of std_logic_vector (BRAM_DATA_WIDTH-1 downto 0);
    signal rd_addr : std_logic_vector(BRAM_ADDR_WIDTH-1 downto 0);
    signal mem : mem_type;
    begin
        q <= mem(to_integer(unsigned(rd_addr)));
        process (clk)
        begin
            if (rising_edge(clk)) then
                rd_addr <= raddr;
                if (we = '1') then
                    mem(to_integer(unsigned(waddr))) <= d;
                end if;
            end if;
        end process;
end rtl;