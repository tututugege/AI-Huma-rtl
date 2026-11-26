// Tapeout-oriented chip_top Verilator testbench (rtl/tb/soc/soc_tb.cpp):
//   - Reuses SimDDR + PhysMemory with parameterized AXI4 DDR data width (64 / 128 / 256-bit)
//   - Drives real asynchronous clk_rtc (default 1 edge / 16 core cycles)
//   - Samples real serial uart_txd bit-by-bit (8N1, 16x oversampled) and prints live console
//   - Supports pin-level serial uart_rxd injection, external ext_irq[6:0] stimulus, dynamic
//     boot_mode strap updates, UART stop/fail/expect matching, and silent-park checking
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "Vchip_top.h"
#include "verilated.h"
#ifdef SOC_TB_TRACE
#include "verilated_vcd_c.h"
#endif

#include "PhysMemory.h"
#include "SimDDR.h"
#include "config.h"

#ifndef CHIP_DDR_DATA_W
#define CHIP_DDR_DATA_W 64
#endif

long long sim_time = 0;

namespace {

// Bit-level 8N1 serial receiver sampling chip_top::uart_txd
struct UartMonitor {
  uint32_t bit_ticks = 16;   // divisor * 16 (default divisor=1 -> 16 core cycles/bit)
  int      state     = 0;    // 0=idle, 1=start, 2=data, 3=stop
  uint32_t cnt       = 0;
  int      bit_idx   = 0;
  uint8_t  shift     = 0;
  uint8_t  prev_txd  = 1;
  std::string captured;

  void step(uint8_t txd, bool echo_stdout) {
    switch (state) {
      case 0:
        if (prev_txd == 1 && txd == 0) { state = 1; cnt = (bit_ticks / 2) - 1; }
        break;
      case 1:
        if (cnt == 0) {
          if (txd == 0) { state = 2; bit_idx = 0; shift = 0; cnt = bit_ticks - 1; }
          else          { state = 0; }
        } else --cnt;
        break;
      case 2:
        if (cnt == 0) {
          shift |= uint8_t((txd & 1u) << bit_idx);
          if (bit_idx == 7) state = 3;
          else              ++bit_idx;
          cnt = bit_ticks - 1;
        } else --cnt;
        break;
      case 3:
        if (cnt == 0) {
          state = 0;
          if (txd == 1) {
            char c = static_cast<char>(shift);
            captured.push_back(c);
            if (echo_stdout) { std::fputc(c, stdout); std::fflush(stdout); }
          }
        } else --cnt;
        break;
    }
    prev_txd = txd;
  }
};

// Bit-level 8N1 serial transmitter driving chip_top::uart_rxd
struct UartDriver {
  uint32_t    bit_ticks = 16;
  std::string queue;
  size_t      pos       = 0;
  bool        active    = false;
  uint16_t    shift     = 0x3FF;
  int         bits_left = 0;
  uint32_t    cnt       = 0;

  uint8_t step() {
    if (!active) {
      if (pos < queue.size()) {
        uint8_t b = static_cast<uint8_t>(queue[pos++]);
        shift     = uint16_t(0x200u | (uint16_t(b) << 1));
        bits_left = 10;
        cnt       = bit_ticks - 1;
        active    = true;
      } else return 1;
    }
    uint8_t out = uint8_t(shift & 1u);
    if (cnt == 0) {
      shift >>= 1;
      shift |= 0x200u;
      if (--bits_left == 0) active = false;
      else cnt = bit_ticks - 1;
    } else --cnt;
    return out;
  }
};

struct PinTrigger {
  std::string match;
  uint32_t    val   = 0;
  bool        fired = false;
};

bool parse_trigger(const char *arg, PinTrigger &out) {
  const char *sep = std::strrchr(arg, ':');
  if (!sep || sep == arg || sep[1] == '\0') return false;
  out.match.assign(arg, static_cast<size_t>(sep - arg));
  out.val   = static_cast<uint32_t>(std::strtoul(sep + 1, nullptr, 0));
  out.fired = false;
  return true;
}

void load_ddr_image(const char *path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) { std::fprintf(stderr, "soc_tb: cannot open %s\n", path); std::exit(2); }
  f.seekg(0, std::ios::end);
  std::streamsize sz = f.tellg();
  f.seekg(0, std::ios::beg);
  if (sz <= 0 || !f.read(reinterpret_cast<char *>(pmem_ram_ptr()), sz)) {
    std::fprintf(stderr, "soc_tb: read failed for %s\n", path);
    std::exit(2);
  }
  std::fprintf(stderr, "soc_tb: loaded %lld bytes into DDR @ 0x80000000 (DDR_DATA_W=%d, real RTL BootROM + AXI4)\n",
               (long long)sz, CHIP_DDR_DATA_W);
}

