// Makes the Windows icon from the Mac one: AppIcon.icns holds PNGs, and an .ico can hold PNGs too.
// Usage: node icns-to-ico.js AppIcon.icns out.ico out.png
"use strict";
const fs = require("fs");
const [src, ico, png] = process.argv.slice(2);
const b = fs.readFileSync(src);
const pngs = {};
for (let o = 8; o < b.length; o += b.readUInt32BE(o + 4)) {
  const len = b.readUInt32BE(o + 4);
  if (len > 32 && b.readUInt32BE(o + 8) === 0x89504e47) {
    const data = b.subarray(o + 8, o + len);
    pngs[data.readUInt32BE(16)] = data;
  }
}
const sizes = [256, 128, 64, 32].filter((s) => pngs[s]);
const head = Buffer.alloc(6 + 16 * sizes.length);
head.writeUInt16LE(0, 0); head.writeUInt16LE(1, 2); head.writeUInt16LE(sizes.length, 4);
let offset = head.length;
sizes.forEach((s, i) => {
  const e = 6 + 16 * i;
  head.writeUInt8(s >= 256 ? 0 : s, e); head.writeUInt8(s >= 256 ? 0 : s, e + 1);
  head.writeUInt16LE(1, e + 4); head.writeUInt16LE(32, e + 6);
  head.writeUInt32LE(pngs[s].length, e + 8); head.writeUInt32LE(offset, e + 12);
  offset += pngs[s].length;
});
fs.writeFileSync(ico, Buffer.concat([head, ...sizes.map((s) => pngs[s])]));
if (png) fs.writeFileSync(png, pngs[256] || pngs[sizes[0]]);
console.log("icon sizes:", sizes.join(", "));
