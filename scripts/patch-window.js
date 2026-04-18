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
 *
 * Design notes on resilience:
 *
 *   Upstream minifies its main-process bundle, and minifier-assigned
 *   variable names change between releases (e.g. `h` became `u`, `p`
 *   became `E` going 1.2773.0 → 1.3109.0). Patches that hardcoded those
 *   names would silently no-op on every upstream bump and ship visual
 *   regressions (title bar not reserved, window controls overlapping
 *   content, etc).
 *
 *   To stay resilient across minifier renames, critical patches use
 *   STRUCTURAL regexes with backreferences — they capture variable
 *   names at the first occurrence and reference them again later in
 *   the same expression, so the match is keyed on the code SHAPE, not
 *   the specific letters the minifier chose that day.
 *
 *   After all patches run, we re-verify each target state. If a critical
 *   patch didn't leave the bundle in its correct final form, the build
 *   FAILS LOUDLY with exit code 1 so a broken UI never ships silently.
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

/**
 * Apply a regex replacement and report match count.
 * Returns the number of matches (0 if none).
 * If more than maxMatches match, REFUSES to apply (ambiguous pattern).
 */
function replaceCount(source, replacement, { maxMatches = Infinity } = {}) {
  const matches = code.match(source);
  if (!matches || matches.length === 0) return 0;
  if (matches.length > maxMatches) {
    console.error(`         Pattern matched ${matches.length} sites (expected ≤${maxMatches}) — refusing to apply to avoid corrupting unrelated code.`);
    return -1;
  }
  code = code.replace(source, replacement);
  return matches.length;
}

function logApplied(name, count) {
  patchCount++;
  console.log(`  [OK]   ${name} (${count} match${count === 1 ? '' : 'es'})`);
}

function logAlready(name) {
  patchCount++;
  console.log(`  [OK]   ${name} (already applied)`);
}

function logSkip(name) {
  console.log(`  [SKIP] ${name}`);
}

console.log('Patching window decorations for Linux CSD...');

// ---------------------------------------------------------------------------
// 1. titleBarOverlay → transparent CSD with 40px height
// ---------------------------------------------------------------------------
// Matches both inline object values and variable references. The key
// `titleBarOverlay:` is an Electron API option name and is stable across
// upstream versions.
{
  const name = 'titleBarOverlay → transparent CSD';
  const n = replaceCount(
    /titleBarOverlay:(?:\{[^}]*\}|[A-Za-z_$][\w$]*)/g,
    'titleBarOverlay:{color:"#00000000",symbolColor:"#ffffff",height:40}'
  );
  if (n > 0) logApplied(name, n);
  else logSkip(name); // verified below
}

// ---------------------------------------------------------------------------
// 2. titleBarStyle: hiddenInset → hidden
// ---------------------------------------------------------------------------
// Literal string value — stable Electron API enum. Safe to match by string.
{
  const name = 'titleBarStyle: hiddenInset → hidden';
  const n = replaceCount(/titleBarStyle:"hiddenInset"/g, 'titleBarStyle:"hidden"');
  if (n > 0) logApplied(name, n);
  else if (code.includes('titleBarStyle:"hidden"')) logAlready(name);
  else logSkip(name);
}

// ---------------------------------------------------------------------------
// 3. Remove trafficLightPosition (macOS-only — warning on Linux)
// ---------------------------------------------------------------------------
// Handles both `trafficLightPosition:{x:N,y:N}` AND `trafficLightPosition:varRef`.
// Non-critical — leaving it in produces a console warning but doesn't break UI.
{
  const name = 'Remove trafficLightPosition';
  if (code.includes('trafficLightPosition')) {
    const before = code.length;
    code = code.replace(
      /,?trafficLightPosition:(?:\{[^}]*\}|[A-Za-z_$][\w$]*),?/g,
      ','
    );
    code = code.replace(/,,+/g, ',');
    code = code.replace(/([\{,])\s*,/g, '$1');
    const after = code.length;
    if (after !== before) logApplied(name, 1);
    else logSkip(name);
  } else {
    logAlready(name);
  }
}

