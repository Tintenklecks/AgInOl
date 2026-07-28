import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

const root = process.cwd();
const project = JSON.parse(await fs.readFile(path.join(root, "app-store-screenshots.json"), "utf8"));
const outputRoot = path.join(root, "screenshots");
const expectedPerLocale = 12;
const failures = [];
let checked = 0;

for (const locale of project.locales) {
  const localeDir = path.join(outputRoot, locale);
  const entries = (await fs.readdir(localeDir)).filter((name) => name.endsWith(".png") && name.includes("_AGINOL_"));
  if (entries.length !== expectedPerLocale) {
    failures.push(`${locale}: expected ${expectedPerLocale} marketing PNGs, found ${entries.length}`);
  }
  for (const name of entries) {
    const file = path.join(localeDir, name);
    const metadata = await sharp(file).metadata();
    const expected = name.includes("_IPHONE_") ? { width: 1320, height: 2868 } : { width: 2752, height: 2064 };
    if (metadata.width !== expected.width || metadata.height !== expected.height) {
      failures.push(`${locale}/${name}: ${metadata.width}x${metadata.height}`);
    }
    if (metadata.hasAlpha) failures.push(`${locale}/${name}: unexpected alpha channel`);
    if (metadata.format !== "png") failures.push(`${locale}/${name}: expected PNG, got ${metadata.format}`);
    checked += 1;
  }
}

const sourcePairs = [
  ["scteenshots_raw/Mac Screenshot.png", "public/screenshots/apple/shared/mac-dashboard.png"],
  ["scteenshots_raw/iphone-0.png", "public/screenshots/apple/iphone/00.png"],
  ["scteenshots_raw/ipad-0.png", "public/screenshots/apple/ipad/00.png"],
];
for (const [raw, copied] of sourcePairs) {
  const [a, b] = await Promise.all([fs.readFile(path.join(root, raw)), fs.readFile(path.join(root, copied))]);
  const digest = (buffer) => crypto.createHash("sha256").update(buffer).digest("hex");
  if (digest(a) !== digest(b)) failures.push(`${copied}: source copy differs from ${raw}`);
}

async function makeContactSheet(device, locales, output) {
  const isPhone = device === "IPHONE";
  const thumbW = isPhone ? 160 : 320;
  const thumbH = isPhone ? 348 : 240;
  const gap = 14;
  const columns = 6;
  const width = columns * thumbW + (columns + 1) * gap;
  const height = locales.length * thumbH + (locales.length + 1) * gap;
  const composites = [];
  for (let row = 0; row < locales.length; row += 1) {
    for (let column = 0; column < columns; column += 1) {
      const name = `${String(column + 1).padStart(2, "0")}_AGINOL_${device}_${isPhone ? "69" : "13"}.png`;
      const input = await sharp(path.join(outputRoot, locales[row], name)).resize(thumbW, thumbH, { fit: "fill" }).png().toBuffer();
      composites.push({ input, left: gap + column * (thumbW + gap), top: gap + row * (thumbH + gap) });
    }
  }
  await sharp({
    create: { width, height, channels: 3, background: "#242830" },
  }).composite(composites).png().toFile(output);
}

await makeContactSheet("IPHONE", ["en-US", "de-DE", "hi", "ja", "zh-Hans"], "/tmp/aginol-qa-iphone.png");
await makeContactSheet("IPAD", ["en-US", "de-DE", "hi", "ja", "zh-Hans"], "/tmp/aginol-qa-ipad.png");

if (failures.length) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log(`Verified ${checked} marketing PNGs across ${project.locales.length} locales.`);
