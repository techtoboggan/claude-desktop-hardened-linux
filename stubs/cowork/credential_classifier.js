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
  // Generic secrets in env-style assignments
  /(?:SECRET|PASSWORD|PASSWD|TOKEN|CREDENTIAL)\s*[=:]\s*['"]?[^\s'"]{8,}['"]?/gi,
  // JWTs
  /eyJ[A-Za-z0-9\-_]+\.eyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_.+/=]*/g,
  // Private keys
  /-----BEGIN\s+(?:RSA\s+)?PRIVATE\s+KEY-----[\s\S]*?-----END\s+(?:RSA\s+)?PRIVATE\s+KEY-----/g,
];

/**
 * Check if a string contains potential credentials.
 */
function containsCredentials(text) {
  if (!text || typeof text !== 'string') return false;
  return CREDENTIAL_PATTERNS.some(pattern => {
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
  for (const pattern of CREDENTIAL_PATTERNS) {
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
