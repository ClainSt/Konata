// Local synthetic fixture transfer only; no directory browsing or upload.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(process.argv[2] || '.dart_tool/playback-fixtures-v2');
const port = Number(process.argv[3] || 18763);
http.createServer((req, res) => {
  let name;
  try { name = decodeURIComponent(new URL(req.url, 'http://localhost').pathname.slice(1)); }
  catch { res.writeHead(400).end(); return; }
  if (req.method !== 'GET' || !/^[a-zA-Z0-9_-]+\.(mkv|mp4|ass)$/.test(name)) {
    res.writeHead(400).end(); return;
  }
  const file = path.join(root, name);
  if (!fs.existsSync(file)) { res.writeHead(404).end(); return; }
  res.setHeader('Content-Length', fs.statSync(file).size);
  const input = fs.createReadStream(file);
  res.on('close', () => input.destroy());
  input.on('error', () => res.destroy());
  input.pipe(res);
}).listen(port, '127.0.0.1', () => console.log('Fixture server: loopback port ' + port));
