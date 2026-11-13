import assert from 'node:assert/strict';
import test from 'node:test';
import { spawnSync } from 'node:child_process';
import {
  deriveSparklePublicKey,
  verifySparkleKeyPair,
} from './sparkle-key.mjs';

const seed = Buffer.from('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60', 'hex');
const publicKey = Buffer.from('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a', 'hex');

test('derives the Ed25519 public key from Sparkle new-format seed', () => {
  assert.deepEqual(deriveSparklePublicKey(seed.toString('base64')), publicKey);
  assert.doesNotThrow(() => verifySparkleKeyPair(
    seed.toString('base64'),
    publicKey.toString('base64'),
  ));
});

test('rejects Sparkle legacy-format secrets that cannot be independently derived', () => {
  const legacySecret = Buffer.concat([Buffer.alloc(64, 7), publicKey]);
  assert.throws(() => deriveSparklePublicKey(legacySecret.toString('base64')));
});

test('rejects malformed and mismatched keys', () => {
  assert.throws(() => deriveSparklePublicKey('not-base64'));
  assert.throws(() => deriveSparklePublicKey(Buffer.alloc(31).toString('base64')));
  assert.throws(() => verifySparkleKeyPair(
    seed.toString('base64'),
    Buffer.alloc(32).toString('base64'),
  ));
});

test('CLI verifies piped private keys and rejects mismatched public keys', () => {
  for (const [expectedPublicKey, expectedStatus] of [
    [publicKey, 0],
    [Buffer.alloc(32), 1],
  ]) {
    const result = spawnSync(process.execPath, [
      new URL('./sparkle-key.mjs', import.meta.url).pathname,
      'verify',
    ], {
      input: seed.toString('base64'),
      encoding: 'utf8',
      env: { ...process.env, SPARKLE_PUBLIC_KEY: expectedPublicKey.toString('base64') },
    });
    assert.equal(result.status, expectedStatus, result.stderr);
    assert.match(result.stdout + result.stderr, expectedStatus === 0
      ? /Sparkle signing key pair verified/
      : /do not belong to the same key pair/);
    assert.ok(!(result.stdout + result.stderr).includes(seed.toString('base64')));
  }
});
