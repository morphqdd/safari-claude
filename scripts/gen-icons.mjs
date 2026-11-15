// Generates extension/icons/{16,32,48,128}.png: orange (#D97757) circle with a white arrow.
import { deflateSync } from "node:zlib";
import { writeFileSync } from "node:fs";

const crcT = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc = (b) => {
  let c = 0xffffffff;
  for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
const chunk = (t, d) => {
  const o = Buffer.alloc(12 + d.length);
  o.writeUInt32BE(d.length, 0);
  o.write(t, 4, "latin1");
  d.copy(o, 8);
  o.writeUInt32BE(crc(o.subarray(4, 8 + d.length)), 8 + d.length);
  return o;
};
function png(n) {
  const raw = Buffer.alloc(n * (n * 4 + 1));
  const c = n / 2, r = n / 2 - 0.5;
  for (let y = 0; y < n; y++) {
    raw[y * (n * 4 + 1)] = 0;
    for (let x = 0; x < n; x++) {
      const i = y * (n * 4 + 1) + 1 + x * 4;
      const u = (x + 0.5) / n, v = (y + 0.5) / n;
      const inCircle = Math.hypot(x + 0.5 - c, y + 0.5 - c) <= r;
      // arrow pointing up-left: triangle head + shaft
      const head = u > 0.28 && v > 0.28 && u + v < 0.95 && u < 0.7 && v < 0.7 && Math.abs(u - v) < 0.4;
      const shaft = Math.abs(u - v) < 0.07 && u > 0.35 && u < 0.72;
      const arrow = head || shaft;
      const px = !inCircle ? [0, 0, 0, 0] : arrow ? [255, 255, 255, 255] : [0xd9, 0x77, 0x57, 255];
      raw.set(px, i);
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(n, 0); ihdr.writeUInt32BE(n, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}
for (const n of [16, 32, 48, 128]) writeFileSync(`extension/icons/${n}.png`, png(n));
