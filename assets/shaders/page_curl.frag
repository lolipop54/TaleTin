#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uPageSize;
uniform vec2 uLeafSize;
uniform vec2 uMid;
uniform vec2 uNormal;
uniform float uRadius;
uniform float uPixel;
uniform vec3 uPaper;
uniform vec4 uTurningInkRect;
uniform vec4 uUnderInkRect;
uniform sampler2D uTurning;
uniform sampler2D uUnder;
uniform sampler2D uTurningInk;
uniform sampler2D uUnderInk;
out vec4 fragColor;

const float pi = 3.14159265;

// 小于零表示仍在纸内。按整个纸面的原始尺寸取色，包括打开书边时的裁切。
float edge(vec2 source) {
  vec2 outside = max(-source, source - uLeafSize);
  return max(outside.x, outside.y);
}
float coverage(float distance) {
  return clamp(0.5 - distance / uPixel, 0.0, 1.0);
}
bool containsInk(vec2 local, vec2 size) {
  return all(greaterThanEqual(local, vec2(0))) && all(lessThan(local, size));
}
vec3 compositeInk(vec3 base, vec4 ink) {
  return ink.rgb + base * (1.0 - ink.a);
}
vec3 page(vec2 source) {
  vec3 base = texture(uTurning, source / uPageSize).rgb;
  vec2 p = source - uTurningInkRect.xy;
  if (uTurningInkRect.z > 0.0 && containsInk(p, uTurningInkRect.zw)) {
    return compositeInk(base, texture(uTurningInk, p / uTurningInkRect.zw));
  }
  return base;
}
vec3 underPage(vec2 source) {
  vec3 base = texture(uUnder, source / uPageSize).rgb;
  vec2 p = source - uUnderInkRect.xy;
  if (uUnderInkRect.z > 0.0 && containsInk(p, uUnderInkRect.zw)) {
    return compositeInk(base, texture(uUnderInk, p / uUnderInkRect.zw));
  }
  return base;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  float d = dot(p - uMid, uNormal);
  float r = max(uRadius, 0.0001);
  vec2 reflected = p - 2.0 * d * uNormal;

  // 折线以左为未弯的正面。如果纸背和它的投影都够不到，只需读一次正面。
  float backEdge = max(d + r, edge(reflected));
  if (d < -r - uPixel && backEdge > 2.5 * r + uPixel) {
    fragColor = vec4(page(p), 1.0);
    return;
  }
  vec3 color = underPage(p);
  color *= 1.0 - (48.0 / 255.0) * clamp((0.65 * r - d) / (1.65 * r), 0.0, 1.0);
  if (d < -r + uPixel) {
    color = mix(color, page(p), coverage(d + r));
  }

  // 纸背投影随抬起高度向下偏移。直接根据纸边距离衰减，无须逐帧模糊整张纸。
  vec2 light = p - vec2(0.0, 0.5 * r);
  float dl = dot(light - uMid, uNormal);
  float shadowEdge = max(dl + r, edge(light - 2.0 * dl * uNormal));
  color *= 1.0 - 0.125 * (1.0 - smoothstep(-r, r, shadowEdge));
  float back = coverage(backEdge);
  if (back > 0.0) {
    color = mix(color, mix(page(reflected), uPaper, 0.90), back);
  }

  // 半圆柱的两面落在同一窄条内。倒算回书页的位置，正、背两面仍分别裁到原纸边界。
  float arc = (d + r) * pi / (2.0 * r);
  if (arc >= 0.0 && arc <= 1.0 && uRadius > 0.001) {
    float angle = asin(arc);
    float frontD = r * (2.0 * angle / pi - 1.0);
    vec2 frontSource = p + (frontD - d) * uNormal;
    vec2 backSource = p + (-frontD - d) * uNormal;
    color = mix(color, page(frontSource) * (1.0 - 0.24 * arc),
                coverage(edge(frontSource)));
    vec3 backColor = mix(mix(page(backSource), uPaper, 0.90), vec3(1.0), 0.18 * arc);
    color = mix(color, backColor, coverage(edge(backSource)));
  }
  fragColor = vec4(color, 1.0);
}
