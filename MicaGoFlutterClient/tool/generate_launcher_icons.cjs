// Asset packaging only: npm package `sharp` is a development tool, not an app dependency.
// Run from any directory: NODE_PATH=<directory containing sharp> node tool/generate_launcher_icons.cjs
const sharp = require('sharp');
const fs = require('node:fs/promises');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const res = path.join(root, 'android/app/src/main/res');
const previews = path.join(root, 'lib/Assets/launcher_icons');
const densities = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };

async function normalizedForeground(source, visualScale = 1) {
  // Fit the complete alpha silhouette into a 58dp box on the 108dp layer.
  // Transparent padding in generated source images must not change the optical size.
  const image = sharp(source).ensureAlpha();
  const { data, info } = await image.raw().toBuffer({ resolveWithObject: true });
  let left = info.width, top = info.height, right = 0, bottom = 0;
  for (let y = 0; y < info.height; y++) {
    for (let x = 0; x < info.width; x++) {
      if (data[(y * info.width + x) * 4 + 3] > 32) {
        left = Math.min(left, x); top = Math.min(top, y);
        right = Math.max(right, x); bottom = Math.max(bottom, y);
      }
    }
  }
  const fitted = await image.extract({ left, top, width: right - left + 1, height: bottom - top + 1 })
    .resize(580, 580, { fit: 'contain', background: '#00000000' })
    .extend({ top: 250, bottom: 250, left: 250, right: 250, background: '#00000000' })
    .png().toBuffer();
  const pixels = await sharp(fitted).ensureAlpha().raw().toBuffer();
  let radius = 0;
  for (let y = 0; y < 1080; y++) {
    for (let x = 0; x < 1080; x++) {
      if (pixels[(y * 1080 + x) * 4 + 3] > 32) {
        radius = Math.max(radius, Math.hypot(x - 539.5, y - 539.5));
      }
    }
  }
  // Keep even the tail inside the 66dp safe circle, with 1dp extra clearance.
  const side = Math.floor(Math.min(1080, 1080 * 320 / radius) * visualScale);
  const before = Math.floor((1080 - side) / 2);
  return sharp(fitted).resize(side).extend({
    left: before, right: 1080 - side - before,
    top: before, bottom: 1080 - side - before, background: '#00000000',
  }).png().toBuffer();
}

async function monochrome(foreground) {
  const { data, info } = await sharp(foreground).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  // Transparent cutouts retain the eyes, smile and m when tinted by the launcher.
  for (let i = 0; i < data.length; i += 4) {
    const luminance = .2126 * data[i] + .7152 * data[i + 1] + .0722 * data[i + 2];
    data[i + 3] = Math.round(data[i + 3] * Math.max(0, Math.min(1, (luminance - 40) / 24)));
    data[i] = data[i + 1] = data[i + 2] = 255;
  }
  return sharp(data, { raw: info }).png().toBuffer();
}

function layer(background) {
  return sharp({ create: { width: 1080, height: 1080, channels: 4, background } });
}

function adaptive(name, background = `@color/${name}_background`) {
  return `<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="${background}" />
  <foreground android:drawable="@mipmap/${name}_foreground" />
  <monochrome android:drawable="@mipmap/${name}_monochrome" />
</adaptive-icon>\n`;
}

