import sys,glob,collections
d=sys.argv[1]
tot=collections.Counter(); mx=collections.Counter(); progs=collections.defaultdict(list)
for f in sorted(glob.glob(d+'/*.stat')):
    n=f.split('/')[-1][:-5]
    for ln in open(f):
        _,k,v=ln.split(); v=int(v)
        if k.startswith('max_'): mx[k]=max(mx[k],v)
        else: tot[k]+=v
        if v and (k.startswith('ERR') or 'differs' in k or k.startswith('write_same_set') or k in('read_request_while_pending','read_and_write_same_tick') or k.startswith('MMIO') or k.startswith('A_ne') or 'VALID' in k): progs[k].append(n)
for k in sorted(tot): print('%-46s %d'%(k,tot[k]))
for k in sorted(mx): print('%-46s max=%d'%(k,mx[k]))
print('--- programs hitting rare keys')
for k,v in progs.items(): print(k, len(v), v[:6])
