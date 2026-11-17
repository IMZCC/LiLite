"""Render unchanged mpv GLSL hook bodies in a real offscreen OpenGL context (Mesa is sufficient)."""
import ctypes as C
import os
os.environ.setdefault('EGL_PLATFORM','surfaceless')
P=C.c_void_p; I=C.c_int; U=C.c_uint; F=C.c_float; S=C.c_char_p
def fn(lib,name,restype,*args):
    f=getattr(lib,name);f.argtypes=args;f.restype=restype;return f
class Reference:
    def __init__(self):
        E=C.CDLL('libEGL.so.1'); G=C.CDLL('libGL.so.1')
        self.E=E;self.G=G
        d=fn(E,'eglGetDisplay',P,P)(None)
        assert fn(E,'eglInitialize',I,P,P,P)(d,None,None)
        assert fn(E,'eglBindAPI',I,U)(0x30A2)
        def attrs(*x):return (I*(len(x)+1))(*x,0x3038)
        cfg=P();n=I()
        assert fn(E,'eglChooseConfig',I,P,P,C.POINTER(P),I,C.POINTER(I))(d,attrs(0x3033,1,0x3040,8),C.byref(cfg),1,C.byref(n)) and n.value
        ctx=fn(E,'eglCreateContext',P,P,P,P,P)(d,cfg,None,attrs(0x3098,3,0x30fb,3))
        surf=fn(E,'eglCreatePbufferSurface',P,P,P,P)(d,cfg,attrs(0x3057,1,0x3056,1))
        assert ctx and surf and fn(E,'eglMakeCurrent',I,P,P,P,P)(d,surf,surf,ctx)
        sig={
          'GetString':(S,U),'GetError':(U,), 'CreateShader':(U,U),'ShaderSource':(None,U,I,C.POINTER(S),P),
          'CompileShader':(None,U),'GetShaderiv':(None,U,U,C.POINTER(I)),'GetShaderInfoLog':(None,U,I,P,P),
          'CreateProgram':(U,),'AttachShader':(None,U,U),'LinkProgram':(None,U),'GetProgramiv':(None,U,U,C.POINTER(I)),
          'GetProgramInfoLog':(None,U,I,P,P),'UseProgram':(None,U),'DeleteShader':(None,U),
          'GenTextures':(None,I,C.POINTER(U)),'BindTexture':(None,U,U),'TexParameteri':(None,U,U,I),
          'TexImage2D':(None,U,I,I,I,I,I,U,U,P),'DeleteTextures':(None,I,C.POINTER(U)),'ActiveTexture':(None,U),
          'GenFramebuffers':(None,I,C.POINTER(U)),'BindFramebuffer':(None,U,U),'FramebufferTexture2D':(None,U,U,U,U,I),
          'CheckFramebufferStatus':(U,U),'GetUniformLocation':(I,U,S),'Uniform1i':(None,I,I),'Uniform2f':(None,I,F,F),
          'GenVertexArrays':(None,I,C.POINTER(U)),'BindVertexArray':(None,U),'Viewport':(None,I,I,I,I),
          'DrawArrays':(None,U,I,I),'ReadPixels':(None,I,I,I,I,U,U,P)}
        for k,(ret,*args) in sig.items():setattr(self,k,fn(G,'gl'+k,ret,*args))
        self.fb=U();self.vao=U()
        self.GenFramebuffers(1,C.byref(self.fb));self.BindFramebuffer(0x8d40,self.fb)
        self.GenVertexArrays(1,C.byref(self.vao));self.BindVertexArray(self.vao)
        self.vertex=self.shader(0x8b31,'#version 330 core\nvoid main(){vec2 st=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(st*2.0-1.0,0.0,1.0);}')
        self.programs={}
    def shader(self,kind,text):
        obj=self.CreateShader(kind);src=S(text.encode())
        self.ShaderSource(obj,1,C.byref(src),None);self.CompileShader(obj)
        ok=I();self.GetShaderiv(obj,0x8b81,C.byref(ok))
        if not ok.value:
            msg=C.create_string_buffer(12000);self.GetShaderInfoLog(obj,len(msg),None,msg)
            raise RuntimeError(msg.value.decode())
        return obj
    def program(self,name,bind,body):
        if name in self.programs:return self.programs[name]
        aliases={n:i for i,n in enumerate(bind)}
        if 'HOOKED' in aliases:aliases.setdefault('MAIN',aliases['HOOKED'])
        src='#version 330 core\nuniform vec2 output_size;out vec4 color;\n'
        for i in range(len(bind)):src+=f'uniform sampler2D t{i};\n'
        for n,i in aliases.items():
            src += f'#define {n}_pos (gl_FragCoord.xy/output_size)\n#define {n}_size vec2(textureSize(t{i},0))\n#define {n}_pt (1.0/{n}_size)\n#define {n}_tex(uv) texture(t{i},uv)\n#define {n}_texOff(p) texture(t{i},{n}_pos+vec2(p)*{n}_pt)\n'
        frag=self.shader(0x8b30,src+body+'\nvoid main(){color=hook();}\n')
        pr=self.CreateProgram();self.AttachShader(pr,self.vertex);self.AttachShader(pr,frag);self.LinkProgram(pr)
        ok=I();self.GetProgramiv(pr,0x8b82,C.byref(ok));self.DeleteShader(frag)
        if not ok.value:
            msg=C.create_string_buffer(4096);self.GetProgramInfoLog(pr,len(msg),None,msg);raise RuntimeError(msg.value.decode())
        self.programs[name]=pr;return pr
    def texture(self,w,h,pix=None):
        tid=U();self.GenTextures(1,C.byref(tid));self.BindTexture(0xde1,tid)
        for key,val in ((0x2801,0x2601),(0x2800,0x2601),(0x2802,0x812f),(0x2803,0x812f)):
            self.TexParameteri(0xde1,key,val)
        self.TexImage2D(0xde1,0,0x881a,w,h,0,0x1908,0x1406,pix)
        return tid
    def run(self,key,bind,body,inputs,w,h):
        pr=self.program(key,bind,body);self.UseProgram(pr)
        self.ActiveTexture(0x84c0);out=self.texture(w,h)
        self.FramebufferTexture2D(0x8d40,0x8ce0,0xde1,out,0)
        assert self.CheckFramebufferStatus(0x8d40)==0x8cd5
        inp=[]
        for i,(iw,ih,px) in enumerate(inputs):
            self.ActiveTexture(0x84c0+i);inp.append(self.texture(iw,ih,px))
            self.Uniform1i(self.GetUniformLocation(pr,f't{i}'.encode()),i)
        self.Uniform2f(self.GetUniformLocation(pr,b'output_size'),w,h)
        self.Viewport(0,0,w,h);self.DrawArrays(4,0,3)
        pixels=(F*(w*h*4))();self.ReadPixels(0,0,w,h,0x1908,0x1406,pixels);assert self.GetError()==0
        for t in inp+[out]:self.DeleteTextures(1,C.byref(t))
        return pixels
