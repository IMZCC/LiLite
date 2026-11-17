#!/usr/bin/env python3
"""Compare both presets with the upstream shaders; no video, accounts or Apple GPU required."""
import ctypes as C
import importlib.util
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

base=Path(__file__).resolve().parents[1];root=base.parent; support=base/'Checks/Support/Anime4K'
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path); m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
generate=module('upscale_generation',base/'Tools/anime4k.py')
glref=module('upscale_reference',support/'gl_reference.py')
F=C.c_float;I=C.c_int
class Image(C.Structure):_fields_=[('w',I),('h',I),('pixels',C.POINTER(F))]

def native_shim(tmp,graph):
    text=(generate.DEST/'Anime4K.msl').read_text()
    text=text[:text.index('struct PresentOut')]
    text=re.sub(r'^#include <metal_stdlib>.*?constexpr sampler[^;]+;', '#include "MetalMath.hpp"',text,flags=re.S)
    text=re.sub(r'^kernel void .*?^\}', '',text,flags=re.M|re.S)
    text=text.replace('texture2d<float,access::sample>', 'Image')
    ids={}
    text+='\nextern "C" void pixel_pass(int fn,const Image* t,int w,int h,int channels,float* out){for(int y=0;y<h;y++)for(int x=0;x<w;x++){float2 uv((x+.5f)/w,(y+.5f)/h);float4 c; switch(fn){\n'
    for hooks in graph['programs'].values():
        for hook in hooks:
            kid=hook['kernel'];idx=ids[kid]=len(ids)
            text+=f'case {idx}: c=pixel_{kid}('+','.join(f't[{j}]' for j in range(len(hook['bind'])))+',uv); break;\n'
    text+='}for(int n=0;n<4;n++)out[(y*w+x)*4+n]=n<channels?(float)(_Float16)c[n]:0.0f;}}\n'
    path=tmp/'render.cpp';path.write_text(text);so=tmp/'render.so'
    compiler=shutil.which('clang++') or 'g++'
    subprocess.run([compiler,'-std=c++17','-O1','-fPIC','-shared','-I',str(support),str(path),'-o',str(so)],check=True)
    fn=C.CDLL(str(so)).pixel_pass;fn.restype=None;fn.argtypes=[I,C.POINTER(Image),I,I,I,C.POINTER(F)]
    return ids,fn
def rpn(exp,values):
    stack=[]
    for s in exp.split():
        if s in '+-/*<>':
            b,a=stack.pop(),stack.pop()
            stack.append({'/':lambda:a/b,'*':lambda:a*b,'>':lambda:a>b,'<':lambda:a<b}[s]())
        elif s.endswith(('.w','.h')):stack.append(values[s[:-2]][int(s[-1]=='h')])
        else:stack.append(float(s))
    assert len(stack)==1
    return stack[0]

def main():
    subprocess.run(['python3',str(base/'Tools/anime4k.py'),'--check'],check=True)
    os.environ.setdefault('LIBGL_ALWAYS_SOFTWARE','1')
    gl=glref.Reference()
    graph=json.loads((generate.DEST/'Graph.json').read_text())
    original={}
    for f,hooks in graph['programs'].items():
        _,*raw=generate.pass_text((generate.SRC/f).read_text())
        for (md,body),h in zip(raw,hooks,strict=True):
            original[h['kernel']]=(md,body)
    print('Reference:',gl.GetString(0x1f01).decode(),flush=True)
    with tempfile.TemporaryDirectory() as folder:
        tmp=Path(folder); ids,run=native_shim(tmp,graph)
        subprocess.run(['swiftc',str(base/'Sources/PiliNative/Playback/UpscaleGraph.swift'),str(base/'Checks/UpscaleGraphCheck.swift'),'-o',str(tmp/'plan')],check=True)
        plans=json.loads(subprocess.check_output([str(tmp/'plan'),str(generate.DEST/'Graph.json')]))
        for mode in ('efficiency','quality'):
            # Logical graph is independently assembled from upstream hook metadata below.
            stages=[k for f in generate.presets()[mode] for k in graph['programs'][f]]
            stages=sorted(stages,key=lambda h:original[h['kernel']][0]['HOOK']!=['MAIN'])
            for factor in (1.0,1.5,2.0,3.0,4.0):
                w,h=8,6;ow,oh=int(w*factor),int(h*factor)
                src=(F*(w*h*4))()
                for i in range(w*h):
                    x,y=i%w,i//w
                    for n,v in enumerate((float((x+2*y)%5)/4,float(y>1)+0.0,float((x^y)&1),1.0)):src[i*4+n]=v
                vals={'MAIN':(w,h,src,src),'NATIVE':(w,h,src,src),'OUTPUT':(ow,oh,None,None)}
                performed=[]; plan=plans[f"{mode}:{ow}:{oh}"];slots={0:(w,h,src)}
                for step in stages:
                    kid=step['kernel'];meta,body=original[kid]; vals['HOOKED']=vals['MAIN']
                    if 'WHEN' in meta and not rpn(meta['WHEN'][0],vals):continue
                    sw=int(math.floor(rpn(meta.get('WIDTH',['MAIN.w'])[0],vals)+.5));sh=int(math.floor(rpn(meta.get('HEIGHT',['MAIN.h'])[0],vals)+.5))
                    bind=meta['BIND'];inputs=[vals[n] for n in bind]
                    ref=gl.run(kid,bind,body,[(iw,ih,p0) for iw,ih,p0,p1 in inputs],sw,sh)
                    real=plan["passes"][len(performed)];dst=real["dst"]
                    assert real["kernel"]==kid and plan["shapes"][dst]==[sw,sh,step["channels"]] and dst not in real["inputs"]
                    images=(Image*len(bind))(*(Image(*slots[s]) for s in real["inputs"]))
                    gen=(F*(sw*sh*4))();run(ids[kid],images,sw,sh,step['channels'],gen)
                    slots[dst]=(sw,sh,gen)
                    vals[meta.get('SAVE',['MAIN'])[0]]=(sw,sh,ref,gen);performed.append(kid)
                fw,fh,ref,_=vals['MAIN'];mw,mh,gen=slots[plan['final']]
                assert (fw,fh)==(mw,mh) and len(performed)==len(plan['passes'])
                deltas=[abs(ref[i]-gen[i]) for i in range(len(ref)) if i%4!=3]
                worst=max(deltas); rms=math.sqrt(sum(v*v for v in deltas)/len(deltas))
                def baseline(x,y,c):
                    px=(x+.5)*w/fw-.5; py=(y+.5)*h/fh-.5; ix,iy=math.floor(px),math.floor(py)
                    def read(X,Y):return src[(max(0,min(h-1,Y))*w+max(0,min(w-1,X)))*4+c]
                    u,v=px-ix,py-iy
                    return (read(ix,iy)*(1-u)+read(ix+1,iy)*u)*(1-v)+(read(ix,iy+1)*(1-u)+read(ix+1,iy+1)*u)*v
                changed=sum(abs(gen[(y*fw+x)*4+c]-baseline(x,y,c)) for y in range(fh) for x in range(fw) for c in range(3))/(fw*fh*3)
                if changed<0.003:raise AssertionError(("unexpected bilinear output",mode,factor,changed))
                if not all(math.isfinite(v) for v in deltas) or rms>0.009 or worst>0.04:
                    raise AssertionError((mode,factor,worst,rms))
                print(f'{mode:10} output {factor:.1f}x passes {len(performed):2} final {fw}x{fh} RGB max {worst:.6f} rms {rms:.6f} vs bilinear MAE {changed:.6f}',flush=True)
if __name__=='__main__':main()
