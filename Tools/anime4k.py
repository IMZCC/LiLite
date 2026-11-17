#!/usr/bin/env python3
"""Compile the fixed upstream mpv hook descriptions to one Metal library and pass manifest."""
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'assets/shaders'
DEST = ROOT / 'Native/Sources/PiliNative/UpscaleAssets'

def presets():
    text=(ROOT/'lib/common/assets.dart').read_text('utf8')
    result={}
    for mode,key in [('quality','mpvAnime4KShaders'),('efficiency','mpvAnime4KShadersLite')]:
        block=re.search(r'\b'+key+r'\s*=\s*\[(.*?)\]',text,re.S)[1]
        result[mode]=re.findall(r"'([^']+\.glsl)'",block)
    assert [len(result[x]) for x in ('quality','efficiency')]==[6,7]
    return result

def pass_text(text):
    header,*passes=re.split(r'(?=^//!DESC )',text,flags=re.M)
    yield header
    for src in passes:
        meta={}
        for k,v in re.findall(r'^//!([A-Z]+)[ \t]+([^\n]+)',src,re.M):
            meta.setdefault(k,[]).append(v.strip())
        yield meta,re.sub(r'^//![^\n]*\n','',src,flags=re.M)

def matrix(m):
    a=[x.strip() for x in m[1].split(',')]
    assert len(a)==16
    return 'float4x4('+', '.join('float4('+','.join(a[i:i+4])+')' for i in range(0,16,4))+')'

def translate(body,bind,kid):
    # Each GLSL matrix constructor lists its four columns. Keep the operation ordering and biases.
    s=re.sub(r'mat4\(([^()]+)\)',matrix,body)
    for a,b in [('ivec2','int2'),('vec2','float2'),('vec4','float4'),('get_luma','luma_'+kid)]:
        s=re.sub(r'\b'+a+r'\b',b,s)
    s=re.sub(r'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])',r'\1f',s)
    aliases={b:i for i,b in enumerate(bind)}
    if 'HOOKED' in aliases: aliases.setdefault('MAIN',aliases['HOOKED'])
    macros={}
    for name,i in aliases.items():
        macros.update({name+'_size':f'float2(t{i}.get_width(), t{i}.get_height())',name+'_pt':f'(1.0f/{name}_size)',name+'_pos':'uv',
           name+'_tex(p)':f't{i}.sample(linearEdge,(p),level(0.0f))',name+'_texOff(p)':f't{i}.sample(linearEdge,uv+float2(p)*{name}_pt,level(0.0f))'})
    ts=[f'texture2d<float,access::sample> t{i}' for i in range(len(bind))]
    args=', '.join(ts+['float2 uv'])
    s=s.replace('float4 hook()',f'inline float4 pixel_{kid}({args})')
    assert 'pixel_'+kid in s
    decl=', '.join(t+f' [[texture({i})]]' for i,t in enumerate(ts))
    entry=(f'kernel void {kid}({decl}, texture2d<float,access::write> dst [[texture({len(ts)})]], uint2 gid [[thread_position_in_grid]]) {{\n'
           ' if (gid.x>=dst.get_width() || gid.y>=dst.get_height()) return;\n'
           ' float2 uv=(float2(gid)+0.5f)/float2(dst.get_width(),dst.get_height());\n'
           f' dst.write(pixel_{kid}('+', '.join(f't{i}' for i in range(len(ts)))+', uv), gid);\n}')
    undefs=re.findall(r'^#define\s+(\w+)',s,re.M)+[k.split('(')[0] for k in macros]
    return '\n'.join('#define '+k+' '+v for k,v in macros.items())+'\n'+s+'\n'+entry+'\n'+'\n'.join('#undef '+k for k in undefs)+'\n'

def data():
    names=presets(); programs={}; license_text={}; hashes={}
    msl='#include <metal_stdlib>\nusing namespace metal;\nconstexpr sampler linearEdge(coord::normalized,address::clamp_to_edge,filter::linear);\n'
    for file in sorted(set(names['quality']+names['efficiency'])):
        raw=(SRC/file).read_text('utf8')
        hashes[file]=hashlib.sha256(raw.encode('utf8')).hexdigest()
        header,*passes=pass_text(raw)
        assert passes
        license_text[file]=header.strip()
        msl+='\n// Source: '+file+'\n'+header+'\n'
        programs[file]=[]
        for i,(m,body) in enumerate(passes):
            kid='ak_'+Path(file).stem.removeprefix('Anime4K_')+'_'+str(i)
            p={'kernel':kid,'hook':m['HOOK'][0],'bind':m['BIND'],'save':m.get('SAVE',['MAIN'])[0],
               'width':m.get('WIDTH',['MAIN.w'])[0],'height':m.get('HEIGHT',['MAIN.h'])[0],
               'when':m.get('WHEN',[''])[0],'channels':int(m.get('COMPONENTS',['4'])[0])}
            programs[file].append(p)
            msl+=translate(body,p['bind'],kid)
    msl+='''
struct PresentOut { float4 pos [[position]]; float2 uv; };
vertex PresentOut animeVertex(uint id [[vertex_id]], constant float2& extent [[buffer(0)]], constant float2* uv [[buffer(1)]]) {
  float2 st=float2(float(id & 1),float((id >> 1) & 1));
  PresentOut v; v.pos=float4((st*float2(2,-2)+float2(-1,1))*extent,0,1); v.uv=uv[0]+st.x*uv[1]+st.y*uv[2]; return v;
}
fragment float4 animePresent(PresentOut in [[stage_in]],texture2d<float> src [[texture(0)]]) {
  return float4(src.sample(linearEdge,in.uv).rgb,1.0f);
}
'''
    msl='\n'.join(line.rstrip() for line in msl.splitlines())+'\n'
    licenseOut='\n\n'.join(k+'\n'+license_text[k] for k in ('Anime4K_AutoDownscalePre_x2.glsl','Anime4K_Clamp_Highlights.glsl'))+'\n'
    return {DEST/'Anime4K.msl':msl, DEST/'Graph.json':json.dumps({'presets':names,'programs':programs,'hashes':hashes},indent=2)+'\n',
       ROOT/'Native/Sources/PiliNative/Notices/Anime4K.txt':licenseOut}

if __name__=='__main__':
    for path,text in data().items():
        if '--check' in sys.argv:
            if path.read_text('utf8')!=text: raise SystemExit('stale: '+str(path))
        else:
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text(text,encoding='utf8',newline='\n')
