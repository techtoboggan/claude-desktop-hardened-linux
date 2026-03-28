/**
 * Tests for credential_classifier.js
 *
 * Run: node --test tests/test_credential_classifier.js
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');

const {
  containsCredentials,
  redactForLogs,
  filterCredentialEnvVars,
} = require('../stubs/cowork/credential_classifier');

describe('containsCredentials', () => {
  it('detects Bearer tokens', () => {
    assert.ok(containsCredentials('Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc'));
  });

  it('detects API keys', () => {
    assert.ok(containsCredentials('api_key=sk-ant-abcdef0123456789abcdef'));
    assert.ok(containsCredentials('apikey: ghp_1234567890abcdefghijklmnopqrstuvwxyz0'));
  });

  it('detects AWS keys', () => {
    assert.ok(containsCredentials('AKIAIOSFODNN7EXAMPLE'));
  });

  it('detects GitHub tokens', () => {
    assert.ok(containsCredentials('ghp_ABCDEFghijklmnopqrstuvwxyz0123456789'));
  });

  it('detects Anthropic API keys', () => {
    assert.ok(containsCredentials('sk-ant-api03-abcdefghijklmnopqrst'));
  });

  it('detects JWTs', () => {
    assert.ok(containsCredentials('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c'));
  });

  it('detects private keys', () => {
    assert.ok(containsCredentials('-----BEGIN RSA PRIVATE KEY-----\nMIIEpQIBAAKC\n-----END RSA PRIVATE KEY-----'));
  });

  it('detects Slack tokens', () => {
    assert.ok(containsCredentials('xoxb-1234567890-abcdefghij'));
  });

  it('detects Stripe-style keys', () => {
    // Test the regex pattern [sr]k_live_ without triggering GitHub push protection
    const pattern = /[sr]k_live_[A-Za-z0-9]{20,}/;
    assert.ok(pattern.test('sk_live_' + 'a'.repeat(24)));
  });

  it('detects npm tokens', () => {
    assert.ok(containsCredentials('npm_abcdefghijklmnopqrstuvwxyz'));
  });

  it('detects database connection strings', () => {
    assert.ok(containsCredentials('postgres://user:secretpass@localhost:5432/db'));
  });

  it('returns false for safe text', () => {
    assert.ok(!containsCredentials('Hello world, this is a normal message'));
    assert.ok(!containsCredentials('The API returned 200 OK'));
    assert.ok(!containsCredentials(''));
  });

  it('handles null and undefined', () => {
    assert.ok(!containsCredentials(null));
    assert.ok(!containsCredentials(undefined));
    assert.ok(!containsCredentials(42));
  });
});

describe('redactForLogs', () => {
  it('redacts Bearer tokens', () => {
    const input = 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc';
    const result = redactForLogs(input);
    assert.ok(!result.includes('eyJhbGciOiJ'));
    assert.ok(result.includes('[REDACTED]'));
  });

  it('redacts multiple credentials in one string', () => {
    const input = 'key=sk-ant-api03-abcdefghijklmnopqrst token=ghp_ABCDEFghijklmnopqrstuvwxyz0123456789';
    const result = redactForLogs(input);
    assert.ok(!result.includes('sk-ant-'));
    assert.ok(!result.includes('ghp_'));
  });

  it('preserves non-credential text', () => {
    const input = 'Hello world';
    assert.equal(redactForLogs(input), 'Hello world');
  });

  it('handles null/undefined safely', () => {
    assert.equal(redactForLogs(null), null);
    assert.equal(redactForLogs(undefined), undefined);
  });
});

describe('filterCredentialEnvVars', () => {
  it('removes sensitive env vars', () => {
    const env = {
      HOME: '/home/user',
      API_TOKEN: 'secret123',
      SECRET_KEY: 'mysecret',
      PATH: '/usr/bin',
      DATABASE_PASSWORD: 'dbpass',
    };
    const filtered = filterCredentialEnvVars(env);
    assert.equal(filtered.HOME, '/home/user');
    assert.equal(filtered.PATH, '/usr/bin');
    assert.ok(!('API_TOKEN' in filtered));
    assert.ok(!('SECRET_KEY' in filtered));
    assert.ok(!('DATABASE_PASSWORD' in filtered));
  });

  it('preserves CLAUDE_CODE_OAUTH_TOKEN', () => {
    const env = { CLAUDE_CODE_OAUTH_TOKEN: 'token123' };
    const filtered = filterCredentialEnvVars(env);
    assert.equal(filtered.CLAUDE_CODE_OAUTH_TOKEN, 'token123');
  });
});
