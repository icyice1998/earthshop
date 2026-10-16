// Builds dev/mock/mock_state.json using the app's own Logic (so lots, movements, bills stay consistent).
// usage: node dev/mock/generate_mock.js        (needs playwright + chromium; paths via env PW / CHROME)
const fs = require('fs'), path = require('path')
const { chromium } = require(process.env.PW || '/opt/node-tools/node_modules/playwright')
const root = path.resolve(__dirname, '../..')
const stub = `window.supabase={createClient:()=>({auth:{getSession:async()=>({data:{}}),onAuthStateChange(){},signInWithPassword:async()=>({}),signOut:async()=>({}),updateUser:async()=>({})},from:()=>({select:()=>({eq:()=>({maybeSingle:async()=>({data:null,error:null})})})}),rpc:async()=>({data:1,error:null})})}`

function build(DAYS) {
  let seed = 20260101
  const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296 }
  const ri = (a, b) => a + Math.floor(rnd() * (b - a + 1))
  const pick = a => a[Math.floor(rnd() * a.length)]
  ACTOR = 'mock'
  const S = makeSeed()
  S.settings.shopName = 'ร้านยาตัวอย่าง (MOCK)'
  S.settings.shopAddress = '99 ถนนตัวอย่าง แขวงตัวอย่าง เขตตัวอย่าง กรุงเทพฯ 10000'
  S.settings.pharmacistName = 'ภก.ตัวอย่าง ใจดี'
  S.settings.licenseNo = 'ภ.0000 (ตัวอย่าง)'
  const STAFF = ['ผู้ดูแล (ตัวอย่าง)', 'พนักงานขายตัวอย่าง', 'เภสัชกรตัวอย่าง']
  const BUYERS = ['สมชาย ใจดี', 'สมหญิง รักสุข', 'วิชัย มั่นคง', 'มาลี สุขใจ', 'ประเสริฐ ดีเลิศ', 'นภา แสงทอง']
  const MAKERS = ['บริษัท ไทยเภสัช จำกัด', 'บริษัท เมดิฟาร์มา (ประเทศไทย) จำกัด', 'Siam Pharma Co., Ltd.', 'องค์การเภสัชกรรม']
  const GEN = [ // generic, category, unit, cost range, margin, pack strengths
    ['Paracetamol', 'แก้ปวด', 'แผง', [4, 9], ['500 mg', '650 mg']], ['Ibuprofen', 'แก้ปวด', 'แผง', [8, 14], ['200 mg', '400 mg']],
    ['Naproxen', 'แก้ปวด', 'แผง', [15, 30], ['250 mg', '500 mg']], ['Diclofenac gel', 'แก้ปวด', 'หลอด', [30, 70], ['1%']],
    ['Cetirizine', 'หวัด/แพ้/ไอ', 'แผง', [6, 15], ['10 mg']], ['Chlorpheniramine', 'หวัด/แพ้/ไอ', 'แผง', [2, 5], ['4 mg']],
    ['Bromhexine', 'หวัด/แพ้/ไอ', 'แผง', [8, 16], ['8 mg']], ['Ambroxol', 'หวัด/แพ้/ไอ', 'ขวด', [30, 55], ['15 mg/5 ml']],
    ['Amoxicillin', 'ฆ่าเชื้อ', 'แผง', [15, 30], ['250 mg', '500 mg']], ['Cefalexin', 'ฆ่าเชื้อ', 'แผง', [20, 40], ['500 mg']],
    ['Roxithromycin', 'ฆ่าเชื้อ', 'แผง', [40, 80], ['150 mg']], ['Norfloxacin', 'ฆ่าเชื้อ', 'แผง', [20, 35], ['400 mg']],
    ['Chloramphenicol eye', 'ยาตา', 'หลอด', [20, 40], ['0.5%']], ['Artificial tear', 'ยาตา', 'ขวด', [50, 110], ['0.3%']],
    ['Omeprazole', 'กระเพาะ/ท้อง', 'แผง', [12, 28], ['20 mg']], ['Simethicone', 'กระเพาะ/ท้อง', 'แผง', [8, 18], ['80 mg']],
    ['ORS', 'กระเพาะ/ท้อง', 'ซอง', [5, 9], ['25 g']], ['Domperidone', 'กระเพาะ/ท้อง', 'แผง', [8, 15], ['10 mg']],
    ['Clotrimazole cream', 'ผิวหนัง', 'หลอด', [25, 55], ['1%']], ['Hydrocortisone cream', 'ผิวหนัง', 'หลอด', [15, 40], ['1%']],
    ['Calamine lotion', 'ผิวหนัง', 'ขวด', [20, 40], ['60 ml']], ['Vitamin C', 'อาหารเสริม', 'กระปุก', [60, 150], ['500 mg', '1000 mg']],
    ['Zinc', 'อาหารเสริม', 'กระปุก', [80, 180], ['15 mg']], ['Fish oil', 'อาหารเสริม', 'กระปุก', [150, 320], ['1000 mg']],
    ['Calcium', 'อาหารเสริม', 'กระปุก', [120, 260], ['600 mg']], ['Povidone iodine', 'อื่นๆ', 'ขวด', [20, 60], ['10%']],
    ['Alcohol 70%', 'อื่นๆ', 'ขวด', [15, 45], ['450 ml']], ['Plaster', 'อื่นๆ', 'กล่อง', [15, 45], ['100 pcs']],
    ['Thermometer', 'อื่นๆ', 'อัน', [60, 180], ['digital']], ['Mask', 'อื่นๆ', 'กล่อง', [25, 60], ['50 pcs']],
    ['Amlodipine', 'อื่นๆ', 'แผง', [10, 25], ['5 mg', '10 mg']], ['Metformin', 'อื่นๆ', 'แผง', [8, 20], ['500 mg']],
    ['Simvastatin', 'อื่นๆ', 'แผง', [12, 30], ['20 mg']], ['Lorazepam', 'อื่นๆ', 'แผง', [30, 60], ['0.5 mg']]
  ]
  const STEM = ['Zeta', 'Nova', 'Medi', 'Vita', 'Siam', 'Lotus', 'Orchid', 'Naga', 'Mira', 'Kala', 'Sun', 'Blue']
  const SUP = ['บ.ยาดี จำกัด', 'หจก.สยามเภสัช', 'บ.โอสถภัณฑ์', 'ร้านส่งยาเจริญ', 'บ.เมดิโค']
  const LOC = ['A1', 'A2', 'A3', 'B1', 'B2', 'B3', 'C1', 'C2', 'ตู้เย็น', 'เคาน์เตอร์']
  const today = new Date(); today.setHours(0, 0, 0, 0)
  const dayAdd = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x }
  const iso = (d, h) => { const x = new Date(d); x.setHours(h || 9, ri(0, 59), ri(0, 59)); return x.toISOString() }
  const ymd = d => dayKey(d)

  // seed products get extra details
  S.products.forEach((p, i) => { p.barcode = '8850' + String(100000 + i * 37); p.supplier = pick(SUP); p.location = pick(LOC) })
  let code = Math.max(...S.products.map(p => parseInt(p.code, 10) || 0))
  const mock = []
  let n = 0
  for (const g of GEN) {
    const variants = ri(5, 7)
    for (let v = 0; v < variants; v++) {
      code++; n++
      const st = pick(g[4]), cost = ri(g[3][0] * 100, g[3][1] * 100) / 100
      const price = Math.round(cost * (1.25 + rnd() * 0.6))
      const p = { id: 'pm' + code, code: String(code), name: pick(STEM) + g[0].split(' ')[0].slice(0, 6).toLowerCase() + ' ' + st, generic: g[0], category: g[1], unit: g[2],
        cost, price: Math.max(price, Math.ceil(cost) + 1), reorder: ri(2, 8), note: 'MOCK', active: true,
        barcode: '8851' + String(200000 + n * 53), supplier: pick(SUP), location: pick(LOC),
        danger: ['Amoxicillin', 'Cefalexin', 'Roxithromycin', 'Norfloxacin', 'Omeprazole', 'Diclofenac gel', 'Amlodipine', 'Metformin', 'Simvastatin'].includes(g[0]),
        controlled: g[0] === 'Lorazepam' }
      p.manufacturer = pick(MAKERS); p.packSize = '10 ' + g[2] + '/กล่อง'; p.regNo = pick(['1A', '1C', '2A']) + ' ' + ri(10, 99) + '/' + ri(40, 66) + '(NC)'
      p.ky13 = rnd() < 0.05
      p.ky8 = rnd() < 0.06; p.ky11 = rnd() < 0.06; p.special = /cream|gel|eye|lotion|tear/i.test(g[0])
      S.products.push(p); mock.push(p)
    }
  }
  // opening-style initial receiving, 1 day before first sale
  const start = dayAdd(today, -DAYS)
  const recv = (day, items, supplier, invoice, orderId) => {
    const rc = Logic.receive(S, { invoice, supplier, day: ymd(day), items, discount: rnd() < 0.2 ? ri(5, 40) : 0, orderId })
    if (rnd() < 0.7) rc.invoiceTotal = rc.total
    const ts = iso(day, 9)
    rc.ts = ts
    for (const it of rc.items) {
      const lot = S.lots.find(l => l.id === it.lotId); lot.receivedAt = ts
      S.movements.filter(m => m.lotId === lot.id && m.type === 'receive').forEach(m => { m.ts = ts })
    }
    return rc
  }
  const lineFor = (p, qty, dayRef) => {
    const r = rnd(); let expDays
    if (r < 0.04) expDays = -ri(5, 60)            // already expired (kept on shelf)
    else if (r < 0.14) expDays = ri(10, 80)       // near expiry
    else expDays = ri(240, 900)
    const cost = Math.max(0.5, Math.round(p.cost * (0.92 + rnd() * 0.16) * 100) / 100)
    return { pid: p.id, qty, freeQty: rnd() < 0.12 ? ri(1, 4) : 0, unitCost: cost, lotNo: 'L' + ri(10000, 99999), expiry: ymd(dayAdd(today, expDays + (dayRef ? 0 : 0))) }
  }
  const sellables = () => S.products.filter(p => p.active !== false && p.type !== 'supply' && !(p.bundle && p.bundle.length))
  const byS = {}; for (const p of sellables()) (byS[p.supplier] = byS[p.supplier] || []).push(p)
  let inv = 0
  for (const sup of Object.keys(byS)) {
    const list = byS[sup].filter(p => mock.includes(p))
    for (let i = 0; i < list.length; i += 25) {
      recv(dayAdd(start, -1), list.slice(i, i + 25).map(p => lineFor(p, ri(15, 120))), sup, 'MOCK-' + String(++inv).padStart(4, '0'))
    }
  }
  // members
  const members = []
  const NAMES = ['สมชาย', 'สมหญิง', 'ประยุทธ', 'วิไล', 'มานะ', 'ปราณี', 'สุเทพ', 'นงลักษณ์']
  NAMES.forEach((nm, i) => members.push(Logic.addMember(S, { name: nm + ' (ตัวอย่าง)', phone: '08' + ri(10000000, 99999999), allergies: i % 3 === 0 ? [{ drug: 'Penicillin', reaction: 'ผื่น' }] : [], note: 'MOCK' })))
  // daily simulation
  const hot = sellables().filter(() => rnd() < 0.35)
  let voided = 0, bills = 0, skipped = 0
  for (let d = -DAYS; d <= 0; d++) {
    const day = dayAdd(today, d)
    if (d !== -DAYS && (d + DAYS) % 9 === 0) {   // restock low items
      const low = sellables().filter(p => Logic.stockOf(S, p.id) <= (p.reorder || 0) * 2)
      const groups = {}; low.forEach(p => (groups[p.supplier] = groups[p.supplier] || []).push(p))
      for (const sup of Object.keys(groups)) recv(day, groups[sup].map(p => lineFor(p, ri(20, 100))), sup, 'MOCK-' + String(++inv).padStart(4, '0'))
    }
    const nb = ri(7, 18)
    for (let b = 0; b < nb; b++) {
      const at = new Date(day); at.setHours(ri(9, 20), ri(0, 59), ri(0, 59))
      if (at.getTime() > Date.now() - 120000) continue
      const items = []
      for (let k = ri(1, 3); k > 0; k--) {
        const p = rnd() < 0.6 ? pick(hot) : pick(sellables())
        const qty = ri(1, 3)
        if (Logic.stockOf(S, p.id) < qty || items.some(i => i.pid === p.id)) continue
        items.push({ pid: p.id, name: p.name, unit: p.unit, qty, price: p.price })
      }
      if (!items.length) { skipped++; continue }
      const sub = items.reduce((t, i) => t + i.qty * i.price, 0)
      const cash = rnd() < 0.7
      try {
        ACTOR = pick(STAFF)
        const needB = items.some(i => { const q = S.products.find(x => x.id === i.pid); return q && (q.controlled || q.ky11 || q.ky13) })
        const isRx = needB && rnd() < 0.25
        const buyer = needB ? { name: pick(BUYERS), addr: 'ที่อยู่ตัวอย่าง ' + ri(1, 99) + ' กรุงเทพฯ', type: 'ผู้บริโภค' } : undefined
        const rx = isRx ? { doc: 'นพ.ตัวอย่าง รักษา', docAddr: 'โรงพยาบาลตัวอย่าง', user: buyer.name, age: String(ri(18, 80)), addr: buyer.addr } : undefined
        const sale = Logic.commitSale(S, { items, discount: rnd() < 0.08 ? Math.min(10, sub) : 0, method: cash ? 'cash' : 'transfer',
          received: Math.ceil(sub / 20) * 20, at: at.toISOString(), memberId: rnd() < 0.15 ? pick(members).id : '', buyer, rx })
        bills++
        if (rnd() < 0.02) { Logic.voidSale(S, sale.id, 'ลูกค้ายกเลิก'); voided++ }
      } catch (e) { skipped++ }
    }
  }
  // purchase orders: one open, one partly received, one fully received
  const ordProducts = mock.filter(p => Logic.stockOf(S, p.id) <= p.reorder * 3 && !p.controlled).slice(0, 14)
  const mk = (sup, list) => Logic.createOrder(S, { supplier: sup, day: ymd(today), note: 'MOCK', items: list.map(p => ({ pid: p.id, qty: ri(20, 60), unitCost: p.cost })) })
  const oOpen = mk(SUP[0], ordProducts.slice(0, 4))
  const oPart = mk(SUP[1], ordProducts.slice(4, 8))
  const oDone = mk(SUP[2], ordProducts.slice(8, 11))
  const rcvOrder = (o, only, short) => recv(today, o.items.filter((_, i) => !only || only.includes(i)).map(i => ({ pid: i.pid, qty: short ? Math.max(1, Math.floor(i.qty / 2)) : i.qty, unitCost: i.unitCost, lotNo: 'L' + ri(10000, 99999), expiry: ymd(dayAdd(today, ri(300, 700))) })), o.supplier, 'MOCK-' + String(++inv).padStart(4, '0'), o.id)
  rcvOrder(oPart, [0, 1], false)
  rcvOrder(oDone, null, false)
  // two supplier returns of near-expiry lots
  const cand = S.lots.filter(l => l.qtyLeft > 3 && l.expiry && l.expiry < ymd(dayAdd(today, 60))).slice(0, 2)
  cand.forEach(l => { try { Logic.returnGoods(S, { supplier: S.products.find(p => p.id === l.pid).supplier, day: ymd(today), reason: 'ใกล้หมดอายุ', items: [{ lotId: l.id, qty: 2 }], refund: '' }) } catch (e) {} })
  // a few items out of stock / negative-looking edge cases for UI testing
  mock.slice(0, 6).forEach(p => { const q = Logic.stockOf(S, p.id); if (q > 0) { try { Logic.adjust(S, p.id, 0, 'นับสต็อกไม่ตรง', 'MOCK หมดสต็อก') } catch (e) {} } })
  mock.slice(6, 14).forEach(p => { const q = Logic.stockOf(S, p.id); if (q > 1) { try { Logic.adjust(S, p.id, 1, 'นับสต็อกไม่ตรง', 'MOCK เหลือน้อย') } catch (e) {} } })
  const mkUser = (login, name, preset, extra) => ({ id: uid(), empId: 'E' + String(S.users.length + 1).padStart(3, '0'), login, name, role: PERM_PRESETS[preset].label, active: true, admin: preset === 'admin', workStart: '', workEnd: '', perms: { ...PERM_PRESETS[preset].perms }, ...(extra || {}) })
  S.users = [mkUser('demo', 'ผู้ดูแล (ตัวอย่าง)', 'admin'), mkUser('pharm', 'เภสัชกรตัวอย่าง', 'pharmacist'), mkUser('cashier', 'พนักงานขายตัวอย่าง', 'cashier'), mkUser('stock', 'พนักงานคลังตัวอย่าง', 'stock')]
  return { state: JSON.stringify(S), stats: { products: S.products.length, lots: S.lots.length, receipts: S.receipts.length, orders: S.orders.length, users: S.users.length, suppliers: S.suppliers.length, sales: S.sales.length, voided, members: S.members.length, returns: S.returns.length, skipped } }
}

;(async () => {
  const b = await chromium.launch(process.env.CHROME ? { executablePath: process.env.CHROME } : {})
  const pg = await b.newPage()
  await pg.route('**/@supabase/supabase-js@2', r => r.fulfill({ contentType: 'application/javascript', body: stub }))
  await pg.goto('file://' + path.join(root, 'index.html'))
  await pg.waitForSelector('#app', { timeout: 20000 })
  const out = await pg.evaluate(`(${build.toString()})(90)`)
  fs.writeFileSync(path.join(__dirname, 'mock_state.json'), out.state)
  console.log(JSON.stringify(out.stats), (out.state.length / 1e6).toFixed(2) + ' MB')
  await b.close()
})()
