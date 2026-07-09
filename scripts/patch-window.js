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

// Since upstream 1.13576.0, `.vite/build/index.js` is a thin (~800 byte) Vite
// loader that just `require("./index.chunk-<hash>.js")`s the real code. The
// window-decoration code we patch moved into that sibling chunk, whose hash
// changes every release. Resolve the loader to its largest required sibling
// (the main chunk dwarfs everything else); fall back to the entry itself for
// old monolithic bundles. Mirrors patches/base.py:_resolve_loader_chunk.
const THIN_LOADER_MAX_BYTES = 100000;
function resolveMainJs(entry) {
  if (!fs.existsSync(entry)) return entry;
  if (fs.statSync(entry).size > THIN_LOADER_MAX_BYTES) return entry;
  const loader = fs.readFileSync(entry, 'utf8');
  const dir = path.dirname(entry);
  const siblings = [];
  const re = /require\((?:"|')(\.\/[^"']+\.js)(?:"|')\)/g;
  let m;
  while ((m = re.exec(loader)) !== null) {
    const cand = path.normalize(path.join(dir, m[1]));
    if (fs.existsSync(cand) && fs.statSync(cand).isFile()) siblings.push(cand);
  }
  if (siblings.length === 0) return entry;
  return siblings.reduce((a, b) => (fs.statSync(b).size > fs.statSync(a).size ? b : a));
}

const mainJs = resolveMainJs(path.join(asarDir, '.vite', 'build', 'index.js'));
if (!fs.existsSync(mainJs)) {
  console.error(`Not found: ${mainJs}`);
  process.exit(1);
}
console.log(`  Target: ${path.relative(asarDir, mainJs)}`);

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
// Matches inline Electron-API objects (must contain `color`, `symbolColor`,
// or `height` as the first key) OR a bare identifier reference. The
// `(?=[,}])` lookahead requires the value to end cleanly at a comma or
// closing brace.
//
// Both refinements are critical defenses against false positives in
// upstream 1.8555.0+, which now uses `titleBarOverlay` for THREE
// distinct purposes in the same file:
//
//   (a) BrowserWindow constructor option (what we WANT to patch):
//       `titleBarOverlay: mo,` or `titleBarOverlay: {color:...}`
//
//   (b) Field-schema metadata for the desktop preference editor:
//       `titleBarOverlay: {allowed:!0, creationOnly:!1}` — DON'T touch
//
//   (c) Ternary referencing the same property name:
//       `titleBarOverlay: LFA() ? e.titleBarOverlay : void 0` — DON'T touch
//
// Earlier regex `\{[^}]*\}|[A-Za-z_$][\w$]*` matched ALL three forms
// because it didn't distinguish the API-config object from the schema
// metadata object, and matched bare `LFA` even when followed by `(`.
// The result was object-literal-followed-by-call syntax `{...}()?`,
// which crashed the parser two lines later at an unrelated template
// literal (`${s} KB`) because the parser's state was wrong by then.
//
// The two safeguards together restrict matches to legitimate
// constructor-option positions only.
{
  const name = 'titleBarOverlay → transparent CSD';
  const n = replaceCount(
    /titleBarOverlay:(?:\{(?:color|symbolColor|height)[^}]*\}|[A-Za-z_$][\w$]*)(?=[,}])/g,
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
// Matches the real API value (a {x,y} object) or a bare variable reference
// at object-property positions only. Same false-positive concerns as the
// titleBarOverlay patch above:
//
//   - `trafficLightPosition:{allowed:!0,...}` is preference SCHEMA metadata,
//      not the Electron API — must not delete it.
//   - `trafficLightPosition:LFA() ? ... : ...` is a ternary reading the
//      property, not setting it — must not touch.
//
// The lookahead `(?=[,}])` and the restricted object-key set (`x` or `y`)
// keep us focused on legitimate BrowserWindow constructor options.
// Non-critical — leaving it in produces a console warning but doesn't break UI.
{
  const name = 'Remove trafficLightPosition';
  if (code.includes('trafficLightPosition')) {
    const before = code.length;
    code = code.replace(
      /,?trafficLightPosition:(?:\{[xy]:[^}]*\}|[A-Za-z_$][\w$]*)(?=[,}])/g,
      ''
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
// The upstream resize handler for the Claude view has taken two shapes:
//
//   old (≤1.12603.1, monolithic):
//     <var>=0;<view>.setBounds({x:0,y:<var>,width:<b>.width,height:<b>.height-<var>})
//   new (≥1.13576.0, chunked):
//     …,<var>=0,<s>=<view>.getBounds();return <view>.setBounds({x:0,y:<var>,…})
//
// i.e. the `<var>=0` offset used to be glued to the setBounds with a `;`, but
// now sits in a comma-declaration ahead of a `return <view>.setBounds(…)`. We
// match BOTH by allowing the separator to be `;` or `,` and letting an
// optional `[^{}]` middle span whatever sits between the assignment and the
// setBounds call (getBounds()/return in the new form, nothing in the old).
//
// Minifier names change every release, so we key on SHAPE via backreferences:
//   \1 = offset variable (the `=0` we bump to `=40`)
//   \3 = bounds variable (its .width / .height feed the setBounds)
// Group 2 captures the whole tail so the replacement just flips `=0`→`=40`
// and re-emits \2 verbatim. The backrefs `y:\1`, `\3.width`, `\3.height-\1`
// enforce internal consistency so we only match the real resize handler.
{
  const name = 'Claude view y-offset: 0 → 40 (Linux titlebar inset)';
  const offsetTail = /([A-Za-z_$][\w$]*)=0([;,][^{}]{0,120}?[A-Za-z_$][\w$]*\.setBounds\(\{x:0,y:\1,width:([A-Za-z_$][\w$]*)\.width,height:\3\.height-\1\}\))/g;
  const alreadyAppliedPattern = /([A-Za-z_$][\w$]*)=40([;,][^{}]{0,120}?[A-Za-z_$][\w$]*\.setBounds\(\{x:0,y:\1,width:([A-Za-z_$][\w$]*)\.width,height:\3\.height-\1\}\))/;
  const n = replaceCount(offsetTail, '$1=40$2', { maxMatches: 1 });
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
      // There must be at least one match of the structural pattern with =40,
      // and zero matches with =0.
      const patched = /([A-Za-z_$][\w$]*)=40([;,][^{}]{0,120}?[A-Za-z_$][\w$]*\.setBounds\(\{x:0,y:\1,width:([A-Za-z_$][\w$]*)\.width,height:\3\.height-\1\}\))/;
      const unpatched = /([A-Za-z_$][\w$]*)=0([;,][^{}]{0,120}?[A-Za-z_$][\w$]*\.setBounds\(\{x:0,y:\1,width:([A-Za-z_$][\w$]*)\.width,height:\3\.height-\1\}\))/;
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
