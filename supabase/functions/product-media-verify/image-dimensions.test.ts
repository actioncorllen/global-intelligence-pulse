// Deterministic tests for the pure image-dimension parser (BE345 CS.02 verification).
// Run: `deno test supabase/functions/product-media-verify/image-dimensions.test.ts`
// Crafted header bytes only; no network, no files.
import { parseImageDimensions } from "./image-dimensions.ts";

function ok(c: unknown, m: string): asserts c {
  if (!c) throw new Error("ASSERT FAILED: " + m);
}
function eq<T>(a: T, b: T, m: string) {
  if (a !== b) throw new Error(`ASSERT EQ FAILED: ${m} (got ${JSON.stringify(a)} !== ${JSON.stringify(b)})`);
}
const u8 = (...xs: number[]) => Uint8Array.from(xs);
function pad(a: Uint8Array, n: number): Uint8Array {
  if (a.length >= n) return a;
  const out = new Uint8Array(n);
  out.set(a);
  return out;
}

Deno.test("PNG 800x600", () => {
  const b = pad(u8(0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a, 0,0,0,0x0d, 0x49,0x48,0x44,0x52,
    0x00,0x00,0x03,0x20, 0x00,0x00,0x02,0x58), 32); // 0x320=800, 0x258=600
  const d = parseImageDimensions(b);
  ok(d, "parsed"); eq(d!.format, "PNG", "fmt"); eq(d!.width, 800, "w"); eq(d!.height, 600, "h");
});

Deno.test("JPEG 640x480 via SOF0", () => {
  const b = pad(u8(0xff,0xd8, 0xff,0xc0, 0x00,0x11, 0x08, 0x01,0xe0, 0x02,0x80, 0,0,0,0,0,0), 32);
  const d = parseImageDimensions(b);
  ok(d, "parsed"); eq(d!.format, "JPEG", "fmt"); eq(d!.width, 640, "w"); eq(d!.height, 480, "h");
});

Deno.test("JPEG with a leading APP0 segment then SOF2", () => {
  // FF D8, APP0 (FF E0 len=0x0010 + 14 bytes), then SOF2 (FF C2) 300x200.
  const app0 = [0xff,0xe0,0x00,0x10, 0x4a,0x46,0x49,0x46,0x00,0x01,0x01,0x00,0x00,0x01,0x00,0x01,0x00,0x00];
  const sof2 = [0xff,0xc2,0x00,0x11,0x08, 0x00,0xc8, 0x01,0x2c, 0,0,0,0,0,0,0,0];
  const b = Uint8Array.from([0xff,0xd8, ...app0, ...sof2]);
  const d = parseImageDimensions(b);
  ok(d, "parsed"); eq(d!.width, 300, "w"); eq(d!.height, 200, "h"); // 0x12c=300, 0xc8=200
});

Deno.test("GIF89a 320x240", () => {
  const b = pad(u8(0x47,0x49,0x46,0x38,0x39,0x61, 0x40,0x01, 0xf0,0x00), 24); // 0x140=320, 0xf0=240
  const d = parseImageDimensions(b);
  ok(d, "parsed"); eq(d!.format, "GIF", "fmt"); eq(d!.width, 320, "w"); eq(d!.height, 240, "h");
});

Deno.test("WEBP VP8X 1024x768", () => {
  // RIFF <size> WEBP VP8X <chunksize> flags res(3) width-1(3 LE) height-1(3 LE)
  const b = pad(u8(
    0x52,0x49,0x46,0x46, 0,0,0,0, 0x57,0x45,0x42,0x50, 0x56,0x50,0x38,0x58,
    0x0a,0,0,0, 0x00, 0,0,0, 0xff,0x03,0x00, 0xff,0x02,0x00), 32); // 1023 -> 1024, 767 -> 768
  const d = parseImageDimensions(b);
  ok(d, "parsed"); eq(d!.format, "WEBP", "fmt"); eq(d!.width, 1024, "w"); eq(d!.height, 768, "h");
});

Deno.test("truncated / garbage -> null (never a guess)", () => {
  eq(parseImageDimensions(u8(0x89,0x50,0x4e,0x47)), null, "short png -> null");
  eq(parseImageDimensions(u8(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24)), null, "garbage -> null");
  eq(parseImageDimensions(u8(0xff,0xd8,0xff,0xd9)), null, "empty jpeg -> null");
});