async function main() {
  await fs.mkdir(previews, { recursive: true });
  await fs.mkdir(path.join(res, 'mipmap-anydpi-v26'), { recursive: true });
  const colors = [];
  for (const [id, background] of [['default', '#FFF7EB'], ['minimal', '#104753']]) {
    const name = `ic_launcher_${id}`;
    // New icons share an extra 4% breathing room; classic resources remain untouched.
    const foreground = await normalizedForeground(
      path.join(__dirname, `launcher_icons/${id}-foreground.svg`),
      0.96,
    );
    const mono = await monochrome(foreground);
    // The 72dp launcher viewport sits at the center of a 108dp adaptive layer.
    const base = layer(background);
    const flattened = await base.composite([{ input: foreground }]).png().toBuffer();
    const viewport = await sharp(flattened).extract({ left: 180, top: 180, width: 720, height: 720 }).png().toBuffer();
    await sharp(viewport).resize(256).png().toFile(path.join(previews, `${id}.png`));
    await sharp(mono).extract({ left: 180, top: 180, width: 720, height: 720 }).resize(256)
      .png().toFile(path.join(__dirname, `launcher_icons/${id}-monochrome-preview.png`));
    for (const [density, scale] of Object.entries(densities)) {
      const dir = path.join(res, `mipmap-${density}`);
      await fs.mkdir(dir, { recursive: true });
      const size = Math.round(48 * scale);
      await sharp(foreground).resize(Math.round(108 * scale)).png().toFile(path.join(dir, `${name}_foreground.png`));
      await sharp(mono).resize(Math.round(108 * scale)).png().toFile(path.join(dir, `${name}_monochrome.png`));
      // Pre-26 icons have their own silhouette; adaptive icons leave masking to Android.
      for (const [suffix, shape] of [
        ['', `<rect width="${size}" height="${size}" rx="${size * .22}" fill="white"/>`],
        ['_round', `<circle cx="${size / 2}" cy="${size / 2}" r="${size / 2}" fill="white"/>`],
      ]) {
        const mask = Buffer.from(`<svg width="${size}" height="${size}">${shape}</svg>`);
        await sharp(viewport).resize(size).composite([{ input: mask, blend: 'dest-in' }])
          .png().toFile(path.join(dir, `${name}${suffix}.png`));
      }
    }
    const backgroundResource = `@color/${name}_background`;
    await fs.writeFile(path.join(res, `mipmap-anydpi-v26/${name}.xml`), adaptive(name, backgroundResource));
    await fs.writeFile(path.join(res, `mipmap-anydpi-v26/${name}_round.xml`), adaptive(name, backgroundResource));
    colors.push(`  <color name="${name}_background">${background}</color>`);
  }
  await fs.writeFile(path.join(res, 'values/launcher_icon_colors.xml'),
    `<?xml version="1.0" encoding="utf-8"?>\n<resources>\n${colors.join('\n')}\n</resources>\n`);
  // Preview the untouched original adaptive foreground through its 72dp viewport.
  // The old legacy thumbnail has extra padding and does not match Android 8+.
  await sharp(path.join(res, 'mipmap-xxxhdpi/ic_launcher_foreground.png'))
    .extract({ left: 72, top: 72, width: 288, height: 288 })
    .resize(256).png().toFile(path.join(previews, 'classic.png'));
  const sheet = Buffer.from(`<svg width="900" height="460" xmlns="http://www.w3.org/2000/svg">
    <rect width="900" height="460" fill="#F5F3EF"/>
    <g font-family="sans-serif" fill="#263648" text-anchor="middle">
      <text x="450" y="42" font-size="24">micaGO · Android</text>
      <text x="150" y="315" font-size="20">Default</text>
      <text x="450" y="315" font-size="20">Classic</text>
      <text x="750" y="315" font-size="20">Minimal</text>
    </g></svg>`);
  const tiles = [];
  for (const [i, id] of ['default', 'classic', 'minimal'].entries()) {
    const mask = Buffer.from('<svg width="210" height="210"><circle cx="105" cy="105" r="105" fill="white"/></svg>');
    const icon = await sharp(path.join(previews, `${id}.png`)).resize(210)
      .composite([{ input: mask, blend: 'dest-in' }]).png().toBuffer();
    tiles.push({ input: icon, left: i * 300 + 45, top: 78 });
    if (id !== 'classic') {
      const alpha = await sharp(path.join(__dirname, `launcher_icons/${id}-monochrome-preview.png`))
        .resize(64).extractChannel(3).png().toBuffer();
      const mono = await sharp({ create: { width: 64, height: 64, channels: 3, background: '#23372F' } })
        .joinChannel(alpha).png().toBuffer();
      const tile = await sharp({ create: { width: 76, height: 76, channels: 4, background: '#DCE4CD' } })
        .composite([{ input: mono, left: 6, top: 6 }]).png().toBuffer();
      tiles.push({ input: tile, left: i * 300 + 112, top: 348 });
    }
  }
  await sharp(sheet).composite(tiles).png().toFile(path.join(__dirname, 'launcher_icons/preview.png'));
}

main().catch(error => { console.error(error); process.exitCode = 1; });
