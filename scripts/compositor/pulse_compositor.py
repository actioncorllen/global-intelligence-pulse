#!/usr/bin/env python3
"""
Strateloq Native Video Compositor (STRATELOQ-015S/T, productionized 015U)
========================================================================
A small, Strateloq-OWNED automated ad-production compositor. It turns a
storyboard (scene plan) + authoritative assets (Product Card pixels for
CUSTOMER_PRODUCT, real screenshots/logo for STRATELOQ_BRAND) + existing
generated clips + deterministic copy/captions/CTA + optional audio into ONE
finished multi-scene vertical short-form advertisement.

GENERIC / PRODUCTION NOTES (015U):
- Nothing here is specific to any product, tenant, copy, theme or storyboard.
  The DESIGN/THEME (palette, stars, halo) is data-driven via storyboard["design"];
  the default theme is neutral and brand-agnostic. Product/copy/scene data all
  come from the storyboard. The night-sky look is just one theme (see the 015S/T
  storyboards) — it is NOT baked into this engine.
- Core renderer = FFmpeg (open source, server-side) via imageio-ffmpeg. No
  external editing/composition SaaS.
- Product identity: IMAGE scenes composite exact authoritative pixels (scale/
  crop/position/mask/shadow/pan/zoom) — never redraw. VIDEO scenes reuse a clip.
- Scene types: IMAGE_SCENE, VIDEO_SCENE, TEXT_SCENE, CTA_SCENE.

Usage: python3 pulse_compositor.py <storyboard.json> <output.mp4> [workdir]
"""
import json, os, subprocess, sys, math, random
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import imageio_ffmpeg

FF = imageio_ffmpeg.get_ffmpeg_exe()
W, H, FPS = 1080, 1920, 30
FONT_BOLD = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"
FONT_REG = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"
if not os.path.exists(FONT_REG):
    FONT_REG = FONT_BOLD
SAFE_X = 72  # side safe margin

# ---- neutral, brand-agnostic DEFAULT theme (data can override every value) ----
DEFAULT_THEME = {
    "palette": [[20, 20, 26], [30, 30, 40], [14, 14, 18]],  # top, mid, bottom
    "accent": [255, 201, 102],      # CTA pill / kicker
    "accent_text": [26, 26, 30],    # text on the accent pill
    "text": [245, 245, 248],
    "sub": [200, 200, 212],
    "stars": None,                   # e.g. {"n": 260, "seed": 8080} to enable
    "halo_rgb": [255, 238, 208],
    "halo_default": 40,
}


def build_theme(storyboard):
    t = dict(DEFAULT_THEME)
    t.update(storyboard.get("design", {}) or {})
    return t


def _lerp(a, b, s):
    return tuple(int(a[i] + (b[i] - a[i]) * s) for i in range(3))


def make_gradient(theme, w=W, h=H):
    top, mid, bot = [tuple(c) for c in theme["palette"]]
    g = Image.new("RGB", (w, h)); px = g.load()
    for y in range(h):
        s = y / (h - 1)
        c = _lerp(top, mid, s / 0.5) if s < 0.5 else _lerp(mid, bot, (s - 0.5) / 0.5)
        for x in range(w):
            px[x, y] = c
    return g


def make_starfield(theme, w=W, h=H + 260):
    cfg = theme.get("stars")
    if not cfg:
        return None
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0)); d = ImageDraw.Draw(layer)
    r = random.Random(cfg.get("seed", 8080))
    for _ in range(cfg.get("n", 260)):
        x = r.randint(0, w - 1); y = r.randint(0, h - 1); b = r.randint(120, 255)
        s = r.choice([1, 1, 1, 2, 2, 3]); col = (b, b, min(255, b + 8), r.randint(120, 255))
        if s == 1:
            d.point((x, y), fill=col)
        else:
            d.ellipse([x - s / 2, y - s / 2, x + s / 2, y + s / 2], fill=col)
    return layer


def make_halo(cx, cy, maxr, strength, theme, w=W, h=H):
    halo = Image.new("L", (w, h), 0); hd = ImageDraw.Draw(halo)
    for rr in range(maxr, 0, -3):
        a = int(strength * (1 - rr / maxr) ** 2)
        hd.ellipse([cx - rr, cy - int(rr * 0.9), cx + rr, cy + int(rr * 0.9)], fill=a)
    return halo.filter(ImageFilter.GaussianBlur(38))


