#!/usr/bin/env node
/**
 * patch-window.js — Patch Claude Desktop window decorations for Linux CSD
 *
 * Usage: node patch-window.js <path-to-extracted-asar-dir>
 *
 * Replaces macOS-specific title bar settings with Linux frameless CSD:
 *   titleBarStyle:"hidden" + titleBarOverlay:false
 *
 * We do NOT use Electron's titleBarOverlay on Linux because it draws invisible
 * window controls at a compositor layer above all web content. When the plan
 * panel (or other sidebar panels) have their own header buttons at the top-right,
 * those buttons are click-trapped behind the overlay — users can see them but
 * can't click them.
 *
 * Instead, we inject our own window control buttons (min/max/close) into the
 * app's DOM at z-index max, positioned on the LEFT side next to the Claude icon
 * so they never conflict with right-side panel controls.
 */

const fs = require('fs');
const path = require('path');

const asarDir = process.argv[2];
if (!asarDir || !fs.existsSync(asarDir)) {
  console.error('Usage: node patch-window.js <path-to-extracted-asar-dir>');
  process.exit(1);
}

const mainJs = path.join(asarDir, '.vite', 'build', 'index.js');
if (!fs.existsSync(mainJs)) {
  console.error(`Not found: ${mainJs}`);
  process.exit(1);
}

let code = fs.readFileSync(mainJs, 'utf8');
let patchCount = 0;

function patch(name, fn) {
  const result = fn();
  if (result === false) {
    console.log(`  [SKIP] ${name}`);
  } else {
    patchCount++;
    console.log(`  [OK]   ${name}`);
  }
}

console.log('Patching window decorations for Linux CSD...');

// Disable titleBarOverlay — on Linux this draws invisible Electron window controls
// at a compositor layer above all web content, blocking clicks on plan panel buttons
// and other sidebar header controls at the top-right. Our injected DOM buttons
// (added by the startup patch in prepare.sh) replace this functionality.
patch('titleBarOverlay → false (DOM buttons used instead)', () => {
  const before = code.length;
  code = code.replace(
    /titleBarOverlay:(?:\{[^}]*\}|\w+)/g,
    'titleBarOverlay:false'
  );
  if (code.length === before) return false;
});

// Switch hiddenInset (macOS inset) to hidden (Linux frameless with app-drawn chrome)
patch('titleBarStyle: hiddenInset → hidden', () => {
  if (!code.includes('titleBarStyle:"hiddenInset"')) return false;
  code = code.replace(/titleBarStyle:"hiddenInset"/g, 'titleBarStyle:"hidden"');
});

// Remove trafficLightPosition (macOS-only — causes errors on Linux)
patch('Remove trafficLightPosition', () => {
  if (!code.includes('trafficLightPosition')) return false;
  code = code.replace(/,?trafficLightPosition:\{[^}]*\},?/g, ',');
  code = code.replace(/,,+/g, ',');
});

fs.writeFileSync(mainJs, code);
console.log(`  ${patchCount} window patches applied`);