inline void ddr_rdata_to_top(const sim_ddr::axi_data_t &src, Vchip_top &top) {
#if CHIP_DDR_DATA_W == 64
  uint64_t lo = axi_compat::get_u32(src, 0);
  uint64_t hi = axi_compat::get_u32(src, 1);
  top.ddr_rdata = (hi << 32) | lo;
#elif CHIP_DDR_DATA_W == 128
  for (int w = 0; w < 4; ++w) top.ddr_rdata[w] = axi_compat::get_u32(src, w);
#else
  for (int w = 0; w < 8; ++w) top.ddr_rdata[w] = axi_compat::get_u32(src, w);
#endif
}

inline void top_wdata_to_ddr(const Vchip_top &top, sim_ddr::axi_data_t &dst) {
#if CHIP_DDR_DATA_W == 64
  axi_compat::set_u32(dst, 0, uint32_t(top.ddr_wdata & 0xFFFFFFFFu));
  axi_compat::set_u32(dst, 1, uint32_t(top.ddr_wdata >> 32));
#elif CHIP_DDR_DATA_W == 128
  for (int w = 0; w < 4; ++w) axi_compat::set_u32(dst, w, top.ddr_wdata[w]);
#else
  for (int w = 0; w < 8; ++w) axi_compat::set_u32(dst, w, top.ddr_wdata[w]);
#endif
}

}  // namespace

