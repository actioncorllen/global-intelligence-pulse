// Pure image-dimension + container parser for CS.02 media verification (BE345).
// Reads width/height from the leading bytes of JPEG / PNG / GIF / WEBP without any
// dependency, so the verify edge can measure a discovered candidate cheaply (a ranged
// GET of the first ~128 KB). Returns null when the bytes are not a recognised image or
// are truncated before the dimensions — the caller then records UNKNOWN, never a guess.
//
// This is metadata only. Measuring an image NEVER changes its rights_state or grants any
// use: CS.02 keeps discovery/research separate from AI-input/commercial authorisation.

export type ImageDims = { width: number; height: number; format: "JPEG" | "PNG" | "GIF" | "WEBP" } | null;

export function parseImageDimensions(b: Uint8Array): ImageDims {
  if (b.length < 24) return null;

  // PNG: 89 50 4E 47 0D 0A 1A 0A, then IHDR at byte 16 (width, height big-endian u32).
  if (
    b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 &&
    b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a
  ) {
    const width = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
    const height = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    if (width > 0 && height > 0) return { width: width >>> 0, height: height >>> 0, format: "PNG" };
    return null;
  }

  // GIF: "GIF87a"/"GIF89a", width/height little-endian u16 at bytes 6..9.
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) {
    const width = b[6] | (b[7] << 8);
    const height = b[8] | (b[9] << 8);
    if (width > 0 && height > 0) return { width, height, format: "GIF" };
    return null;
  }

  // WEBP: "RIFF"...."WEBP" then a VP8/VP8L/VP8X chunk.
  if (
    b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
    b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50
  ) {
    const fourcc = String.fromCharCode(b[12], b[13], b[14], b[15]);
    if (fourcc === "VP8 " && b.length >= 30) {
      // Lossy: 16-bit width/height (14 bits used) at offset 26.
      const width = (b[26] | (b[27] << 8)) & 0x3fff;
      const height = (b[28] | (b[29] << 8)) & 0x3fff;
      if (width > 0 && height > 0) return { width, height, format: "WEBP" };
    } else if (fourcc === "VP8L" && b.length >= 25) {
      // Lossless: 1 signature byte (0x2f) then 14-bit width-1, 14-bit height-1.
      const bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      const width = (bits & 0x3fff) + 1;
      const height = ((bits >> 14) & 0x3fff) + 1;
      if (width > 0 && height > 0) return { width, height, format: "WEBP" };
    } else if (fourcc === "VP8X" && b.length >= 30) {
      // Extended: 24-bit width-1, 24-bit height-1 at offset 24.
      const width = ((b[24] | (b[25] << 8) | (b[26] << 16)) & 0xffffff) + 1;
      const height = ((b[27] | (b[28] << 8) | (b[29] << 16)) & 0xffffff) + 1;
      if (width > 0 && height > 0) return { width, height, format: "WEBP" };
    }
    return null;
  }

  // JPEG: FF D8, then walk segment markers to a Start-Of-Frame (SOF0..SOF15 except
  // DHT/JPG/DAC), whose payload has height (u16) then width (u16) after the precision byte.
  if (b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    const n = b.length;
    while (i + 9 < n) {
      if (b[i] !== 0xff) { i++; continue; }
      let marker = b[i + 1];
      // Skip fill bytes (0xFF padding).
      while (marker === 0xff && i + 1 < n) { i++; marker = b[i + 1]; }
      // Standalone markers with no length (RSTn, SOI, EOI, TEM).
      if (marker === 0xd8 || marker === 0xd9 || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) {
        i += 2;
        continue;
      }
      if (i + 3 >= n) break;
      const seg = (b[i + 2] << 8) | b[i + 3];
      const isSOF = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
      if (isSOF) {
        if (i + 9 >= n) return null;
        const height = (b[i + 5] << 8) | b[i + 6];
        const width = (b[i + 7] << 8) | b[i + 8];
        if (width > 0 && height > 0) return { width, height, format: "JPEG" };
        return null;
      }
      if (seg < 2) return null; // malformed
      i += 2 + seg;
    }
    return null;
  }

  return null;
}
