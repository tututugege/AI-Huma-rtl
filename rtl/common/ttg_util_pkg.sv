`default_nettype none
// Ref: (new common package) shared helpers that several modules had their own copies of
// (docs/modules/common.md).
package ttg_util_pkg;
  import ttg_cfg_pkg::*;

  // a is younger than b in the ROB (index + wrap flag; the two are at most ROB_NUM apart)
  function automatic logic ttg_rob_younger(input logic [ROB_IDX_WIDTH-1:0] a_idx, input logic a_flag,
                                           input logic [ROB_IDX_WIDTH-1:0] b_idx, input logic b_flag);
    return (a_flag == b_flag) ? (a_idx > b_idx) : (a_idx < b_idx);
  endfunction

  // 4-way tree pseudo-LRU: bit 0 = root (1: next victim in ways 2..3), bit 1 = ways 0/1, bit 2 = ways 2/3
  function automatic logic [2:0] ttg_plru4_touch(input logic [2:0] p, input logic [1:0] way);
    logic [2:0] n;
    n    = p;
    n[0] = ~way[1];
    if (!way[1]) n[1] = ~way[0];
    else         n[2] = ~way[0];
    return n;
  endfunction

  function automatic logic [1:0] ttg_plru4_victim(input logic [2:0] p);
    return {p[0], p[0] ? p[2] : p[1]};
  endfunction
endpackage
`default_nettype wire
