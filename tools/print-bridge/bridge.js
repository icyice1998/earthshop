#!/usr/bin/env node
/* Earthshop print bridge
   A web page cannot open a network connection to a LAN printer by itself. Run this small program on a PC in the shop:
   the app sends the receipt (already drawn as an image, so Thai prints correctly) to this bridge, and the bridge forwards the bytes
   to the printer's raw port (usually 9100).

   usage:  node bridge.js [--port 9101] [--lan] [--origin https://your-site.example]
     --port    the port this bridge listens on (the same number goes in the app: Settings > Program > Slip printer)
     --lan     listen on the whole network instead of this PC only (not needed when the app runs on this PC)
     --origin  extra web address allowed to use the bridge (the default list already has https://icyice1998.github.io)
     --serve   also serve the app itself from this PC (for phones: open http://<this PC's IP>:PORT/ on the phone; implies --lan).
               The app file is downloaded once into app.html next to this program; add --update to download the newest version.
   No packages to install. Needs Node.js 16 or newer. */
const http = require('http'), https = require('https'), net = require('net'), fs = require('fs'), path = require('path')
const argv = process.argv.slice(2)
const opt = (k, d) => { const i = argv.indexOf(k); return i >= 0 && argv[i + 1] ? argv[i + 1] : d }
const PORT = Number(opt('--port', process.env.PORT || 9101))
const SERVE = argv.includes('--serve'), UPDATE = argv.includes('--update')
const BIND = (argv.includes('--lan') || SERVE) ? '0.0.0.0' : '127.0.0.1'
const APP_URL = 'https://icyice1998.github.io/earthshop/app/', APP_FILE = path.join(__dirname, 'app.html')
const ORIGINS = new Set(['https://icyice1998.github.io', 'null', 'http://localhost', 'http://127.0.0.1', 'https://localhost'])
for (let i = 0; i < argv.length; i++) if (argv[i] === '--origin' && argv[i + 1]) ORIGINS.add(argv[i + 1].replace(/\/+$/, ''))
const PRIVATE = /^(10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+|127\.\d+\.\d+\.\d+|localhost)$/
const MAX_BODY = 4 * 1024 * 1024

function cors(req, res) {
  const o = req.headers.origin
  const okOrigin = !o || ORIGINS.has(o) || /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o) || (SERVE && o === 'http://' + req.headers.host)
  if (o && okOrigin) { res.setHeader('Access-Control-Allow-Origin', o); res.setHeader('Vary', 'Origin') }
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type')
  res.setHeader('Access-Control-Allow-Private-Network', 'true')
  return okOrigin
}
const send = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(obj)) }
const readBody = req => new Promise((ok, bad) => { let n = 0; const b = []; req.on('data', c => { n += c.length; if (n > MAX_BODY) { bad(new Error('ข้อมูลใหญ่เกินไป')); req.destroy() } else b.push(c) }); req.on('end', () => ok(Buffer.concat(b).toString('utf8'))); req.on('error', bad) })
function target(j) {
  const host = String(j.host || '').trim(), port = Number(j.port)
  if (!PRIVATE.test(host)) throw new Error('ที่อยู่เครื่องพิมพ์ต้องเป็นเลข IP ในวงแลนของร้าน (เช่น 192.168.1.146)')
  if (!(port >= 1 && port <= 65535)) throw new Error('พอร์ตไม่ถูกต้อง')
  return { host, port }
}
function toPrinter(host, port, data, timeout = 8000) {
  return new Promise((ok, bad) => {
    const s = net.createConnection({ host, port })
    let done = false
    const fin = (e) => { if (done) return; done = true; clearTimeout(t); s.destroy(); e ? bad(e) : ok() }
    const t = setTimeout(() => fin(new Error('เครื่องพิมพ์ไม่ตอบ (หมดเวลา) ตรวจสอบว่าเปิดเครื่องและ IP/พอร์ตถูกต้อง')), timeout)
    s.on('error', e => fin(new Error('เชื่อมต่อเครื่องพิมพ์ไม่ได้: ' + (e.code || e.message))))
    s.on('connect', () => { if (!data) return fin(); s.write(data, () => s.end()) })
    s.on('close', () => fin())
  })
}

