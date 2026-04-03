/**
 * Credential detection and redaction for Cowork session logs.
 *
 * Uses multi-pass regex to strip tokens, API keys, and other secrets
 * from log output before it reaches disk or the renderer process.
 */

'use strict';

// Patterns that match common credential formats
const CREDENTIAL_PATTERNS = [
  // Bearer tokens
  /Bearer\s+[A-Za-z0-9\-._~+/]+=*/gi,
  // API keys (various formats)
  /(?:api[_-]?key|apikey|api[_-]?token)\s*[=:]\s*['"]?[A-Za-z0-9\-._~+/]{16,}['"]?/gi,
  // OAuth tokens
  /(?:oauth[_-]?token|access[_-]?token|refresh[_-]?token)\s*[=:]\s*['"]?[A-Za-z0-9\-._~+/]{16,}['"]?/gi,
  // AWS keys
  /(?:AKIA|ASIA)[A-Z0-9]{16}/g,
  // GitHub tokens
  /gh[pousr]_[A-Za-z0-9_]{36,}/g,
  // Anthropic API keys
  /sk-ant-[A-Za-z0-9\-]{20,}/g,
  // OpenAI API keys
  /sk-[A-Za-z0-9]{20,}/g,
  // Slack tokens
  /xox[bpras]-[A-Za-z0-9\-]{10,}/g,
  // Stripe keys
  /[sr]k_live_[A-Za-z0-9]{20,}/g,
  // npm tokens
  /npm_[A-Za-z0-9]{20,}/g,
  // PyPI tokens
  /pypi-[A-Za-z0-9\-]{20,}/g,
  // Google Cloud service account key IDs
  /(?:private_key_id|client_id)\s*[":]\s*["\']?[A-Za-z0-9\-_]{20,}/gi,
  // Database connection strings with passwords
  /(?:mongodb|postgres|mysql|redis):\/\/[^:]+:[^@]+@/gi,
  // Generic secrets in env-style assignments
  /(?:SECRET|PASSWORD|PASSWD|TOKEN|CREDENTIAL)\s*[=:]\s*['"]?[^\s'"]{8,}['"]?/gi,
  // JWTs
  /eyJ[A-Za-z0-9\-_]+\.eyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_.+/=]*/g,
  // Private keys
  /-----BEGIN\s+(?:RSA\s+)?PRIVATE\s+KEY-----[\s\S]*?-----END\s+(?:RSA\s+)?PRIVATE\s+KEY-----/g,
];

/**
 * Load additional credential patterns from user config.
 * File: ~/.config/Claude/credential-patterns.json
 * Format: { "patterns": ["regex1", "regex2"] }
 */
const MAX_PATTERN_LENGTH = 500;
const MAX_USER_PATTERNS = 50;

function loadUserPatterns() {
  const path = require('path');
  const fs = require('fs');
  const os = require('os');
  const configPath = path.join(
    process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'),
    'Claude', 'credential-patterns.json'
  );
  try {
    const raw = fs.readFileSync(configPath, 'utf8');
    const config = JSON.parse(raw);
    if (Array.isArray(config.patterns)) {
      return config.patterns
        .slice(0, MAX_USER_PATTERNS)
        .filter(p => typeof p === 'string' && p.length <= MAX_PATTERN_LENGTH)
        .map(p => { try { return new RegExp(p, 'g'); } catch (_) { return null; } })
        .filter(Boolean);
    }
  } catch (_) {
    // No user config or invalid — use built-in patterns only
  }
  return [];
}

const USER_PATTERNS = loadUserPatterns();
const ALL_PATTERNS = [...CREDENTIAL_PATTERNS, ...USER_PATTERNS];

/**
 * Check if a string contains potential credentials.
 */
function containsCredentials(text) {
  if (!text || typeof text !== 'string') return false;
  return ALL_PATTERNS.some(pattern => {
    pattern.lastIndex = 0;  // Reset regex state
    return pattern.test(text);
  });
}

/**
 * Redact credentials from a string for safe logging.
 */
function redactForLogs(text) {
  if (!text || typeof text !== 'string') return text;

  let redacted = text;
  for (const pattern of ALL_PATTERNS) {
    pattern.lastIndex = 0;
    redacted = redacted.replace(pattern, '[REDACTED]');
  }
  return redacted;
}

/**
 * Filter environment variables, removing any that look like credentials.
 */
function filterCredentialEnvVars(env) {
  const filtered = {};
  const sensitiveKeys = /(?:token|secret|password|passwd|credential|api[_-]?key|auth)/i;

  for (const [key, value] of Object.entries(env)) {
    if (sensitiveKeys.test(key) && key !== 'CLAUDE_CODE_OAUTH_TOKEN') {
      // Block sensitive env vars (except the one we need)
      continue;
    }
    filtered[key] = value;
  }
  return filtered;
}

module.exports = {
  containsCredentials,
  redactForLogs,
  filterCredentialEnvVars,
  CREDENTIAL_PATTERNS,
};
