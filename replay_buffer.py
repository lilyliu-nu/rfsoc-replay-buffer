# =============================================================================
# replay_buffer.py
#
# PYNQ driver for the replay_buf_top IP on the strath-sdr rfsoc_radio overlay.
#
# Usage pattern (matches tested working behaviour):
#
#   from rfsoc_radio.overlay import RadioOverlay
#   from replay_buffer import ReplayBuffer
#
#   ol  = RadioOverlay(bitfile_name='replay_rfsoc_radio.bit', run_test=True)
#   rb  = ReplayBuffer(ol)
#
#   # Load BRAM by sending once through the transmitter
#   ol.radio_transmitter.data('Hello World!\r')
#   rb.load_via_transmitter()        # calls transmitter.start() in passthrough
#
#   # Replay
#   rb.replay_finite(10)
#   rb.wait()
#
#   rb.replay_infinite()
#   time.sleep(2)
#   rb.stop()
# =============================================================================

import time
from pynq import MMIO


class ReplayBuffer:
    """
    Driver for replay_buf_top IP on the strath-sdr rfsoc_radio overlay.

    Does not allocate its own DMA buffer. Instead relies on the existing
    RadioOverlay transmitter infrastructure to load the BRAM — matching
    the verified working test procedure.

    Register map (base from ol.ip_dict['replay_buf_top_0']['phys_addr']):
      0x00  CTRL       [R/W]  bit0=mode (0=passthrough,1=replay), bit1=infinite
      0x04  REP_COUNT  [R/W]  target repetitions (finite mode)
      0x08  STATUS     [R]    bit0=busy, bit1=done
      0x0C  REP_DONE   [R]    completed repetitions

    Parameters
    ----------
    overlay  : RadioOverlay
        Loaded strath-sdr RadioOverlay instance.
    ip_name  : str
        Name of replay buffer IP in ip_dict. Default 'replay_buf_top_0'.
    """

    # Register offsets
    CTRL      = 0x00
    REP_COUNT = 0x04
    STATUS    = 0x08
    REP_DONE  = 0x0C

    # CTRL bits
    MODE_REPLAY = (1 << 0)
    INFINITE    = (1 << 1)

    # STATUS bits
    BUSY = (1 << 0)
    DONE = (1 << 1)

    def __init__(self, overlay, ip_name='replay_buf_top_0'):
        if ip_name not in overlay.ip_dict:
            available = list(overlay.ip_dict.keys())
            raise ValueError(
                f"'{ip_name}' not found in overlay.\n"
                f"Available IPs: {available}\n"
                f"Pass ip_name=<correct name> to ReplayBuffer().")

        base        = overlay.ip_dict[ip_name]['phys_addr']
        self._mmio  = MMIO(base, length=0x20)
        self._tx    = overlay.radio_transmitter

        # Ensure passthrough on init
        self._mmio.write(self.CTRL, 0x0)

        print(f"ReplayBuffer '{ip_name}' at 0x{base:08X}")
        print(f"  {self}")

    # =========================================================================
    # Loading the BRAM
    # =========================================================================

    def load_via_transmitter(self):
        """
        Load BRAM by firing one transmission through the existing transmitter.

        Call ol.radio_transmitter.data('your message') BEFORE this.
        The BRAM is written as a side effect of passthrough mode.
        The transmitter also sends the data once to the DAC during this call.

        This matches the verified working test procedure:
            ol.radio_transmitter.data('Hello World!\\r')
            rb.load_via_transmitter()
        """
        self._mmio.write(self.CTRL, 0x0)   # ensure passthrough
        self._tx.start()
        # No wait needed — transmitter.start() in single mode is synchronous

    # =========================================================================
    # Replay control
    # =========================================================================

    def replay_finite(self, n):
        """
        Replay BRAM contents n times then stop.

        Write REP_COUNT before CTRL — required by RTL register ordering.
        Non-blocking. Use wait() to block until done.

        Parameters
        ----------
        n : int   number of complete replays to perform
        """
        self._mmio.write(self.REP_COUNT, int(n))
        self._mmio.write(self.CTRL, self.MODE_REPLAY)
        print(f"Finite replay: {n} reps.")

    def replay_infinite(self):
        """
        Replay BRAM contents indefinitely. Call stop() to end.
        """
        self._mmio.write(self.REP_COUNT, 0)
        self._mmio.write(self.CTRL, self.MODE_REPLAY | self.INFINITE)
        print("Infinite replay started. Call stop() to end.")

    def stop(self):
        """
        Return to passthrough mode. Stops replay immediately.
        Also stops the transmitter monitor if it is running.
        """
        self._mmio.write(self.CTRL, 0x0)
        try:
            self._tx.stop()
        except Exception:
            pass
        print(f"Stopped. reps_done={self.reps_done}")

    def wait(self, timeout_s=60.0, poll_interval_s=0.05):
        """
        Block until finite replay completes.

        Returns
        -------
        int   number of replays completed.
        """
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            if self._mmio.read(self.STATUS) & self.DONE:
                n = self.reps_done
                print(f"Replay done. Reps: {n}")
                return n
            time.sleep(poll_interval_s)
        raise TimeoutError(
            f"Replay did not complete in {timeout_s}s. "
            f"STATUS=0x{self._mmio.read(self.STATUS):08X}")

    # =========================================================================
    # Properties
    # =========================================================================

    @property
    def is_busy(self):
        return bool(self._mmio.read(self.STATUS) & self.BUSY)

    @property
    def is_done(self):
        return bool(self._mmio.read(self.STATUS) & self.DONE)

    @property
    def reps_done(self):
        return self._mmio.read(self.REP_DONE)

    @property
    def mode(self):
        ctrl = self._mmio.read(self.CTRL)
        if not (ctrl & self.MODE_REPLAY):
            return 'passthrough'
        return 'infinite' if (ctrl & self.INFINITE) else 'finite'

    def __repr__(self):
        s = self._mmio.read(self.STATUS)
        return (f"ReplayBuffer(mode={self.mode}  "
                f"busy={bool(s & self.BUSY)}  "
                f"done={bool(s & self.DONE)}  "
                f"reps_done={self.reps_done})")