// jobs for the same printer go one at a time (a network printer takes a single connection at once), so a PC and several phones can print together
const lanes = new Map()
function queued(key, job) {
  const prev = lanes.get(key) || Promise.resolve()
  const run = prev.catch(() => {}).then(job).then(async r => { await new Promise(ok => setTimeout(ok, 150)); return r })
  lanes.set(key, run.catch(() => {}))
  return run
}

const server = http.createServer(async (req, res) => {
  const okOrigin = cors(req, res)
  if (req.method === 'OPTIONS') { res.writeHead(okOrigin ? 204 : 403); return res.end() }
  if (!okOrigin) return send(res, 403, { ok: false, error: 'เว็บนี้ไม่ได้รับอนุญาตให้ใช้สะพานพิมพ์ (ใส่ --origin)' })
  try {
    if (req.method === 'GET' && req.url.split('?')[0] === '/status') return send(res, 200, { ok: true, name: 'earthshop-print-bridge', version: 1, port: PORT })
    if (req.method === 'POST' && req.url === '/check') { const { host, port } = target(JSON.parse(await readBody(req) || '{}')); await toPrinter(host, port, null, 4000); return send(res, 200, { ok: true }) }
    if (req.method === 'POST' && req.url === '/print') {
      const j = JSON.parse(await readBody(req) || '{}'); const { host, port } = target(j)
      const data = Buffer.from(String(j.data || ''), 'base64')
      if (!data.length) throw new Error('ไม่มีข้อมูลที่จะพิมพ์')
      await queued(host + ':' + port, () => toPrinter(host, port, data))
      console.log(new Date().toLocaleTimeString(), 'printed', data.length, 'bytes ->', host + ':' + port)
      return send(res, 200, { ok: true, bytes: data.length })
    }
    if (SERVE && req.method === 'GET' && (req.url === '/' || req.url.split('?')[0] === '/index.html')) {
      if (!fs.existsSync(APP_FILE)) { res.writeHead(503, { 'Content-Type': 'text/plain; charset=utf-8' }); return res.end('ยังไม่มีไฟล์แอป ลองรีสตาร์ท bridge.js ด้วย --update') }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' }); return res.end(fs.readFileSync(APP_FILE))
    }
    send(res, 404, { ok: false, error: 'not found' })
  } catch (e) { send(res, 200, { ok: false, error: e.message }) }
})
function download(url, to) {
  return new Promise((ok, bad) => https.get(url, r => {
    if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) return download(new URL(r.headers.location, url).href, to).then(ok, bad)
    if (r.statusCode !== 200) return bad(new Error('HTTP ' + r.statusCode))
    const f = fs.createWriteStream(to + '.tmp'); r.pipe(f); f.on('finish', () => f.close(() => { fs.renameSync(to + '.tmp', to); ok() }))
  }).on('error', bad))
}
async function start() {
  if (SERVE && (UPDATE || !fs.existsSync(APP_FILE))) { try { await download(APP_URL, APP_FILE); console.log('downloaded the app to', APP_FILE) } catch (e) { console.error('ดาวน์โหลดแอปไม่สำเร็จ: ' + e.message + (fs.existsSync(APP_FILE) ? ' (ใช้ไฟล์เดิม)' : '')) } }
  server.listen(PORT, BIND, () => {
    console.log('Earthshop print bridge listening on ' + BIND + ':' + PORT + '  (Ctrl+C to stop)')
    if (SERVE) { const ips = []; for (const l of Object.values(require('os').networkInterfaces())) for (const a of l || []) if (a.family === 'IPv4' && !a.internal) ips.push(a.address); console.log('Open on the phone:  ' + ips.map(i => 'http://' + i + ':' + PORT + '/').join('   ')) }
  })
}
start()
server.on('error', e => { console.error(e.code === 'EADDRINUSE' ? 'พอร์ต ' + PORT + ' ถูกใช้อยู่ ลองเลือกพอร์ตอื่น: node bridge.js --port 9102' : e.message); process.exit(1) })
