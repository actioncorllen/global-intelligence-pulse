#!/usr/bin/env python3
"""
Strateloq Native Video Compositor (STRATELOQ-015S)
==================================================
A small, Strateloq-OWNED automated ad-production compositor. It turns a
storyboard (scene plan) + authoritative Product Card assets + existing
generated clips + deterministic copy/captions/CTA into ONE finished
multi-scene vertical short-form advertisement.

- No external editing/composition SaaS. Core renderer = FFmpeg (open source,
  server-side, scriptable) via the bundled imageio-ffmpeg static binary.
- Strateloq owns: scene definitions, timeline, durations, ordering,
  transitions, product placement, pan/zoom, backgrounds, overlays, captions,
  typography, CTA, safe zones and the final encode spec.
- Motion for IMAGE scenes is deterministic PIL frame-generation (push-in,
  parallax star drift, fades) — the product is scaled/positioned only, never
  redrawn. VIDEO scenes reuse an existing clip (e.g. the 015R Veo clip),
  upscaled without stretching.
- Transitions between scenes are real crossfades (ffmpeg xfade).

Usage: python3 pulse_compositor.py <storyboard.json> <output.mp4>
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

# ---- design system (night-sky, consistent with 015P/015R) ----
GRAD_TOP, GRAD_MID, GRAD_BOT = (31, 26, 66), (58, 48, 110), (26, 22, 54)
GOLD = (255, 201, 102)
GOLD_TEXT = (35, 29, 74)
TEXT = (245, 244, 252)
SUB = (200, 196, 224)
SAFE_X = 72  # side safe margin


def _lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def make_gradient(w=W, h=H):
    g = Image.new("RGB", (w, h))
    px = g.load()
    for y in range(h):
        t = y / (h - 1)
        c = _lerp(GRAD_TOP, GRAD_MID, t / 0.5) if t < 0.5 else _lerp(GRAD_MID, GRAD_BOT, (t - 0.5) / 0.5)
        for x in range(w):
            px[x, y] = c
    return g


def make_starfield(w=W, h=H + 260, n=260, seed=8080):
    """Taller than frame so we can scroll it for parallax drift."""
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    r = random.Random(seed)
    for _ in range(n):
        x = r.randint(0, w - 1); y = r.randint(0, h - 1)
        b = r.randint(120, 255)
        s = r.choice([1, 1, 1, 2, 2, 3])
        col = (b, b, min(255, b + 8), r.randint(120, 255))
        if s == 1:
            d.point((x, y), fill=col)
        else:
            d.ellipse([x - s / 2, y - s / 2, x + s / 2, y + s / 2], fill=col)
    return layer


def make_halo(cx, cy, maxr=560, strength=70, w=W, h=H):
    halo = Image.new("L", (w, h), 0)
    hd = ImageDraw.Draw(halo)
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


def text_layer(scene):
    """Build a static RGBA overlay for a scene's typography (crisp, stable)."""
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    def draw_center(lines, font, y, fill, lh, shadow=True):
        for ln in lines:
            tw = d.textlength(ln, font=font)
            x = (W - tw) / 2
            if shadow:
                d.text((x + 3, y + 3), ln, font=font, fill=(0, 0, 0, 150))
            d.text((x, y), ln, font=font, fill=fill + (255,))
            y += lh
        return y

    kicker = scene.get("kicker")
    if kicker:
        f = ImageFont.truetype(FONT_BOLD, 34)
        tw = d.textlength(kicker, font=f)
        d.text(((W - tw) / 2, scene.get("kicker_y", 150)), kicker, font=f, fill=GOLD + (255,))

    head = scene.get("headline")
    if head:
        f = ImageFont.truetype(FONT_BOLD, scene.get("headline_size", 78))
        lines = wrap(d, head, f, W - 2 * SAFE_X)
        y0 = scene.get("headline_y", 210)
        draw_center(lines, f, y0, TEXT, int(scene.get("headline_size", 78) * 1.16))

    sup = scene.get("supporting")
    if sup:
        f = ImageFont.truetype(FONT_REG, scene.get("supporting_size", 40))
        lines = wrap(d, sup, f, W - 2 * SAFE_X)
        draw_center(lines, f, scene.get("supporting_y", 360), SUB, int(scene.get("supporting_size", 40) * 1.2))

    cap = scene.get("caption")
    if cap:
        f = ImageFont.truetype(FONT_BOLD, 44)
        lines = wrap(d, cap, f, W - 2 * SAFE_X)
        # lower third with a soft dark band for readability
        yb = scene.get("caption_y", H - 430)
        draw_center(lines, f, yb, TEXT, 54)

    return layer


