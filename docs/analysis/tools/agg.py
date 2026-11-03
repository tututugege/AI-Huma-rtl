import glob,collections,os,sys
d=sys.argv[1]
keys=collections.defaultdict(dict)
progs=[]
for f in sorted(glob.glob(d+'/*.txt')):
    if os.path.basename(f).startswith('_'): continue
    n=os.path.basename(f)[:-4]
    progs.append(n)
    for l in open(f):
        p=l.split()
        if p[0]!='COV': continue
        v=int(p[-1]); k=' '.join(p[1:-1])
        keys[k][n]=v
allk=sorted(keys)
print(f"programs: {len(progs)}")
print("%-62s %5s %12s %10s  %s"%("key","#prog","total","max","max-prog"))
for k in allk:
    vals=keys[k]
    nz=[p for p,v in vals.items() if v>0]
    mx=max(vals.items(), key=lambda x:x[1]) if vals else ('',0)
    print("%-62s %5d %12d %10d  %s"%(k,len(nz),sum(vals.values()),mx[1],mx[0]))
