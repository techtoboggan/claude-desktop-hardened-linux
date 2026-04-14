#!/usr/bin/env node
/**
 * patch-window.js — Patch Claude Desktop window decorations for Linux CSD
 *
 * Usage: node patch-window.js <path-to-extracted-asar-dir>
 *
 * Replaces macOS-specific title bar settings with Electron 28+ Linux CSD:
 *   titleBarStyle:"hidden" + titleBarOverlay:{color:"#00000000",...}
 *
 * This lets Electron draw native close/min/max buttons inside the app's
 * own content area (just like Firefox on Linux), giving a clean merged look.
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

// Replace any existing titleBarOverlay value (inline object or variable reference)
// with the transparent overlay that lets app content show behind native buttons.
patch('titleBarOverlay → transparent CSD', () => {
  const before = code.length;
  code = code.replace(
    /titleBarOverlay:(?:\{[^}]*\}|\w+)/g,
    'titleBarOverlay:{color:"#00000000",symbolColor:"#ffffff",height:10}'
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
