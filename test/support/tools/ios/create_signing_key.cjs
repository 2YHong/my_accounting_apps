// Optional, only after enrolling in the Apple Developer Program.
// Save outside the source tree, then add it as a Secret in Codemagic.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const input = process.argv[2];
if (!input || !path.isAbsolute(input)) throw Error('Provide an absolute destination outside the project');
const target = path.resolve(input);
if (target === root || target.toLowerCase().startsWith(root.toLowerCase() + path.sep)) {
  throw Error('Signing private keys must stay outside the source project');
}
const pair = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  privateKeyEncoding: {type: 'pkcs1', format: 'pem'},
  publicKeyEncoding: {type: 'spki', format: 'pem'},
});
fs.mkdirSync(path.dirname(target), {recursive: true});
fs.writeFileSync(target, pair.privateKey, {flag: 'wx', mode: 0o600});
console.log('Distribution key saved. Add the complete file contents as CERTIFICATE_PRIVATE_KEY in Codemagic Secret variables.');
