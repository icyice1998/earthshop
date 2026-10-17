// Slip printer chain: app -> print bridge -> (fake) network printer. Checks the bytes the printer receives.
const { chromium } = require(process.env.PW || '/opt/node-tools/node_modules/playwright')
const net = require('net'), { spawn } = require('child_process'), path = require('path')
const ok = (c, m) => { console.log((c ? 'ok   - ' : 'FAIL - ') + m); if (!c) process.exitCode = 1 }
;(async () => {
  const got = []
  const printer = net.createServer(s => { const b = []; s.on('data', d => b.push(d)); s.on('end', () => { const x = Buffer.concat(b); if (x.length) got.push(x) }) }); await new Promise(r => printer.listen(19100, '127.0.0.1', r))
  const bridge = spawn('node', [path.join(__dirname, '..', '..', 'tools', 'print-bridge', 'bridge.js'), '--port', '19101'], { stdio: 'pipe' })
  await new Promise(r => setTimeout(r, 800))
  const browser = await chromium.launch(); const pg = await browser.newPage({ viewport: { width: 1300, height: 900 } }); const errs = []; pg.on('pageerror', e => errs.push(e.message))
  await pg.goto('file://' + (process.env.PAGE || path.join(__dirname, 'demo_standalone.html'))); await pg.waitForSelector('nav button.tab', { timeout: 60000 }); await pg.waitForTimeout(600)
  await pg.evaluate(() => { const v = window.__vm; v.S.settings.prog = { lanPrint: true, lanHost: '127.0.0.1', lanPort: 19100, lanDots: 576, lanCut: true }; v.setBridge('http://127.0.0.1:19101') })
  await pg.evaluate(() => window.__vm.lanCheck()); await pg.waitForTimeout(800)
  let m = await pg.evaluate(() => window.__vm.lanMsg); ok(m.ok === true, 'check: bridge and printer reachable: ' + m.text)
  await pg.evaluate(() => window.__vm.lanTest()); await pg.waitForTimeout(1500)
  m = await pg.evaluate(() => window.__vm.lanMsg); ok(m.ok === true && got.length === 1, 'test print sent: ' + m.text)
  const b = got[0] || Buffer.alloc(0)
  ok(b[0] === 0x1b && b[1] === 0x40, 'starts with ESC @ (initialise)')
  const ras = b.indexOf(Buffer.from([0x1d, 0x76, 0x30, 0x00]))
  ok(ras > 0 && b[ras + 4] + b[ras + 5] * 256 === 72, 'raster image 72 bytes wide (576 dots)')
  ok(b.indexOf(Buffer.from([0x1d, 0x56, 0x42, 0x00])) > ras, 'ends with a cut command')
  const dark = [...b.subarray(ras + 8, ras + 8 + 72 * 90)].reduce((a, x) => a + x.toString(2).split('1').length - 1, 0)
  ok(dark > 300, 'image has printed content (' + dark + ' dark dots in the first strip)')
  // a real receipt goes to the printer instead of the browser print dialog
  const r = await pg.evaluate(async () => { const v = window.__vm; let printed = false; window.print = () => { printed = true }; const s = v.S.sales.filter(x => x.status === 'ok').pop(); await v.printReceipt(s); return { printed, doc: !!v.printDoc } })
  await new Promise(r => setTimeout(r, 800))
  ok(got.length === 2 && !r.printed, 'receipt printed through the bridge, not the browser dialog')
  // wrong printer: clear message
  await pg.evaluate(() => { window.__vm.S.settings.prog = { ...window.__vm.S.settings.prog, lanPort: 19999 } }); await pg.evaluate(() => window.__vm.lanCheck()); await pg.waitForTimeout(1500)
  m = await pg.evaluate(() => window.__vm.lanMsg); ok(m.ok === false && /เครื่องพิมพ์/.test(m.text), 'unreachable printer reported: ' + m.text)
  // bridge refuses a public address
  const bad = await pg.evaluate(async () => { try { await Slip.call('/print', { host: '8.8.8.8', port: 9100, data: 'AA==' }); return 'accepted' } catch (e) { return e.message } })
  ok(/วงแลน/.test(bad), 'bridge refuses addresses outside the shop network')
  // phone modes -------------------------------------------------------
  // (1) Android + RawBT app: the app hands the ESC/POS bytes to the rawbt: link
  const rb = await pg.evaluate(async () => { const v = window.__vm; let url = ''; Slip.openUrl = u => { url = u }; v.S.settings.prog = { ...v.S.settings.prog, lanMode: 'rawbt' }; await v.lanTest(); return { url, msg: v.lanMsg } })
  const raw = Buffer.from((rb.url.split(',')[1] || ''), 'base64')
  ok(rb.url.startsWith('rawbt:base64,') && raw[0] === 0x1b && raw[1] === 0x40 && raw.indexOf(Buffer.from([0x1d, 0x76, 0x30, 0x00])) > 0, 'RawBT mode: opens a rawbt:base64 link with the ESC/POS bytes (' + raw.length + ' bytes)')
  // (2) phone opens the app from the bridge itself (bridge --serve): same address is used for printing
  const ip = process.env.LANIP
  if (ip) {
    const fs = require('fs'); fs.copyFileSync(process.env.PAGE, path.join(__dirname, '..', '..', 'tools', 'print-bridge', 'app.html'))
    const b2 = spawn('node', [path.join(__dirname, '..', '..', 'tools', 'print-bridge', 'bridge.js'), '--port', '19102', '--serve'], { stdio: 'pipe' })
    await new Promise(r => setTimeout(r, 800))
    const ph = await browser.newPage({ viewport: { width: 390, height: 800 } }); const perr = []; ph.on('pageerror', e => perr.push(e.message))
    await ph.goto('http://' + ip + ':19102/'); await ph.waitForSelector('nav button.tab', { timeout: 60000 }); await ph.waitForTimeout(600)
    const before = got.length
    const r2 = await ph.evaluate(async () => { const v = window.__vm; v.S.settings.prog = { lanPrint: true, lanHost: '127.0.0.1', lanPort: 19100, lanDots: 384 }; const url = Slip.bridgeUrl(); await v.lanTest(); return { url, ok: v.lanMsg.ok, text: v.lanMsg.text } })
    await new Promise(r => setTimeout(r, 800))
    ok(r2.url === 'http://' + ip + ':19102' && r2.ok === true && got.length === before + 1, 'phone opened from the bridge (' + r2.url + ') prints through it: ' + r2.text)
    const last = got[got.length - 1]; const at = last.indexOf(Buffer.from([0x1d, 0x76, 0x30, 0x00])); ok(last[at + 4] === 48, 'phone slip is 58 mm wide (48 bytes)')
    ok(perr.length === 0, 'no errors on the phone page')
    b2.kill(); fs.unlinkSync(path.join(__dirname, '..', '..', 'tools', 'print-bridge', 'app.html'))
  } else console.log('skip - no LAN address on this machine for the phone test')
  ok(errs.length === 0, 'no page errors ' + JSON.stringify(errs.slice(0, 2)))
  await browser.close(); bridge.kill(); printer.close()
})().catch(e => { console.error('CRASH', e); process.exit(1) })
