// Several devices print at the same moment: a printer that accepts one connection at a time must still get every job complete.
const net = require('net'), http = require('http'), { spawn } = require('child_process'), path = require('path')
const ok = (c, m) => { console.log((c ? 'ok   - ' : 'FAIL - ') + m); if (!c) process.exitCode = 1 }
;(async () => {
  const got = []; let busy = false, refused = 0
  const printer = net.createServer(s => {
    if (busy) { refused++; s.destroy(); return }
    busy = true; const b = []; s.on('data', d => b.push(d)); s.on('end', () => { got.push(Buffer.concat(b)); setTimeout(() => { busy = false }, 80) })
  }); await new Promise(r => printer.listen(19200, '127.0.0.1', r))
  const bridge = spawn('node', [path.join(__dirname, '..', '..', 'tools', 'print-bridge', 'bridge.js'), '--port', '19201'], { stdio: 'pipe' }); await new Promise(r => setTimeout(r, 700))
  const post = (n) => new Promise(res => { const body = JSON.stringify({ host: '127.0.0.1', port: 19200, data: Buffer.alloc(3000, n).toString('base64') }); const rq = http.request({ host: '127.0.0.1', port: 19201, path: '/print', method: 'POST', headers: { 'Content-Type': 'application/json' } }, r => { let t = ''; r.on('data', d => t += d); r.on('end', () => res(JSON.parse(t))) }); rq.end(body) })
  const results = await Promise.all([1, 2, 3, 4, 5, 6].map(post))
  ok(results.every(r => r.ok), 'six simultaneous print requests all accepted: ' + JSON.stringify(results.map(r => r.ok)))
  ok(got.length === 6 && refused === 0, 'printer received 6 complete jobs, none refused while busy (' + got.length + ' jobs, ' + refused + ' refused)')
  ok(got.every(b => b.length === 3000 && b.every(x => x === b[0])), 'no job was mixed with another')
  bridge.kill(); printer.close()
})()
