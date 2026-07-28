import fs from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

const root = process.cwd();
const project = JSON.parse(await fs.readFile(path.join(root, "app-store-screenshots.json"), "utf8"));
const outputRoot = path.join(root, "screenshots");
const publicRoot = path.join(root, "public");
const accents = ["#52C7FF", "#FFB21A", "#A887FF", "#FF914D", "#47D97A", "#FF4FA3"];
const fontStack = "-apple-system, BlinkMacSystemFont, SF Pro Display, Noto Sans, Arial, sans-serif";

function escapeXml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function pickText(field, locale) {
  return field?.[locale] || field?.en || Object.values(field || {}).find(Boolean) || "";
}

function sourcePath(url) {
  const relative = url.replace(/^\//, "");
  if (!relative.startsWith("screenshots/apple/")) {
    throw new Error(`Unexpected screenshot source: ${url}`);
  }
  return path.join(publicRoot, relative);
}

function backgroundSvg(width, height, accent, inverted) {
  const base = inverted ? "#E9EDF4" : "#090B10";
  const base2 = inverted ? "#C9D1DE" : "#111724";
  const grid = inverted ? "rgba(17,21,28,0.055)" : "rgba(255,255,255,0.035)";
  return Buffer.from(`
    <svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="${base}"/>
          <stop offset="1" stop-color="${base2}"/>
        </linearGradient>
        <radialGradient id="glow" cx="78%" cy="12%" r="72%">
          <stop offset="0" stop-color="${accent}" stop-opacity="${inverted ? 0.22 : 0.34}"/>
          <stop offset="0.48" stop-color="${accent}" stop-opacity="0.05"/>
          <stop offset="1" stop-color="${accent}" stop-opacity="0"/>
        </radialGradient>
        <pattern id="grid" width="72" height="72" patternUnits="userSpaceOnUse">
          <path d="M72 0H0V72" fill="none" stroke="${grid}" stroke-width="1"/>
        </pattern>
      </defs>
      <rect width="100%" height="100%" fill="url(#bg)"/>
      <rect width="100%" height="100%" fill="url(#glow)"/>
      <rect width="100%" height="100%" fill="url(#grid)"/>
      <circle cx="${width * 0.92}" cy="${height * 0.83}" r="${Math.min(width, height) * 0.16}" fill="${accent}" opacity="${inverted ? 0.07 : 0.10}"/>
    </svg>
  `);
}

function textSvg({ width, height, headline, x, y, boxWidth, align = "left", accent, inverted, label = "" }) {
  const lines = headline.split("\n");
  const longest = Math.max(...lines.map((line) => [...line].length));
  const baseSize = width > height ? 116 : 108;
  const lengthSize = longest > 28 ? baseSize * 0.68 : longest > 21 ? baseSize * 0.80 : longest > 15 ? baseSize * 0.90 : baseSize;
  const usesWideGlyphs = /[\u0900-\u0fff\u2e80-\u9fff\uac00-\ud7af]/u.test(headline);
  const glyphFactor = usesWideGlyphs ? 0.75 : 0.50;
  const boxFitSize = (boxWidth * 0.94) / Math.max(1, longest * glyphFactor);
  const fontSize = Math.min(lengthSize, boxFitSize);
  const lineHeight = fontSize * 1.02;
  const anchor = align === "center" ? "middle" : align === "right" ? "end" : "start";
  const tx = align === "center" ? x + boxWidth / 2 : align === "right" ? x + boxWidth : x;
  const fg = inverted ? "#11151C" : "#F7F8FA";
  const muted = inverted ? "#4E5A6B" : "#A3ADBC";
  const labelMarkup = label
    ? `<text x="${tx}" y="${y}" text-anchor="${anchor}" font-family="${fontStack}" font-size="${Math.max(28, fontSize * 0.27)}" font-weight="700" letter-spacing="2.5" fill="${accent}">${escapeXml(label)}</text>`
    : `<rect x="${align === "center" ? tx - 46 : x}" y="${y - 12}" width="92" height="10" rx="5" fill="${accent}"/>`;
  const startY = y + (label ? fontSize * 0.72 : fontSize * 0.42);
  const tspans = lines
    .map((line, index) => `<tspan x="${tx}" y="${startY + index * lineHeight}">${escapeXml(line)}</tspan>`)
    .join("");
  return Buffer.from(`
    <svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">
      ${labelMarkup}
      <text text-anchor="${anchor}" font-family="${fontStack}" font-size="${fontSize}" font-weight="780" letter-spacing="-2.2" fill="${fg}">${tspans}</text>
      <text x="${tx}" y="${startY + lines.length * lineHeight + fontSize * 0.20}" text-anchor="${anchor}" font-family="${fontStack}" font-size="${Math.max(24, fontSize * 0.23)}" font-weight="600" letter-spacing="1.2" fill="${muted}">AGINOL COMPANION</text>
    </svg>
  `);
}

async function roundedImage(input, width, height, radius) {
  const mask = Buffer.from(`<svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg"><rect width="${width}" height="${height}" rx="${radius}" fill="#fff"/></svg>`);
  return sharp(input)
    .resize(width, height, { fit: "cover", position: "top" })
    .composite([{ input: mask, blend: "dest-in" }])
    .png()
    .toBuffer();
}

async function phoneVisual(input, width) {
  const height = Math.round(width * 2868 / 1320);
  const inset = Math.max(14, Math.round(width * 0.022));
  const screen = await roundedImage(input, width - inset * 2, height - inset * 2, Math.round(width * 0.105));
  const frame = Buffer.from(`
    <svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">
      <defs><linearGradient id="f" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#4A4E57"/><stop offset=".45" stop-color="#101216"/><stop offset="1" stop-color="#30343C"/></linearGradient></defs>
      <rect x="1" y="1" width="${width - 2}" height="${height - 2}" rx="${Math.round(width * 0.12)}" fill="url(#f)" stroke="rgba(255,255,255,.34)" stroke-width="3"/>
    </svg>
  `);
  return {
    width,
    height,
    buffer: await sharp(frame)
      .composite([{ input: screen, left: inset, top: inset }])
      .png()
      .toBuffer(),
  };
}

async function ipadVisual(input, width) {
  const height = Math.round(width * 0.75);
  const inset = Math.max(20, Math.round(width * 0.022));
  const screen = await roundedImage(input, width - inset * 2, height - inset * 2, Math.round(width * 0.025));
  const frame = Buffer.from(`
    <svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">
      <defs><linearGradient id="f" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#4A4E57"/><stop offset=".5" stop-color="#121419"/><stop offset="1" stop-color="#343841"/></linearGradient></defs>
      <rect x="1" y="1" width="${width - 2}" height="${height - 2}" rx="${Math.round(width * 0.038)}" fill="url(#f)" stroke="rgba(255,255,255,.32)" stroke-width="4"/>
    </svg>
  `);
  return {
    width,
    height,
    buffer: await sharp(frame)
      .composite([{ input: screen, left: inset, top: inset }])
      .png()
      .toBuffer(),
  };
}

async function macVisual(input, width) {
  const metadata = await sharp(input).metadata();
  const height = Math.round(width * metadata.height / metadata.width);
  return {
    width,
    height,
    buffer: await sharp(input).resize(width, height, { fit: "contain" }).png().toBuffer(),
  };
}

function shadowSvg(width, height, x, y, radius, opacity = 0.5) {
  return Buffer.from(`
    <svg width="${width}" height="${height}" xmlns="http://www.w3.org/2000/svg">
      <defs><filter id="s" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="${Math.max(18, radius * 0.55)}"/></filter></defs>
      <rect x="${x}" y="${y}" width="${Math.max(1, width - x * 2)}" height="${Math.max(1, height - y * 2)}" rx="${radius}" fill="#000" opacity="${opacity}" filter="url(#s)"/>
    </svg>
  `);
}

async function renderIphone(slide, locale, index) {
  const width = 1320;
  const height = 2868;
  const accent = accents[index % accents.length];
  const inverted = Boolean(slide.inverted);
  const headline = pickText(slide.headline, locale);
  const layers = [];

  if (index === 0) {
    const mac = await macVisual(sourcePath(slide.screenshotSecondary), 1080);
    const phone = await phoneVisual(sourcePath(slide.screenshot), 610);
    layers.push({ input: shadowSvg(1160, 1100, 60, 70, 90), left: 80, top: 650 });
    layers.push({ input: mac.buffer, left: 120, top: 720 });
    layers.push({ input: shadowSvg(720, 1450, 55, 60, 90), left: 310, top: 1300 });
    layers.push({ input: phone.buffer, left: 400, top: 1370 });
    layers.push({ input: textSvg({ width, height, headline, x: 80, y: 145, boxWidth: 1160, align: "center", accent, inverted, label: "MAC  •  iCLOUD  •  IPHONE" }), left: 0, top: 0 });
  } else {
    const phoneWidth = index === 5 ? 800 : 840;
    const phone = await phoneVisual(sourcePath(slide.screenshot), phoneWidth);
    const topDevice = index === 2 || index === 4;
    const phoneLeft = Math.round((width - phone.width) / 2);
    const phoneTop = topDevice ? 80 : 890;
    layers.push({ input: shadowSvg(phone.width + 130, phone.height + 130, 60, 60, 90), left: phoneLeft - 65, top: phoneTop - 40 });
    layers.push({ input: phone.buffer, left: phoneLeft, top: phoneTop });
    layers.push({
      input: textSvg({
        width,
        height,
        headline,
        x: 95,
        y: topDevice ? 2250 : 170,
        boxWidth: 1130,
        align: "center",
        accent,
        inverted,
      }),
      left: 0,
      top: 0,
    });
  }

  return sharp(backgroundSvg(width, height, accent, inverted))
    .composite(layers)
    .removeAlpha()
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer();
}

async function renderIpad(slide, locale, index) {
  const width = 2752;
  const height = 2064;
  const accent = accents[index % accents.length];
  const inverted = Boolean(slide.inverted);
  const headline = pickText(slide.headline, locale);
  const layers = [];

  if (index === 0) {
    const mac = await macVisual(sourcePath(slide.screenshotSecondary), 1390);
    const ipad = await ipadVisual(sourcePath(slide.screenshot), 1420);
    layers.push({ input: shadowSvg(1480, 1300, 60, 60, 90), left: 80, top: 640 });
    layers.push({ input: mac.buffer, left: 120, top: 720 });
    layers.push({ input: shadowSvg(1520, 1200, 60, 60, 80), left: 1200, top: 680 });
    layers.push({ input: ipad.buffer, left: 1270, top: 770 });
    layers.push({ input: textSvg({ width, height, headline, x: 160, y: 105, boxWidth: 2432, align: "center", accent, inverted, label: "MAC  •  iCLOUD  •  IPAD" }), left: 0, top: 0 });
  } else {
    const ipad = await ipadVisual(sourcePath(slide.screenshot), index % 2 === 0 ? 1450 : 1510);
    const visualLeft = index % 2 === 0 ? 110 : width - ipad.width - 110;
    const textLeft = index % 2 === 0 ? 1650 : 130;
    const textWidth = 950;
    layers.push({ input: shadowSvg(ipad.width + 140, ipad.height + 140, 65, 65, 80), left: visualLeft - 70, top: 350 });
    layers.push({ input: ipad.buffer, left: visualLeft, top: 420 });
    layers.push({
      input: textSvg({
        width,
        height,
        headline,
        x: textLeft,
        y: 690,
        boxWidth: textWidth,
        align: "left",
        accent,
        inverted,
      }),
      left: 0,
      top: 0,
    });
  }

  return sharp(backgroundSvg(width, height, accent, inverted))
    .composite(layers)
    .removeAlpha()
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer();
}

await Promise.all(project.locales.map((locale) => fs.mkdir(path.join(outputRoot, locale), { recursive: true })));

let rendered = 0;
for (const locale of project.locales) {
  const localeDir = path.join(outputRoot, locale);
  for (let index = 0; index < project.slidesByDevice.iphone.length; index += 1) {
    const output = await renderIphone(project.slidesByDevice.iphone[index], locale, index);
    await fs.writeFile(path.join(localeDir, `${String(index + 1).padStart(2, "0")}_AGINOL_IPHONE_69.png`), output);
    rendered += 1;
  }
  for (let index = 0; index < project.slidesByDevice.ipad.length; index += 1) {
    const output = await renderIpad(project.slidesByDevice.ipad[index], locale, index);
    await fs.writeFile(path.join(localeDir, `${String(index + 1).padStart(2, "0")}_AGINOL_IPAD_13.png`), output);
    rendered += 1;
  }
}

console.log(`Rendered ${rendered} marketing screenshots across ${project.locales.length} locales.`);
