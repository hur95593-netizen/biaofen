// 极小静态文件服务器(供本地预览;ES 模块需要 HTTP 而非 file://)
import http from 'http';
import { readFile } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join, normalize, extname } from 'path';

const root = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT) || 8123;
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

http.createServer((req, res) => {
  let p = decodeURIComponent((req.url || '/').split('?')[0]);
  if (p === '/') p = '/index.html';
  const file = join(root, normalize(p).replace(/^(\.\.[/\\])+/, ''));
  if (!file.startsWith(root)) { res.writeHead(403); return res.end('forbidden'); }
  readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end('not found'); return; }
    res.writeHead(200, { 'Content-Type': MIME[extname(file)] || 'application/octet-stream' });
    res.end(data);
  });
}).listen(PORT, () => console.log('biaofen preview on http://localhost:' + PORT));
