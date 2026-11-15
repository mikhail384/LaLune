#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
out vec4 fragColor;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void main() {
    vec2 size = max(uSize, vec2(1.0));
    vec2 uv = FlutterFragCoord().xy / size;
    float edge = smoothstep(0.0, 0.55, 1.0 - distance(uv, vec2(0.5)));
    float grain = hash21(floor(FlutterFragCoord().xy * 0.5)) - 0.5;
    float sheen = (1.0 - smoothstep(0.15, 1.05, uv.x + uv.y)) * 0.035;
    float alpha = 0.022 + edge * 0.018 + grain * 0.012;
    vec3 tint = vec3(0.72, 0.78, 1.0) * (0.70 + sheen);
    fragColor = vec4(tint, clamp(alpha, 0.008, 0.055));
}