def cta_layer(scene, pulse=1.0):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cta = scene["cta"]
    f = ImageFont.truetype(FONT_BOLD, 48)
    cw = d.textlength(cta, font=f)
    pill_w = int((cw + 120) * pulse); pill_h = int(120 * pulse)
    px = (W - pill_w) // 2; py = scene.get("cta_y", H - 380)
    d.rounded_rectangle([px, py, px + pill_w, py + pill_h], radius=pill_h // 2, fill=GOLD + (255,))
    d.text((px + (pill_w - cw) / 2, py + (pill_h - 60) / 2), cta, font=f, fill=GOLD_TEXT + (255,))
    return layer


# ---- ffmpeg helpers ----

def _raw_writer(path, nframes_hint=None):
    """Return a subprocess that reads rgb24 frames on stdin and writes an mp4."""
    cmd = [FF, "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
           "-s", f"{W}x{H}", "-r", str(FPS), "-i", "pipe:0",
           "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "medium",
           "-crf", "19", "-movflags", "+faststart", path]
    return subprocess.Popen(cmd, stdin=subprocess.PIPE)


def render_pil_scene(scene, out_path, assets):
    """Frame-generate an IMAGE/TEXT/CTA scene with deterministic motion."""
    dur = scene["duration"]
    N = max(1, int(round(dur * FPS)))
    grad = assets["gradient"]
    stars = assets["starfield"]
    star_h = stars.size[1]
    txt = text_layer(scene).convert("RGBA")
    has_cta = "cta" in scene
    # product
    prod = None
    if scene.get("product_asset"):
        prod = Image.open(scene["product_asset"]).convert("RGBA")
    # halo behind product
    cy = scene.get("product_cy", 980)
    halo_img = Image.new("RGB", (W, H), (255, 238, 208))
    halo_mask = make_halo(W // 2, cy, maxr=scene.get("halo_r", 520), strength=scene.get("halo", 60))

    p = _raw_writer(out_path)
    fadein = min(0.5, dur * 0.4)
    for i in range(N):
        t = i / max(1, N - 1)
        tt = i / FPS
        frame = grad.copy()
        # star parallax drift (scroll window down slowly)
        shift = int((star_h - H) * (0.15 + 0.7 * t))
        frame.paste(stars, (0, -shift), stars)
        # warm halo grows subtly
        hm = halo_mask.point(lambda v, k=(0.6 + 0.4 * t): int(v * k))
        frame = Image.composite(halo_img, frame, hm)
        # product push-in
        if prod is not None:
            s0, s1 = scene.get("scale0", 0.98), scene.get("scale1", 1.06)
            base_w = scene.get("product_w", 640)
            sw = int(base_w * (s0 + (s1 - s0) * t))
            sh = int(prod.size[1] * sw / prod.size[0])
            pim = prod.resize((sw, sh), Image.LANCZOS)
            drift = int(scene.get("product_drift", -26) * t)
            px = (W - sw) // 2
            py = cy - sh // 2 + drift
            # soft shadow
            al = pim.split()[3]
            sh_l = Image.new("L", (W, H), 0)
            sh_l.paste(al, (px, py + 16))
            sh_l = sh_l.filter(ImageFilter.GaussianBlur(20)).point(lambda v: int(v * 0.45))
            shadow = Image.merge("RGBA", (Image.new("L", (W, H), 0),) * 3 + (sh_l,))
            frame = Image.alpha_composite(frame.convert("RGBA"), shadow).convert("RGB")
            frame.paste(pim, (px, py), pim)
        # typography (fade in)
        a = min(1.0, tt / fadein) if fadein > 0 else 1.0
        if has_cta:
            pulse = 1.0 + 0.03 * math.sin(tt * 3.2)
            over = cta_layer(scene, pulse).convert("RGBA")
        else:
            over = txt
        if a < 1.0:
            oa = over.split()[3].point(lambda v, k=a: int(v * k))
            over = Image.merge("RGBA", over.split()[:3] + (oa,))
        frame = Image.alpha_composite(frame.convert("RGBA"), over).convert("RGB")
        p.stdin.write(frame.tobytes())
    p.stdin.close()
    p.wait()


def render_video_scene(scene, out_path):
    """Normalize an existing clip to 1080x1920/30fps and overlay optional caption.
    Supports an in-point (ss) so a slice of a longer clip can be used as a beat."""
    dur = scene["duration"]
    ss = scene.get("ss", 0)
    src = scene["video_asset"]
    over_png = None
    if any(scene.get(k) for k in ("headline", "kicker", "supporting", "caption")):
        ov = text_layer(scene)
        over_png = out_path + ".over.png"
        ov.save(over_png)
    # subtle slow push-in on the clip too, so video beats never feel static
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
        cmd = [FF, "-y", "-loglevel", "error", *seek,
               "-vf", vf, "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p",
               "-preset", "medium", "-crf", "19", "-r", str(FPS), "-movflags", "+faststart", out_path]
    subprocess.run(cmd, check=True)


def render_ambient(total_s, out_wav):
    """Strateloq-generated, license-clean $0 ambient pad (soft low chord, slow tremolo,
    fades). Demonstrates the audio-mix pipeline; no external API, no rights issue."""
    d = total_s
    fc = (
        "[0:a][1:a][2:a]amix=inputs=3:normalize=0[m];"
        f"[m]volume=0.10,tremolo=f=0.12:d=0.4,"
        f"afade=t=in:st=0:d=1.3,afade=t=out:st={max(0.1,d-1.4):.2f}:d=1.4[a]"
    )
    cmd = [FF, "-y", "-loglevel", "error",
           "-f", "lavfi", "-t", str(d), "-i", "sine=frequency=110",
           "-f", "lavfi", "-t", str(d), "-i", "sine=frequency=164.81",
           "-f", "lavfi", "-t", str(d), "-i", "sine=frequency=220",
           "-filter_complex", fc, "-map", "[a]", "-c:a", "pcm_s16le", out_wav]
    subprocess.run(cmd, check=True)


def mux_audio(video_in, wav_in, out_path):
    cmd = [FF, "-y", "-loglevel", "error", "-i", video_in, "-i", wav_in,
           "-c:v", "copy", "-c:a", "aac", "-b:a", "128k", "-shortest",
           "-movflags", "+faststart", out_path]
    subprocess.run(cmd, check=True)


def xfade_concat(scene_files, durations, out_path, T=0.45):
    """Crossfade-concatenate normalized scene mp4s."""
    if len(scene_files) == 1:
        subprocess.run([FF, "-y", "-loglevel", "error", "-i", scene_files[0], "-c", "copy", out_path], check=True)
        return
    inputs = []
    for f in scene_files:
        inputs += ["-i", f]
    fc = []
    prev = "[0:v]"
    combined = durations[0]
    for i in range(1, len(scene_files)):
        offset = combined - T
        out = f"[x{i}]"
        fc.append(f"{prev}[{i}:v]xfade=transition=fade:duration={T}:offset={offset:.3f}{out}")
        prev = out
        combined = combined + durations[i] - T
    filt = ";".join(fc)
    cmd = [FF, "-y", "-loglevel", "error", *inputs, "-filter_complex", filt,
           "-map", prev, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "medium",
           "-crf", "19", "-r", str(FPS), "-movflags", "+faststart", out_path]
    subprocess.run(cmd, check=True)


def compose(storyboard, out_path, workdir):
    os.makedirs(workdir, exist_ok=True)
    assets = {"gradient": make_gradient(), "starfield": make_starfield()}
    scene_files, durations = [], []
    for idx, scene in enumerate(storyboard["scenes"]):
        sp = os.path.join(workdir, f"scene_{idx}.mp4")
        stype = scene["scene_type"]
        if stype == "VIDEO_SCENE":
            render_video_scene(scene, sp)
        else:  # IMAGE_SCENE / TEXT_SCENE / CTA_SCENE
            render_pil_scene(scene, sp, assets)
        scene_files.append(sp)
        durations.append(scene["duration"])
        print(f"  rendered scene {idx} [{stype}] {scene['duration']}s -> {sp}")
    T = storyboard.get("transition_s", 0.45)
    total = sum(durations) - (len(scene_files) - 1) * T
    if storyboard.get("audio"):
        vid_only = os.path.join(workdir, "_final_video.mp4")
        xfade_concat(scene_files, durations, vid_only, T=T)
        wav = os.path.join(workdir, "_ambient.wav")
        render_ambient(total, wav)
        mux_audio(vid_only, wav, out_path)
        print(f"final (with $0 ambient bed) -> {out_path}  ~{total:.1f}s")
    else:
        xfade_concat(scene_files, durations, out_path, T=T)
        print(f"final -> {out_path}  ~{total:.1f}s")


if __name__ == "__main__":
    sb_path, out = sys.argv[1], sys.argv[2]
    with open(sb_path) as f:
        sb = json.load(f)
    wd = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(out) or ".", "_scenes")
    compose(sb, out, wd)