def wrap(draw, text, font, maxw):
    words, lines, cur = text.split(), [], ""
    for wd in words:
        t = (cur + " " + wd).strip()
        if draw.textlength(t, font=font) <= maxw:
            cur = t
        else:
            if cur:
                lines.append(cur)
            cur = wd
    if cur:
        lines.append(cur)
    return lines


def text_layer(scene, theme):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(layer)
    TEXT = tuple(theme["text"]); SUB = tuple(theme["sub"]); ACC = tuple(theme["accent"])

    def draw_center(lines, font, y, fill, lh):
        for ln in lines:
            tw = d.textlength(ln, font=font); x = (W - tw) / 2
            d.text((x + 3, y + 3), ln, font=font, fill=(0, 0, 0, 150))
            d.text((x, y), ln, font=font, fill=fill + (255,)); y += lh
        return y

    if scene.get("kicker"):
        f = ImageFont.truetype(FONT_BOLD, 34); k = scene["kicker"]
        tw = d.textlength(k, font=f); d.text(((W - tw) / 2, scene.get("kicker_y", 150)), k, font=f, fill=ACC + (255,))
    if scene.get("headline"):
        sz = scene.get("headline_size", 76); f = ImageFont.truetype(FONT_BOLD, sz)
        draw_center(wrap(d, scene["headline"], f, W - 2 * SAFE_X), f, scene.get("headline_y", 210), TEXT, int(sz * 1.16))
    if scene.get("supporting"):
        sz = scene.get("supporting_size", 40); f = ImageFont.truetype(FONT_REG, sz)
        draw_center(wrap(d, scene["supporting"], f, W - 2 * SAFE_X), f, scene.get("supporting_y", 360), SUB, int(sz * 1.2))
    if scene.get("caption"):
        f = ImageFont.truetype(FONT_BOLD, 44)
        draw_center(wrap(d, scene["caption"], f, W - 2 * SAFE_X), f, scene.get("caption_y", H - 430), TEXT, 54)
    return layer


