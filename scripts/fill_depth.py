import re,os,sys
"""Fill the 'depth:' line and the section-6 placeholder of docs/modules/*.md from the single-module synthesis results
(build/synth_<tag>/<module>.ltp, made by scripts/synth_depth.sh).  Rerun it after measuring more modules: modules without a result are skipped.
"""
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def ltp(tag,mod):
    p=f'{ROOT}/build/synth_{tag}/{mod}.ltp'
    if not os.path.exists(p): return None
    t=open(p).read()
    m=re.search(r'length=(\d+)',t)
    if not m: return None
    nodes=[l for l in t.splitlines() if re.match(r'\s*(\d+|ff):',l)]
    def nm(l):
        x=re.sub(r'^\s*(\d+|ff):\s*','',l); x=re.sub(r'\s*\(via.*','',x).strip()
        return x
    named=[nm(l) for l in nodes if not nm(l).startswith('$')]
    return int(m.group(1)), (named[0] if named else None), (named[-1] if named else None)
# doc -> (tag, module, label)
M={'tlb_mmu':('dp1','tlb_mmu','tlb_mmu'),'dispatch':('dp1','dispatch','dispatch'),'ren':('dp1','ren','ren'),'idu':('dp1','idu','idu'),
 'pre_idu_queue':('dp1','pre_idu_queue','pre_idu_queue'),'exu_ctrl':('dp1','exu_ctrl','exu_ctrl'),'exu_fu':('dp2','exu','exu（含 exu_ctrl 和全部功能单元）'),
 'prf':('dp1','prf','prf'),'csr':('dp1','csr','csr'),'icache':('dp1','icache','icache'),'front_ctrl':('dp1','front_ctrl','front_ctrl'),
 'front_fifos':('dp1','fetch_addr_fifo','fetch_addr_fifo；ptab、inst_fifo、front2back_fifo 更浅'),'predecode':('dp1','predecode','predecode；predecode_checker 22 层'),
 'dcache':('dp2','dcache','dcache'),'dcache_pf':('dp1','dcache_pf','dcache_pf'),'mem_route':('dp1','mem_route','mem_route'),'ptw_walk':('dp1','ptw_walk','ptw_walk'),
 'mem_top':('dp2','mem_top','mem_top'),'peripheral_axi':('dp1','peripheral_axi','peripheral_axi'),'axi_interconnect':('dp1','axi_interconnect','axi_interconnect'),
 'axi_llc':('dp2','axi_llc','axi_llc'),'axi_cpu_port_adapter':('dp1','axi_cpu_port_adapter','axi_cpu_port_adapter'),'axi_subsys':('dp1','axi_subsys','axi_subsys（含互连和 LLC）'),
 'pmu':('dp1','pmu','pmu'),'bpu':('dp2','bpu','bpu')}
PH=["`depth: 待测（由协调者补）`","depth: 待测（由协调者补）；子块已测的数字见第 6 节","depth: 待测（由协调者补）","depth 待测（由协调者补）","**待测**（由协调者补）"]
done=[];skip=[]
for doc,(tag,mod,label) in M.items():
    r=ltp(tag,mod)
    p=f'{ROOT}/docs/modules/{doc}.md'
    if not r: skip.append(doc); continue
    n,a,b=r
    s=open(p).read()
    # front matter
    s=re.sub(r'(?m)^depth:.*$',f'depth: {n} 层（{label}，单模块综合，2026-11-18，`SYNTH_ABC="strash;balance;map"`，生成门代理，见第 6 节）',s,count=1)
    path=f"综合报告给出的最长路径：从 `{a}` 到 `{b}`。" if a and b else ""
    msg=f"单模块综合深度 **{n} 层**（{label}；2026-11-18；`scripts/synth_depth.sh`，`SYNTH_ABC=\"strash;balance;map\"`，生成门代理，不是时序）。{path}"
    body_start=s.index('## 6.')
    head,body=s[:body_start],s[body_start:]
    first=True
    for ph in PH:
        if ph in body:
            body=body.replace(ph,msg if first else "",1); first=False
    open(p,'w').write(head+body)
    done.append((doc,n))
print("filled:",done)
print("skipped (no measurement yet):",skip)
