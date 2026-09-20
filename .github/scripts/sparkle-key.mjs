import {
  createPrivateKey,
  createPublicKey,
  timingSafeEqual,
} from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const ED25519_PKCS8_SEED_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

function decodeBase64(value, label) {
  const normalized = value.trim();
  const decoded = Buffer.from(normalized, 'base64');
  if (decoded.toString('base64') !== normalized) {
    throw new Error(`${label} must be canonical base64.`);
  }
  return decoded;
}

export function deriveSparklePublicKey(privateKeyValue) {
  const secret = decodeBase64(privateKeyValue, 'Sparkle private key');
  if (secret.length !== 32) {
    throw new Error('Cellar releases require Sparkle private keys exported as a 32-byte seed.');
  }

  const privateKey = createPrivateKey({
    key: Buffer.concat([ED25519_PKCS8_SEED_PREFIX, secret]),
    format: 'der',
    type: 'pkcs8',
  });
  const subjectPublicKeyInfo = createPublicKey(privateKey).export({
    format: 'der',
    type: 'spki',
  });
  if (subjectPublicKeyInfo.length !== ED25519_SPKI_PREFIX.length + 32
      || !subjectPublicKeyInfo.subarray(0, ED25519_SPKI_PREFIX.length).equals(ED25519_SPKI_PREFIX)) {
    throw new Error('Unable to derive an Ed25519 public key from the Sparkle private key.');
  }
  return subjectPublicKeyInfo.subarray(ED25519_SPKI_PREFIX.length);
}

export function verifySparkleKeyPair(privateKeyValue, publicKeyValue) {
  const expectedPublicKey = decodeBase64(publicKeyValue, 'Sparkle public key');
  if (expectedPublicKey.length !== 32) {
    throw new Error('Sparkle public key must decode to 32 bytes.');
  }
  const derivedPublicKey = deriveSparklePublicKey(privateKeyValue);
  if (!timingSafeEqual(derivedPublicKey, expectedPublicKey)) {
    throw new Error('Sparkle public and private keys do not belong to the same key pair.');
  }
}

async function main() {
  if (process.argv[2] !== 'verify') {
    throw new Error(`Unknown command: ${process.argv[2] ?? ''}.`);
  }
  const privateKeyValue = await readFile(0, 'utf8');
  verifySparkleKeyPair(privateKeyValue, process.env.SPARKLE_PUBLIC_KEY ?? '');
  process.stdout.write('Sparkle signing key pair verified.\n');
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  main().catch((error) => {
    console.error(`::error::Sparkle key verification failed: ${error.message}`);
    process.exitCode = 1;
  });
}