// ---------------------------------------------------------------------------
// 4. Claude WebContentsView y-offset: 0 → 40 (Linux titlebar inset)
// ---------------------------------------------------------------------------
// The upstream resize handler for the Claude view looks like:
//
//   <var>=0;<view>.setBounds({x:0,y:<var>,width:<bounds>.width,height:<bounds>.height-<var>})
//
// Minifier picks short names for <var>/<view>/<bounds>, and they change
// every release (h→u, p→E, etc). We match by SHAPE using backreferences:
//
//   \1 = offset variable (was `h`, now `u`, …)
//   \2 = view variable   (stable: `o`)
//   \3 = bounds variable (was `p`, now `E`, …)
//
// The backreferences `y:\1`, `\3.width`, `\3.height-\1` enforce internal
// consistency so the regex only matches the real resize handler — not
// any other line that happens to start with a similar prefix.
{
  const name = 'Claude view y-offset: 0 → 40 (Linux titlebar inset)';
  const sourcePattern = /([A-Za-z_$][\w$]*)=0;([A-Za-z_$][\w$]*)\.setBounds\(\{x:0,y:\1,width:([A-Za-z_$][\w$]*)\.width,height:\3\.height-\1\}\)/g;
  const alreadyAppliedPattern = /([A-Za-z_$][\w$]*)=40;([A-Za-z_$][\w$]*)\.setBounds\(\{x:0,y:\1,width:([A-Za-z_$][\w$]*)\.width,height:\3\.height-\1\}\)/;
  const n = replaceCount(sourcePattern, '$1=40;$2.setBounds({x:0,y:$1,width:$3.width,height:$3.height-$1})', { maxMatches: 1 });
  if (n > 0) logApplied(name, n);
  else if (alreadyAppliedPattern.test(code)) logAlready(name);
  else logSkip(name); // verified below
}

fs.writeFileSync(mainJs, code);

// ---------------------------------------------------------------------------
// Post-patch verification: confirm the final bundle is in the expected state.
// ---------------------------------------------------------------------------
// Patches can silently no-op if the source pattern doesn't match (e.g. after
// a minifier-driven rename we didn't account for). This check runs regardless
// of which path each patch took (apply / already-applied / skip) and asserts
// the final state is correct. If any critical target is missing, the build
// fails loudly so we never ship a broken UI.
const criticalChecks = [
  {
    name: 'titleBarOverlay set to transparent 40px',
    assert: () => code.includes('titleBarOverlay:{color:"#00000000",symbolColor:"#ffffff",height:40}'),
  },
  {
    name: 'No macOS "hiddenInset" titleBarStyle remains',
    assert: () => !code.includes('titleBarStyle:"hiddenInset"'),
  },
  {
    name: 'Claude view y-offset is 40 (not 0)',
    assert: () => {
      // There must be exactly one match of the structural pattern with =40,
      // and zero matches with =0.
      const patched = /([A-Za-z_$][\w$]*)=40;([A-Za-z_$][\w$]*)\.setBounds\(\{x:0,y:\1,width:([A-Za-z_$][\w$]*)\.width,height:\3\.height-\1\}\)/;
      const unpatched = /([A-Za-z_$][\w$]*)=0;([A-Za-z_$][\w$]*)\.setBounds\(\{x:0,y:\1,width:([A-Za-z_$][\w$]*)\.width,height:\3\.height-\1\}\)/;
      return patched.test(code) && !unpatched.test(code);
    },
  },
];

console.log('');
console.log('Verifying final state...');
const failures = [];
for (const check of criticalChecks) {
  if (check.assert()) {
    console.log(`  [OK]   ${check.name}`);
  } else {
    console.error(`  [FAIL] ${check.name}`);
    failures.push(check.name);
  }
}

console.log('');
console.log(`  ${patchCount} window patches applied`);

if (failures.length > 0) {
  console.error('');
  console.error(`  CRITICAL VERIFICATION FAILURES: ${failures.length}`);
  for (const name of failures) console.error(`    - ${name}`);
  console.error('');
  console.error('  The upstream Claude Desktop bundle has structure we did not expect.');
  console.error('  Inspect the new asar at .vite/build/index.js and update the matching');
  console.error('  regex in scripts/patch-window.js. Refusing to ship a broken build.');
  process.exit(1);
}
