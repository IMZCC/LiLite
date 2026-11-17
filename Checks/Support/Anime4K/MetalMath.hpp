#pragma once
// CPU execution harness for the generated Metal pixel functions (not an implementation used on iOS).
#include <algorithm>
#include <cmath>
#include <cstdint>
struct float2 {
  float x,y;
  float2(float a=0):x(a),y(a) {}
  float2(float a,float b):x(a),y(b){}
};
struct int2 {int x,y; explicit int2(float2 v):x((int)v.x),y((int)v.y){} };
struct float4 {
  float x,y,z,w;
  float4(float a=0):x(a),y(a),z(a),w(a){}
  float4(float a,float b,float c,float d):x(a),y(b),z(c),w(d){}
  float operator[](int n)const{return n==0?x:n==1?y:n==2?z:w;}
  float4& operator+=(float4 b){x+=b.x;y+=b.y;z+=b.z;w+=b.w;return *this;}
};
#define OP(op) \
 inline float2 operator op(float2 a,float2 b){return {a.x op b.x,a.y op b.y};} \
 inline float4 operator op(float4 a,float4 b){return {a.x op b.x,a.y op b.y,a.z op b.z,a.w op b.w};}
OP(+) OP(-) OP(*) OP(/)
#undef OP
inline float4 operator-(float4 a){return {-a.x,-a.y,-a.z,-a.w};}
using std::max; using std::min;
inline float4 max(float4 a,float b){return {max(a.x,b),max(a.y,b),max(a.z,b),max(a.w,b)};}
inline float2 fract(float2 a){return {a.x-std::floor(a.x),a.y-std::floor(a.y)};}
inline float dot(float4 a,float4 b){return a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w;}
struct float4x4 {float4 c[4];float4x4(float4 a,float4 b,float4 d,float4 e):c{a,b,d,e}{}};
inline float4 operator*(const float4x4& a,float4 x){return a.c[0]*x.x+a.c[1]*x.y+a.c[2]*x.z+a.c[3]*x.w;}
struct level {float lod;explicit level(float n):lod(n){} };
struct Image {
 int w,h;
 const float* pixels;
 int get_width()const{return w;} int get_height()const{return h;}
 float4 at(int x,int y)const{
   int i=(std::clamp(y,0,h-1)*w+std::clamp(x,0,w-1))*4;
   return float4(pixels[i],pixels[i+1],pixels[i+2],pixels[i+3]);
 }
 float4 sample(int,float2 uv,level mip)const{
   float px=uv.x*w-0.5f,py=uv.y*h-0.5f;
   int x=std::floor(px),y=std::floor(py);float u=px-x,v=py-y;
   return (at(x,y)*(1-u)+at(x+1,y)*u)*(1-v)+(at(x,y+1)*(1-u)+at(x+1,y+1)*u)*v;
 }
};
constexpr int linearEdge=0;
