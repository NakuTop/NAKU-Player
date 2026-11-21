#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform vec2 uInset;
uniform float uTime;
uniform vec3 uTintA;
uniform vec3 uTintMid;
uniform vec3 uTintB;
out vec4 fragColor;

float softBand(float distance, float centre, float width) {
  float offset = (distance - centre) / width;
  return exp(-0.5 * offset * offset);
}

vec3 tintAt(float weight) {
  vec3 colour = mix(uTintA, uTintMid, smoothstep(0.02, 0.60, weight));
  return mix(colour, uTintB, smoothstep(0.44, 0.98, weight));
}

void main() {
  vec2 pixel = FlutterFragCoord().xy;
  vec2 p = pixel - 0.5 * uSize;
  vec2 halfChip = max(0.5 * uSize - uInset, vec2(1.0));
  vec2 spine = vec2(clamp(p.x, -max(halfChip.x - halfChip.y, 0.0),
                                max(halfChip.x - halfChip.y, 0.0)), 0.0);
  vec2 radius = p - spine;
  float lengthToSpine = max(length(radius), 0.001);
  float d = lengthToSpine - halfChip.y;
  // Project onto the capsule. Top, sides and bottom share one continuous flow.
  vec2 uv = (spine + radius * (halfChip.y / lengthToSpine)) / halfChip;
  float seed = dot(uTintMid, vec3(3.1, 5.7, 7.9));
  float t = uTime * 0.58;
  float tide = sin(1.68 * uv.x - 1.04 * uv.y + 0.48 * t + seed);
  float fold = sin(2.9 * uv.x + 1.33 * uv.y - 0.69 * t + 1.55 * tide);
  float drift = sin(-1.12 * uv.x + 2.35 * uv.y + 0.37 * t
                    + 0.87 * sin(2.13 * uv.x + 0.68 * t - seed));
  float twist = 0.5 + 0.5 * sin(2.74 * uv.x - 0.87 * uv.y + fold
                                 + 0.43 * t + 0.11 * d);
  float rim = 3.5 + 4.6 * fold + 1.3 * drift;
  float veil = 5.0 + 3.7 * drift - 2.3 * fold;
  // The same deformation pulls two folds across one another. Their width,
  // colour and brightness change together as the local surface turns.
  float facing = smoothstep(-0.76, 0.74, sin(1.95 * uv.x + uv.y + 0.42 * t + 1.38 * drift));
  float warp = (0.23 + 0.14 * tide) * (0.24 + 0.90 * facing)
             * softBand(d, rim, 2.8 + twist * 2.0);
  float weft = (0.20 - 0.09 * tide) * (0.35 + 0.78 * mix(facing, twist, 0.27))
             * softBand(d, veil, 4.6 + 1.7 * fold);
  float scatter = (0.030 + 0.054 * facing) * softBand(d, 3.0 + 1.5 * drift, 8.2);
  float weave = 0.5 + 0.5 * sin(1.53 * uv.x - 1.83 * uv.y + 0.32 * t + 1.29 * fold);
  vec3 light = warp * tintAt(0.72 * weave + 0.28 * twist)
             + weft * tintAt(0.30 * weave + 0.70 * (0.5 + 0.5 * drift))
             + scatter * uTintMid;
  // Leave a fully clear margin on all sides, including on a Retina surface.
  vec2 edge = min(pixel, uSize - pixel);
  float feather = smoothstep(1.4, 10.0, min(edge.x, edge.y));
  float mask = feather * smoothstep(-4.0, -0.2, d);
  fragColor = vec4(light * mask, (warp + weft + scatter) * mask);
}
