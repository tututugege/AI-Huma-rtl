"""Random + exhaustive-funct5 check of idu_ctrl_decode (FP=1 config) against the decode of back-end/Idu.cpp (F/D)."""
import random, subprocess, re
random.seed(1)
def ref(i):
    op=i&0x7f; f3=(i>>12)&7; f7=i>>25; rd=(i>>7)&31; rs1=(i>>15)&31; rs2=(i>>20)&31; r3=(i>>27)&31
    d=dict(type=0,dest=0,s1=0,s2=0,s2imm=1,ill=0,dfp=0,s1fp=0,s2fp=0,s3=0,s3a=0,cls=0,da=rd,s1a=rs1,s2a=rs2)
    def ill(): d.update(type=0,dest=0,s1=0,s2=0,s2imm=1,ill=1)
    def op_(t,de,a,b): d.update(type=t,dest=de,s1=a,s2=b)
    if op==0x07:
        if f3 not in(2,3): ill()
        else: op_(5,1,1,0); d['dfp']=1
    elif op==0x27:
        if f3 not in(2,3): ill()
        else: op_(6,0,1,1); d['s2fp']=1
    elif op in(0x43,0x47,0x4b,0x4f):
        if (f7&3)>1: ill()
        else: op_(19,1,1,1); d.update(s2imm=0,dfp=1,s1fp=1,s2fp=1,s3=1,s3a=r3,cls=1)
    elif op==0x53:
        f5=f7>>2
        if (f7&3)>1: ill(); 
        else:
            d['s2imm']=0
            if f5 in(0,1,2): op_(19,1,1,1); d.update(dfp=1,s1fp=1,s2fp=1,cls=1)
            elif f5==3: op_(19,1,1,1); d.update(dfp=1,s1fp=1,s2fp=1,cls=2)
            elif f5==0x0b: op_(19,1,1,0); d.update(dfp=1,s1fp=1,cls=2)
            elif f5 in(4,5): op_(19,1,1,1); d.update(dfp=1,s1fp=1,s2fp=1,cls=3)
            elif f5==8: op_(19,1,1,0); d.update(dfp=1,s1fp=1,cls=3)
            elif f5==0x14: op_(19,1,1,1); d.update(s1fp=1,s2fp=1,cls=3)
            elif f5 in(0x18,0x1c): op_(19,1,1,0); d.update(s1fp=1,cls=3)
            elif f5 in(0x1a,0x1e): op_(19,1,1,0); d.update(dfp=1,cls=4)
            else: ill(); d['s2imm']=1
        if d['ill']: d['s2imm']=1
    else: return None
    if d['dest'] and not d['dfp'] and rd == 0: d['dest'] = 0   # x0 is not written (f0 is a register)
    return d
ins=[]
for op in (0x07,0x27,0x43,0x47,0x4b,0x4f,0x53):
    for _ in range(4000): ins.append((random.getrandbits(32)&~0x7f)|op)
for f5 in range(32):
    for fmt in range(4):
        for rd in (0,5):
            ins.append((f5<<27)|(fmt<<25)|(rd<<7)|0x53|(1<<20)|(2<<15))
inp="\n".join("%08x"%i for i in ins)
out=subprocess.run([__import__("sys").argv[1]],input=inp,capture_output=True,text=True).stdout.strip().split("\n")
bad=0
for i,l in zip(ins,out):
    m=dict(re.findall(r'(\w+)=(\d+)',l)); m={k:int(v) for k,v in m.items()}
    r=ref(i)
    got=dict(type=m['type'],dest=m['dest'],s1=m['s1'],s2=m['s2'],s2imm=m['s2imm'],ill=m['ill'],dfp=m['dfp'],s1fp=m['s1fp'],s2fp=m['s2fp'],s3=m['s3'],s3a=m['s3a'],cls=m['cls'],da=m['da'],s1a=m['s1a'],s2a=m['s2a'])
    if got!=r:
        bad+=1
        if bad<6: print("MISMATCH %08x\n got %s\n ref %s"%(i,got,r))
print(len(ins),"checked, mismatches:",bad)
