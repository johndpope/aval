// GPU frame compositor for the decoded aval_decode RGBA picture.
//
// Line-by-line port of the web player's FRAME_FRAGMENT_SHADER_SOURCE
// (packages/player-web/src/runtime/frame-renderer-browser.ts), adapted per
// flutter/ARCHITECTURE.md §3.2:
//   - FlutterFragCoord() replaces gl_FragCoord.
//   - No precision qualifiers (not present in the Impeller GLSL-ES subset).
//   - One sampler2D (aval_decode has no packed-alpha profile yet, so
//     u_has_alpha is always 0 today); u_alpha_uv/u_has_alpha stay in the
//     uniform layout so a future packed-alpha decode core needs only to
//     flip that one value, not touch this shader.
//   - No V-flip: Skia/Impeller image textures already use a top-left UV
//     origin matching Canvas.drawImage, unlike WebGL's bottom-left origin.
#include <flutter/runtime_effect.glsl>

uniform vec4 u_color_uv;
uniform vec4 u_alpha_uv;
uniform vec4 u_output_rect;
uniform float u_has_alpha;

uniform sampler2D u_frame;

out vec4 fragColor;

void main() {
  vec2 output_index = FlutterFragCoord().xy - u_output_rect.xy - vec2(0.5);
  vec2 output_span = max(u_output_rect.zw - vec2(1.0), vec2(1.0));
  vec2 sample_uv = output_index / output_span;
  if (u_output_rect.z <= 1.0) sample_uv.x = 0.5;
  if (u_output_rect.w <= 1.0) sample_uv.y = 0.5;
  sample_uv = clamp(sample_uv, vec2(0.0), vec2(1.0));

  vec2 color_uv = u_color_uv.xy + sample_uv * u_color_uv.zw;
  vec3 color = texture(u_frame, color_uv).rgb;

  float alpha = 1.0;
  if (u_has_alpha > 0.5) {
    vec2 alpha_uv = u_alpha_uv.xy + sample_uv * u_alpha_uv.zw;
    alpha = clamp(texture(u_frame, alpha_uv).r, 0.0, 1.0);
  }

  fragColor = vec4(color * alpha, alpha);
}