def cta_layer(scene, theme, pulse=1.0):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(layer)
    ACC = tuple(theme["accent"]); ACT = tuple(theme["accent_text"])
    cta = scene["cta"]; f = ImageFont.truetype(FONT_BOLD, 48)
    cw = d.textlength(cta, font=f); pill_w = int((cw + 120) * pulse); pill_h = int(120 * pulse)
    px = (W - pill_w) // 2; py = scene.get("cta_y", H - 380)
    d.rounded_rectangle([px, py, px + pill_w, py + pill_h], radius=pill_h // 2, fill=ACC + (255,))
    d.text((px + (pill_w - cw) / 2, py + (pill_h - 60) / 2), cta, font=f, fill=ACT + (255,))
    return layer


def _raw_writer(path):
    cmd = [FF, "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
           "-s", f"{W}x{H}", "-r", str(FPS), "-i", "pipe:0", "-an", "-c:v", "libx264",
           "-pix_fmt", "yuv420p", "-preset", "medium", "-crf", "19", "-movflags", "+faststart", path]
    return subprocess.Popen(cmd, stdin=subprocess.PIPE)


def render_pil_scene(scene, out_path, assets, theme):
    """Frame-generate an IMAGE/TEXT/CTA scene with deterministic motion.
    Background is the themed gradient(+stars) OR a real background_asset image
    (for STRATELOQ_BRAND screenshots)."""
    dur = scene["duration"]; N = max(1, int(round(dur * FPS)))
    grad = assets["gradient"]; stars = assets.get("starfield"); star_h = stars.size[1] if stars else H
    bg_asset = None
    if scene.get("background_asset"):
        bg_asset = Image.open(scene["background_asset"]).convert("RGB")
        bw = int(W * 1.12); bh = int(bw * bg_asset.size[1] / bg_asset.size[0])
        if bh < int(H * 1.12):
            bh = int(H * 1.12); bw = int(bh * bg_asset.size[0] / bg_asset.size[1])
        bg_asset = bg_asset.resize((bw, bh), Image.LANCZOS)
    txt = text_layer(scene, theme).convert("RGBA"); has_cta = "cta" in scene
    prod = Image.open(scene["product_asset"]).convert("RGBA") if scene.get("product_asset") else None
    cy = scene.get("product_cy", 980)
    halo_img = Image.new("RGB", (W, H), tuple(theme["halo_rgb"]))
    halo_mask = make_halo(W // 2, cy, scene.get("halo_r", 520), scene.get("halo", theme["halo_default"]), theme)

    p = _raw_writer(out_path); fadein = min(0.5, dur * 0.4)
    for i in range(N):
        t = i / max(1, N - 1); tt = i / FPS
        if bg_asset is not None:
            # Ken-Burns push-in on the real background image
            z = 1.0 + 0.06 * t; cw = int(W / z); ch = int(H / z)
            x0 = (bg_asset.size[0] - cw) // 2; y0 = (bg_asset.size[1] - ch) // 2
            frame = bg_asset.crop((x0, y0, x0 + cw, y0 + ch)).resize((W, H), Image.LANCZOS)
        else:
            frame = grad.copy()
            if stars is not None:
                shift = int((star_h - H) * (0.15 + 0.7 * t)); frame.paste(stars, (0, -shift), stars)
            hm = halo_mask.point(lambda v, k=(0.6 + 0.4 * t): int(v * k))
            frame = Image.composite(halo_img, frame, hm)
        if prod is not None:
            s0, s1 = scene.get("scale0", 0.98), scene.get("scale1", 1.06)
            base_w = scene.get("product_w", 640); sw = int(base_w * (s0 + (s1 - s0) * t))
            sh = int(prod.size[1] * sw / prod.size[0]); pim = prod.resize((sw, sh), Image.LANCZOS)
            drift = int(scene.get("product_drift", -26) * t); px_ = (W - sw) // 2; py_ = cy - sh // 2 + drift
            al = pim.split()[3]; sh_l = Image.new("L", (W, H), 0); sh_l.paste(al, (px_, py_ + 16))
            sh_l = sh_l.filter(ImageFilter.GaussianBlur(20)).point(lambda v: int(v * 0.45))
            shadow = Image.merge("RGBA", (Image.new("L", (W, H), 0),) * 3 + (sh_l,))
            frame = Image.alpha_composite(frame.convert("RGBA"), shadow).convert("RGB")
            frame.paste(pim, (px_, py_), pim)
        a = min(1.0, tt / fadein) if fadein > 0 else 1.0
        over = cta_layer(scene, theme, 1.0 + 0.03 * math.sin(tt * 3.2)).convert("RGBA") if has_cta else txt
        if a < 1.0:
            oa = over.split()[3].point(lambda v, k=a: int(v * k)); over = Image.merge("RGBA", over.split()[:3] + (oa,))
        frame = Image.alpha_composite(frame.convert("RGBA"), over).convert("RGB")
        p.stdin.write(frame.tobytes())
    p.stdin.close(); p.wait()


def render_video_scene(scene, out_path, theme):
    """Normalize an existing clip to 1080x1920/30fps (with optional in-point ss,
    subtle push, and text overlay)."""
    dur = scene["duration"]; ss = scene.get("ss", 0); src = scene["video_asset"]
    over_png = None
    if any(scene.get(k) for k in ("headline", "kicker", "supporting", "caption")):
        over_png = out_path + ".over.png"; text_layer(scene, theme).save(over_png)
    z = scene.get("video_zoom", 0.04)
    vf = (f"scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},fps={FPS},"
          f"scale=ceil(iw*(1+{z}))/2*2:-2,crop={W}:{H}")
    seek = ["-ss", str(ss), "-t", str(dur), "-i", src]
    if over_png:
        cmd = [FF, "-y", "-loglevel", "error", *seek, "-i", over_png,
               "-filter_complex", f"[0:v]{vf}[v];[v][1:v]overlay=0:0:format=auto",
               "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "medium",
               "-crf", "19", "-r", str(FPS), "-movflags", "+faststart", out_path]
    else:
        cmd = [FF, "-y", "-loglevel", "error", *seek, "-vf", vf, "-an", "-c:v", "libx264",
               "-pix_fmt", "yuv420p", "-preset", "medium", "-crf", "19", "-r", str(FPS),
               "-movflags", "+faststart", out_path]
    subprocess.run(cmd, check=True)


def render_ambient(total_s, out_wav):
    """Strateloq-generated, license-clean $0 ambient bed. Demonstrates the audio-mix
    pipeline; no external API, no rights issue."""
    d = total_s
    fc = ("[0:a][1:a][2:a]amix=inputs=3:normalize=0[m];"
          f"[m]volume=0.10,tremolo=f=0.12:d=0.4,afade=t=in:st=0:d=1.3,"
          f"afade=t=out:st={max(0.1, d - 1.4):.2f}:d=1.4[a]")
    cmd = [FF, "-y", "-loglevel", "error",
           "-f", "lavfi", "-t", str(d), "-i", "sine=frequency=110",
           "-f", "lavfi", "-t", str(d), "-i", "sine=frequency=164.81",
           "-f", "lavfi", "-t", str(d), "-i", "sine=frequency=220",
           "-filter_complex", fc, "-map", "[a]", "-c:a", "pcm_s16le", out_wav]
    subprocess.run(cmd, check=True)


def mux_audio(video_in, wav_in, out_path):
    subprocess.run([FF, "-y", "-loglevel", "error", "-i", video_in, "-i", wav_in,
                    "-c:v", "copy", "-c:a", "aac", "-b:a", "128k", "-shortest",
                    "-movflags", "+faststart", out_path], check=True)


def xfade_concat(scene_files, durations, out_path, T=0.45):
    if len(scene_files) == 1:
        subprocess.run([FF, "-y", "-loglevel", "error", "-i", scene_files[0], "-c", "copy", out_path], check=True)
        return
    inputs = []
    for f in scene_files:
        inputs += ["-i", f]
    fc = []; prev = "[0:v]"; combined = durations[0]
    for i in range(1, len(scene_files)):
        out = f"[x{i}]"
        fc.append(f"{prev}[{i}:v]xfade=transition=fade:duration={T}:offset={combined - T:.3f}{out}")
        prev = out; combined = combined + durations[i] - T
    cmd = [FF, "-y", "-loglevel", "error", *inputs, "-filter_complex", ";".join(fc),
           "-map", prev, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "medium",
           "-crf", "19", "-r", str(FPS), "-movflags", "+faststart", out_path]
    subprocess.run(cmd, check=True)


def compose(storyboard, out_path, workdir):
    os.makedirs(workdir, exist_ok=True)
    theme = build_theme(storyboard)
    assets = {"gradient": make_gradient(theme), "starfield": make_starfield(theme)}
    scene_files, durations = [], []
    for idx, scene in enumerate(storyboard["scenes"]):
        sp = os.path.join(workdir, f"scene_{idx}.mp4"); stype = scene["scene_type"]
        if stype == "VIDEO_SCENE":
            render_video_scene(scene, sp, theme)
        else:
            render_pil_scene(scene, sp, assets, theme)
        scene_files.append(sp); durations.append(scene["duration"])
        print(f"  rendered scene {idx} [{stype}] {scene['duration']}s -> {sp}")
    T = storyboard.get("transition_s", 0.45)
    total = sum(durations) - (len(scene_files) - 1) * T
    if storyboard.get("audio"):
        vid_only = os.path.join(workdir, "_final_video.mp4"); xfade_concat(scene_files, durations, vid_only, T=T)
        wav = os.path.join(workdir, "_ambient.wav"); render_ambient(total, wav); mux_audio(vid_only, wav, out_path)
        print(f"final (with $0 ambient bed) -> {out_path}  ~{total:.1f}s")
    else:
        xfade_concat(scene_files, durations, out_path, T=T); print(f"final -> {out_path}  ~{total:.1f}s")


if __name__ == "__main__":
    sb_path, out = sys.argv[1], sys.argv[2]
    with open(sb_path) as f:
        sb = json.load(f)
    wd = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(out) or ".", "_scenes")
    compose(sb, out, wd)