int main(int argc, char **argv) {
  setvbuf(stdout, nullptr, _IOLBF, 0);
  const char *img_path       = nullptr;
  uint64_t    max_cyc        = 2000000;
  int         boot_mode      = 0;
  uint32_t    rtc_div        = 16;
  uint32_t    uart_div       = 1;
  uint64_t    uart_rx_delay  = 500;
  uint64_t    prog_step      = 0;
  bool        expect_silent  = false;
  std::string stop_str;
  std::string fail_str       = ":FAIL]";
  std::string uart_rx;
  std::string uart_rx_on_str;
  std::vector<std::string> expect_strs;
  std::vector<PinTrigger>  ext_irq_trigs;
  std::vector<PinTrigger>  boot_mode_trigs;

  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--boot-mode") && i + 1 < argc)        boot_mode = std::atoi(argv[++i]);
    else if (!std::strcmp(argv[i], "--max-cycles") && i + 1 < argc)  max_cyc   = std::strtoull(argv[++i], nullptr, 0);
    else if (!std::strcmp(argv[i], "--rtc-div") && i + 1 < argc)     rtc_div   = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 0));
    else if (!std::strcmp(argv[i], "--uart-div") && i + 1 < argc)    uart_div  = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 0));
    else if (!std::strcmp(argv[i], "--uart-rx-delay") && i + 1 < argc) uart_rx_delay = std::strtoull(argv[++i], nullptr, 0);
    else if (!std::strcmp(argv[i], "--uart-rx-on-str") && i + 1 < argc) uart_rx_on_str = argv[++i];
    else if (!std::strcmp(argv[i], "--progress") && i + 1 < argc)    prog_step = std::strtoull(argv[++i], nullptr, 0);
    else if (!std::strcmp(argv[i], "--stop-str") && i + 1 < argc)    stop_str  = argv[++i];
    else if (!std::strcmp(argv[i], "--fail-str") && i + 1 < argc)    fail_str  = argv[++i];
    else if (!std::strcmp(argv[i], "--expect-str") && i + 1 < argc)  expect_strs.emplace_back(argv[++i]);
    else if (!std::strcmp(argv[i], "--uart-rx") && i + 1 < argc)     uart_rx   = argv[++i];
    else if (!std::strcmp(argv[i], "--expect-silent"))               expect_silent = true;
    else if (!std::strcmp(argv[i], "--ext-irq-on-str") && i + 1 < argc) {
      PinTrigger t;
      if (!parse_trigger(argv[++i], t)) { std::fprintf(stderr, "soc_tb: bad --ext-irq-on-str\n"); return 2; }
      ext_irq_trigs.push_back(t);
    } else if (!std::strcmp(argv[i], "--boot-mode-on-str") && i + 1 < argc) {
      PinTrigger t;
      if (!parse_trigger(argv[++i], t)) { std::fprintf(stderr, "soc_tb: bad --boot-mode-on-str\n"); return 2; }
      boot_mode_trigs.push_back(t);
    } else if (argv[i][0] != '-') {
      if (!img_path) img_path = argv[i];
      else           max_cyc  = std::strtoull(argv[i], nullptr, 0);
    }
  }
  if (!img_path) {
    std::fprintf(stderr,
      "usage: soc_tb <ddr_image.bin> [--max-cycles N] [--boot-mode 0..3] [--rtc-div N] [--uart-div N]\n"
      "              [--stop-str STR] [--fail-str STR] [--expect-str STR] [--expect-silent]\n"
      "              [--uart-rx STR] [--uart-rx-delay N] [--uart-rx-on-str STR]\n"
      "              [--ext-irq-on-str STR:HEXMASK] [--boot-mode-on-str STR:MODE]\n");
    return 2;
  }

  Verilated::commandArgs(argc, argv);
  if (!pmem_init()) { std::fprintf(stderr, "soc_tb: pmem_init failed\n"); return 2; }
  load_ddr_image(img_path);

  sim_ddr::SimDDR ddr;
  ddr.init();

  Vchip_top top;
  top.clk_core      = 0;
  top.clk_rtc       = 0;
  top.por_rst_n     = 0;
  top.dft_test_mode = 0;
  top.dft_scan_en   = 0;
  top.boot_mode     = static_cast<uint8_t>(boot_mode & 3);
  top.uart_rxd      = 1;
  top.ext_irq       = 0;
  top.ddr_arready   = 0;
  top.ddr_rvalid    = 0;
  top.ddr_rid       = 0;
  top.ddr_rresp     = 0;
  top.ddr_rlast     = 0;
  top.ddr_awready   = 0;
  top.ddr_wready    = 0;
  top.ddr_bvalid    = 0;
  top.ddr_bid       = 0;
  top.ddr_bresp     = 0;

  UartMonitor umon;
  umon.bit_ticks = (uart_div == 0 ? 1u : uart_div) * 16u;
  UartDriver udrv;
  udrv.bit_ticks = umon.bit_ticks;
  udrv.queue     = uart_rx;
  bool uart_rx_armed = uart_rx_on_str.empty();

  // 8 cycles async POR assertion + 4 cycles sync deassertion
  for (int i = 0; i < 12; ++i) {
    top.por_rst_n = (i >= 8) ? 1 : 0;
    top.clk_core  = 0; top.eval();
    top.clk_core  = 1; top.eval();
  }

  int rc = 0;
  bool hit_stop = false;

  for (uint64_t cyc = 0; cyc < max_cyc; ++cyc) {
    sim_time = static_cast<long long>(cyc);

    // 1. DDR combinational outputs -> chip_top inputs (native SimDDR rlast & rresp!)
    ddr.comb_outputs();
    top.ddr_arready = ddr.io.ar.arready;
    top.ddr_rvalid  = ddr.io.r.rvalid;
    top.ddr_rid     = ddr.io.r.rid;
    ddr_rdata_to_top(ddr.io.r.rdata, top);
    top.ddr_rresp   = ddr.io.r.rresp;
    top.ddr_rlast   = ddr.io.r.rlast;
    top.ddr_awready = ddr.io.aw.awready;
    top.ddr_wready  = ddr.io.w.wready;
    top.ddr_bvalid  = ddr.io.b.bvalid;
    top.ddr_bid     = ddr.io.b.bid;
    top.ddr_bresp   = ddr.io.b.bresp;

    if (rtc_div > 0 && (cyc % rtc_div) == 0) top.clk_rtc ^= 1;
    top.uart_rxd = (uart_rx_armed && cyc > uart_rx_delay) ? udrv.step() : 1;

    top.clk_core = 0;
    top.eval();

    // 2. chip_top outputs -> DDR inputs
    ddr.io.ar.arvalid = top.ddr_arvalid;
    ddr.io.ar.arid    = top.ddr_arid;
    ddr.io.ar.araddr  = top.ddr_araddr;
    ddr.io.ar.arlen   = top.ddr_arlen;
    ddr.io.ar.arsize  = top.ddr_arsize;
    ddr.io.ar.arburst = top.ddr_arburst;
    ddr.io.r.rready   = top.ddr_rready;
    ddr.io.aw.awvalid = top.ddr_awvalid;
    ddr.io.aw.awid    = top.ddr_awid;
    ddr.io.aw.awaddr  = top.ddr_awaddr;
    ddr.io.aw.awlen   = top.ddr_awlen;
    ddr.io.aw.awsize  = top.ddr_awsize;
    ddr.io.aw.awburst = top.ddr_awburst;
    ddr.io.w.wvalid   = top.ddr_wvalid;
    top_wdata_to_ddr(top, ddr.io.w.wdata);
    ddr.io.w.wstrb    = top.ddr_wstrb;
    ddr.io.w.wlast    = top.ddr_wlast;
    ddr.io.b.bready   = top.ddr_bready;

    ddr.comb_inputs();
    ddr.seq();

    // 3. Rising edge of clk_core
    top.clk_core = 1;
    top.eval();

    // 4. Sample real serial uart_txd bit
    size_t prev_len = umon.captured.size();
    umon.step(top.uart_txd, true);

    if (umon.captured.size() != prev_len) {
      if (!uart_rx_armed && umon.captured.find(uart_rx_on_str) != std::string::npos) {
        uart_rx_armed = true;
        uart_rx_delay = cyc;
        std::fprintf(stderr, "\n[soc_tb cyc=%llu] armed uart_rxd stream (%zu bytes)\n",
                     (unsigned long long)cyc, udrv.queue.size());
      }
      for (auto &t : ext_irq_trigs) {
        if (!t.fired && umon.captured.find(t.match) != std::string::npos) {
          t.fired     = true;
          top.ext_irq = static_cast<uint8_t>(t.val & 0x7Fu);
          std::fprintf(stderr, "\n[soc_tb cyc=%llu] ext_irq <= 0x%02x (trigger \"%s\")\n",
                       (unsigned long long)cyc, top.ext_irq, t.match.c_str());
        }
      }
      for (auto &t : boot_mode_trigs) {
        if (!t.fired && umon.captured.find(t.match) != std::string::npos) {
          t.fired       = true;
          top.boot_mode = static_cast<uint8_t>(t.val & 3u);
          std::fprintf(stderr, "\n[soc_tb cyc=%llu] boot_mode <= %u (trigger \"%s\")\n",
                       (unsigned long long)cyc, top.boot_mode, t.match.c_str());
        }
      }
    }

    if (prog_step > 0 && cyc > 0 && (cyc % prog_step) == 0) {
      std::fprintf(stderr, "\n[soc_tb cyc=%llu uart_bytes=%zu]\n",
                   (unsigned long long)cyc, umon.captured.size());
    }

    if (!fail_str.empty() && umon.captured.find(fail_str) != std::string::npos) {
      std::fprintf(stderr, "\nsoc_tb: FAIL marker detected at cycle %llu\n", (unsigned long long)cyc);
      rc = 1; hit_stop = true; break;
    }
    if (!stop_str.empty() && umon.captured.find(stop_str) != std::string::npos) {
      std::fprintf(stderr, "\nsoc_tb: matched stop string \"%s\" at cycle %llu\n",
                   stop_str.c_str(), (unsigned long long)cyc);
      rc = 0; hit_stop = true; break;
    }
  }

  if (!stop_str.empty() && !hit_stop) {
    std::fprintf(stderr, "\nsoc_tb: TIMEOUT after %llu cycles without \"%s\"\n",
                 (unsigned long long)max_cyc, stop_str.c_str());
    rc = 1;
  }
  if (expect_silent && !umon.captured.empty()) {
    std::fprintf(stderr, "\nsoc_tb: expected silent console, got %zu UART bytes\n", umon.captured.size());
    rc = 1;
  }
  if (rc == 0) {
    for (const auto &es : expect_strs) {
      if (umon.captured.find(es) == std::string::npos) {
        std::fprintf(stderr, "\nsoc_tb: missing expected string \"%s\"\n", es.c_str());
        rc = 1;
      }
    }
  }

  pmem_release();
  return rc;
}
