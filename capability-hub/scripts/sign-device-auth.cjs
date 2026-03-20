#!/usr/bin/env node
// sign-device-auth.js
// Builds and signs the OpenClaw gateway device-auth payload for challenge-response.
// Usage: node sign-device-auth.js --nonce <nonce> [--clientId <id>] [--clientMode <mode>]
//        [--role <role>] [--scopes <comma-separated>] [--token <gatewayToken>]
//        [--identityPath <path-to-device.json>]
// Outputs JSON: { deviceId, publicKey, signature, signedAt, nonce }

"use strict";
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

function base64UrlEncode(buf) {
  return buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function derivePublicKeyRaw(publicKeyPem) {
  const spki = crypto.createPublicKey(publicKeyPem).export({ type: "spki", format: "der" });
  if (
    spki.length === ED25519_SPKI_PREFIX.length + 32 &&
    spki.subarray(0, ED25519_SPKI_PREFIX.length).equals(ED25519_SPKI_PREFIX)
  ) {
    return spki.subarray(ED25519_SPKI_PREFIX.length);
  }
  return spki;
}

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    if (argv[i].startsWith("--") && i + 1 < argv.length) {
      args[argv[i].slice(2)] = argv[++i];
    }
  }
  return args;
}

const args = parseArgs(process.argv);

const nonce = args.nonce;
if (!nonce) {
  process.stderr.write("Error: --nonce is required\n");
  process.exit(1);
}

// Determine identity file path
let identityPath = args.identityPath;
if (!identityPath) {
  // Try Windows path via environment
  const userProfile = process.env.USERPROFILE || process.env.HOME || "";
  identityPath = path.join(userProfile, ".openclaw", "identity", "device.json");
}

if (!fs.existsSync(identityPath)) {
  process.stderr.write("Error: device.json not found at: " + identityPath + "\n");
  process.exit(1);
}

let deviceInfo;
try {
  deviceInfo = JSON.parse(fs.readFileSync(identityPath, "utf8"));
} catch (e) {
  process.stderr.write("Error reading device.json: " + e.message + "\n");
  process.exit(1);
}

const deviceId = deviceInfo.deviceId;
const privateKeyPem = deviceInfo.privateKeyPem;
const publicKeyPem = deviceInfo.publicKeyPem;

if (!deviceId || !privateKeyPem || !publicKeyPem) {
  process.stderr.write("Error: device.json missing deviceId, privateKeyPem, or publicKeyPem\n");
  process.exit(1);
}

const clientId = args.clientId || "m3-router";
const clientMode = args.clientMode || "backend";
const role = args.role || "operator";
const scopes = args.scopes || "operator.admin";
const token = args.token || "";
const signedAtMs = Date.now();

// Build payload string: "v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce"
const payload = ["v2", deviceId, clientId, clientMode, role, scopes, String(signedAtMs), token, nonce].join("|");

// Sign with Ed25519
const privateKey = crypto.createPrivateKey(privateKeyPem);
const sigBuf = crypto.sign(null, Buffer.from(payload, "utf8"), privateKey);
const signature = base64UrlEncode(sigBuf);

// Derive public key raw base64url
const publicKeyRaw = base64UrlEncode(derivePublicKeyRaw(publicKeyPem));

const result = {
  deviceId,
  publicKey: publicKeyRaw,
  signature,
  signedAt: signedAtMs,
  nonce,
};

process.stdout.write(JSON.stringify(result) + "\n");
