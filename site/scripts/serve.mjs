// Minimal static server for dist/ that mimics GitHub Pages under the /MacScreen base path.
// Library: `import { serve } from './serve.mjs'`. CLI: `node scripts/serve.mjs [port]`.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../dist/', import.meta.url));
const base = '/MacScreen';
const types = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.woff2': 'font/woff2', '.xml': 'application/xml', '.txt': 'text/plain',
};

export function serve(port = 0) {
  const server = createServer(async (req, res) => {
    let path = decodeURIComponent((req.url ?? '/').split('?')[0]);
    if (!path.startsWith(base)) { res.writeHead(404).end(); return; }
    path = normalize(path.slice(base.length) || '/');
    if (path.includes('..')) { res.writeHead(400).end(); return; }
    if (path.endsWith('/')) path += 'index.html';
    try {
      const body = await readFile(join(root, path));
      res.writeHead(200, { 'content-type': types[extname(path)] ?? 'application/octet-stream' }).end(body);
    } catch {
      const page = await readFile(join(root, '404.html')).catch(() => 'not found');
      res.writeHead(404, { 'content-type': 'text/html; charset=utf-8' }).end(page);
    }
  }).listen(port, '127.0.0.1');
  return server;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = Number(process.argv[2] ?? 4399);
  serve(port).on('listening', () => console.log(`listening on http://127.0.0.1:${port}${base}/`));
}
