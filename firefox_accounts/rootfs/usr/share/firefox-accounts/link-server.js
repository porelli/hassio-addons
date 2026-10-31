// The link of the Firefox Sync add-on (accounts: self_hosted): GET /v1/link with the link
// code's token as a bearer token answers what that add-on needs of these accounts (their
// addresses on the add-on network, the admin UI's database password, Redis's), the file
// fxa-init wrote. Anything else: 401 (after a second) or 404. Port 8101, on the add-on
// network only (not published). LINK_TOKEN, LINK_FILE from fxa-link's run script.
'use strict';
const crypto = require('crypto');
const fs = require('fs');
const http = require('http');

const PORT = 8101;
const digest = (s) => crypto.createHash('sha256').update(String(s)).digest();
const want = digest(process.env.LINK_TOKEN || '');
if (!process.env.LINK_TOKEN || process.env.LINK_TOKEN.length < 32) {
  console.error('link-server: no LINK_TOKEN');
  process.exit(1);
}

http
  .createServer((req, res) => {
    if (req.method !== 'GET' || req.url !== '/v1/link') {
      res.writeHead(404, { 'content-type': 'text/plain' });
      res.end('Not Found\n');
      return;
    }
    const auth = req.headers.authorization || '';
    const given = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (!crypto.timingSafeEqual(digest(given), want)) {
      console.log(`link-server: refused ${req.socket.remoteAddress} (wrong or no link code)`);
      setTimeout(() => {
        res.writeHead(401, { 'content-type': 'text/plain' });
        res.end('Unauthorized\n');
      }, 1000);
      return;
    }
    let body;
    try {
      body = fs.readFileSync(process.env.LINK_FILE);
    } catch (err) {
      res.writeHead(503, { 'content-type': 'text/plain' });
      res.end('Not ready\n');
      return;
    }
    console.log(`link-server: sent the link to ${req.socket.remoteAddress}`);
    res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
    res.end(body);
  })
  .listen(PORT, '0.0.0.0', () => console.log(`link-server: listening on ${PORT}`));
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => process.exit(0));
