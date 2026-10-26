#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform vec2 uImageSize;
uniform float uPixelSize;
uniform float uReveal;
uniform float uElapsed;
uniform float uAssembly;
uniform float uEnabled;
uniform sampler2D uSnapshot;

out vec4 fragColor;

float cellNoise(vec2 cell) {
  vec2 p = fract(cell * vec2(0.1031, 0.1030));
  p += dot(p, p.yx + 33.33);
  return fract((p.x + p.y) * p.x);
}

float roundedDistance(vec2 p, vec2 halfSize, float radius) {
  vec2 q = abs(p) - halfSize + radius;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

void main() {
  vec2 position = FlutterFragCoord().xy;
  vec2 uv = clamp(position / uSize, vec2(0.0), vec2(1.0));
  vec4 original = texture(uSnapshot, uv);
  if (uEnabled < 0.5) {
    fragColor = original;
    return;
  }

  float assembly = smoothstep(0.0, 1.0, uAssembly);
  // Interpolate the reveal field so a ready patch joins its still-soft
  // neighbours gradually, without a hard rectangular 96 px border.
  vec2 field = position / vec2(96.0, 72.0);
  vec2 region = floor(field);
  vec2 blend = smoothstep(vec2(0.0), vec2(1.0), fract(field));
  float noise = mix(
    mix(cellNoise(region), cellNoise(region + vec2(1.0, 0.0)), blend.x),
    mix(cellNoise(region + vec2(0.0, 1.0)), cellNoise(region + vec2(1.0)), blend.x),
    blend.y);
  float refinement = smoothstep(noise * 0.72 + 0.08,
                                noise * 0.72 + 0.28, uReveal);
  float clarity = mix(refinement * 0.92, 1.0, assembly);
  float pitch = max(1.0, mix(uPixelSize * 1.8, 1.0, clarity));
  vec2 cell = floor(position / pitch);
  vec2 center = (cell + 0.5) * pitch;
  vec2 halfTexel = 0.5 / max(uImageSize, vec2(1.0));
  vec2 sampledUv = clamp(center / uSize, halfTexel, vec2(1.0) - halfTexel);
  vec4 sampled = texture(uSnapshot, sampledUv);

  // A signed-distance corner softens sampled colour fields in one pass. There
  // is no stroked grid, generated tile palette, clip path, or offscreen blur.
  float radius = pitch * 0.23 * (1.0 - assembly);
  float edge = roundedDistance(position - center, vec2(pitch * 0.5), radius);
  float rounded = 1.0 - smoothstep(-0.9, 0.6, edge);
  vec4 color = mix(sampled, original, clarity);
  color.rgb *= mix(0.965, 1.0, rounded);
  float shimmer = (0.5 + 0.5 * sin(uElapsed * 0.85 + noise * 6.2831853));
  color.rgb *= 1.0 + 0.012 * shimmer * (1.0 - clarity);
  color.rgb *= 1.0 + 0.045 * sin(uAssembly * 3.14159265);
  fragColor = color;
}
