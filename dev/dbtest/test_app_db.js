// End-to-end: the real app in database mode against a local PostgreSQL (permissions enforced by the database).
const { chromium } = require(process.env.PW || '/opt/node-tools/node_modules/playwright')
const { attach, freshDb } = require('./harness')
const fs = require('fs'), path = require('path')
const LIB = process.env.LIB || ''   // optional folder with vue.js / tw.js to avoid CDN access
const ok = (c, m) => { console.log((c ? 'ok   - ' : 'FAIL - ') + m); if (!c) process.exitCode = 1 }

;(async () => {
  const pool = await freshDb('pharm_app')
  const q = (sql, p) => pool.query(sql, p).then(r => r.rows)
  const U = { admin: '11111111-1111-1111-1111-111111111111', cashier: '22222222-2222-2222-2222-222222222222', newbie: null }
  await q(`select save_staff(jsonb_build_object('login','earth','display_name','เอิร์ธ','is_admin',true,'permissions','[]'::jsonb,'auth_user_id',$1::text))`, [U.admin])
  await q(`select save_staff(jsonb_build_object('login','cash','display_name','พนักงานขาย','permissions','["pos","members","billsView","sellOtc"]'::jsonb,'auth_user_id',$1::text))`, [U.cashier])
  await q(`select set_pin('', '482913')`)
  await q(`select save_supplier('{"name":"ซัพพลายเออร์ A","phone":"021111111"}')`)
  const prod = async (o) => (await q('select save_product($1::jsonb) id', [JSON.stringify(o)]))[0].id
  const pPara = await prod({ code: 'P001', name: 'พาราเซตามอล 500', generic_name: 'Paracetamol', category: 'แก้ปวด', unit: 'แผง', price1: 20, reorder_point: 5, drug_types: ['otc'], latest_cost: 8 })
  const pAmox = await prod({ code: 'P002', name: 'อะม็อกซี่ 500', generic_name: 'Amoxicillin', category: 'ยาปฏิชีวนะ', unit: 'แผง', price1: 60, drug_types: ['danger'], latest_cost: 30 })
  const pKy = await prod({ code: 'P003', name: 'ยา ขย.11 ตัวอย่าง', category: 'อื่นๆ', unit: 'ขวด', price1: 100, drug_types: ['ky11'], manufacturer: 'ผู้ผลิต X', pack_size: '60 มล.', latest_cost: 60 })
  await q(`select receive_goods(jsonb_build_object('supplier_name','ซัพพลายเออร์ A','invoice_no','INV-1','items',jsonb_build_array(
     jsonb_build_object('product_id',$1::bigint,'qty',50,'unit_cost',8,'lot_no','LP1','exp_date',(current_date+400)::text),
     jsonb_build_object('product_id',$2::bigint,'qty',20,'unit_cost',30,'lot_no','LA1','exp_date',(current_date+300)::text),
     jsonb_build_object('product_id',$3::bigint,'qty',10,'unit_cost',60,'lot_no','LK1','exp_date',(current_date+200)::text))))`, [pPara, pAmox, pKy])
  const pOtc = await prod({ code: 'P005', name: 'วิตามินซี', category: 'อื่นๆ', unit: 'กระปุก', price1: 22, drug_types: ['otc'], latest_cost: 10 })
  await q(`select open_stock($1::bigint, 5, 10)`, [pOtc])
  await q(`select save_customer('{"name":"สมหญิง ใจดี","phone":"0811111111","allergies":[{"drug":"Penicillin","reaction":"ผื่น"}]}')`)

  const authUsers = { 'earth@mypharm.com': { id: U.admin, pw: 'secret1' }, 'cash@mypharm.com': { id: U.cashier, pw: 'secret2' }, 'late@mypharm.com': { id: '33333333-3333-3333-3333-333333333333', pw: 'secret3' }, 'moved@mypharm.com': { id: '44444444-4444-4444-4444-444444444444', pw: 'secret4' } }
  const browser = await chromium.launch()
  const errs = []
  const open = async (user, pw) => {
    const ctx = await browser.newContext({ viewport: { width: 1400, height: 900 } })
    const pg = await ctx.newPage()
    pg.on('pageerror', e => errs.push(e.message))
    await attach(pg, pool, authUsers)
    await pg.addInitScript(() => { localStorage.setItem('earthshop_db', JSON.stringify({ url: 'https://test.supabase.co', key: 'x'.repeat(40) })) })
    await pg.route('**/@supabase/supabase-js@2', r => r.fulfill({ contentType: 'application/javascript', body: '' }))
    if (LIB) { await pg.route('**/vue@*/**', r => r.fulfill({ contentType: 'application/javascript', body: fs.readFileSync(path.join(LIB, 'vue.js')) })); await pg.route('**/cdn.tailwindcss.com/**', r => r.fulfill({ contentType: 'application/javascript', body: fs.readFileSync(path.join(LIB, 'tw.js')) })) }
    await pg.goto('file://' + path.join(__dirname, '..', '..', 'index.html'))
    await pg.waitForSelector('input[name=username]', { timeout: 60000 })
    await pg.fill('input[name=username]', user); await pg.fill('input[name=password]', pw)
    await pg.click('button[type=submit]')
    try { await pg.waitForFunction(() => window.__vm && window.__vm.authed && !window.__vm.isLoading, null, { timeout: 30000 }) } catch (e) { console.log('LOGIN ERROR:', await pg.evaluate(() => window.__vm.loginForm.error)); throw e }
    await pg.waitForTimeout(400)
    return pg
  }
  const vm = (pg, fn, arg) => pg.evaluate(fn, arg)

  // ---------------- admin ----------------
  let pg = await open('earth', 'secret1')
  let st = await vm(pg, () => { const v = window.__vm; return { n: v.S.products.length, lots: v.S.lots.length, admin: v.me && v.me.admin, hasAdmin: v.hasAdmin, sup: v.S.suppliers.length, mem: v.S.members.length, flags: v.S.products.find(p => p.code === 'P002').danger, cost: v.S.products.find(p => p.code === 'P001').cost } })
  ok(st.n === 4 && st.lots === 4 && st.admin && st.hasAdmin && st.sup === 1 && st.mem === 1, 'loads products, lots, supplier, customers and admin rights: ' + JSON.stringify(st))
  ok(st.flags === true && st.cost === 8, 'drug types and cost come through')

  // sell: OTC item, then dangerous item with member, via the real pay flow
  await vm(pg, () => { const v = window.__vm; v.addToCart(v.S.products.find(p => p.code === 'P001')); v.addToCart(v.S.products.find(p => p.code === 'P001')); v.openPay('cash'); v.payModal.received = 100 })
  await vm(pg, () => window.__vm.confirmPay()); await pg.waitForTimeout(800)
  let sale = await q(`select s.bill_no, s.total, s.received, s.change_amount, s.staff_name, l.qty, l.cost_total from sales s join sale_lines l on l.sale_id=s.id order by s.id desc limit 1`)
  ok(sale[0] && Number(sale[0].total) === 40 && Number(sale[0].change_amount) === 60 && sale[0].staff_name === 'เอิร์ธ' && Number(sale[0].cost_total) === 16, 'sale committed in the database: ' + JSON.stringify(sale[0]))
  ok((await vm(pg, () => { const v = window.__vm; return v.stockMap[v.S.products.find(p => p.code === 'P001').id] })) === 48, 'app stock updated to 48')
  ok(await vm(pg, () => !!window.__vm.resultSale && window.__vm.resultSale.no.startsWith('B')), 'result screen has the saved bill')

  // void through PIN
  await vm(pg, () => { const v = window.__vm; v.saleDetailId = v.resultSale.id; v.voidReason = 'ทดสอบ'; v.voidFromHistory() }); await pg.waitForTimeout(200)
  await pg.fill('.modal input[type=password]', '0000'); await pg.click('.modal button:has-text("ยืนยัน")'); await pg.waitForTimeout(500)
  ok(await pg.locator('text=รหัสผ่านไม่ถูกต้อง').count() > 0, 'wrong PIN is rejected by the database')
  await pg.fill('.modal input[type=password]', '482913'); await pg.click('.modal button:has-text("ยืนยัน")'); await pg.waitForTimeout(900)
  ok((await q(`select status from sales order by id desc limit 1`))[0].status === 'void', 'bill voided with the right PIN')
  ok((await vm(pg, () => { const v = window.__vm; return v.stockMap[v.S.products.find(p => p.code === 'P001').id] })) === 50, 'stock restored after void')

  // dangerous drug with buyer rules (ky11 needs buyer name)
  const r1 = await vm(pg, async () => { const v = window.__vm; try { await Logic.commitSale(v.S, { items: [{ pid: v.S.products.find(p => p.code === 'P003').id, name: 'x', qty: 1, price: 100 }], discount: 0, method: 'cash', received: 100 }); return 'sold' } catch (e) { return e.message } })
  ok(/ผู้ซื้อ/.test(r1), 'database requires buyer for ky11: ' + r1)
  const r2 = await vm(pg, async () => { const v = window.__vm; const m = v.S.members[0]; const s = await Logic.commitSale(v.S, { items: [{ pid: v.S.products.find(p => p.code === 'P003').id, name: 'ยา ขย.11 ตัวอย่าง', qty: 2, price: 100 }, { pid: v.S.products.find(p => p.code === 'P002').id, name: 'อะม็อกซี่ 500', qty: 1, price: 60 }], discount: 26, method: 'transfer', received: 0, memberId: m.id, buyer: { name: 'สมหญิง ใจดี', addr: '1 ถนนทดสอบ', type: 'ผู้บริโภค' } }); return { no: s.no, total: s.total, buyer: s.buyer && s.buyer.name, member: s.memberId } })
  ok(r2.total === 234 && r2.buyer === 'สมหญิง ใจดี' && !!r2.member, 'sale with buyer, member, discount: ' + JSON.stringify(r2))

  // receive goods (duplicate invoice flow), stock adjust, lot cost
  const rc = await vm(pg, async () => { const v = window.__vm; const p = v.S.products.find(x => x.code === 'P002'); const r = await Logic.receive(v.S, { invoice: 'INV-2', supplier: 'ซัพพลายเออร์ B', day: new Date().toISOString().slice(0, 10), items: [{ pid: p.id, qty: 10, freeQty: 2, unitCost: 31, lotNo: 'LA2', expiry: '2027-12-31' }], discount: 10 }); return { total: r.total, items: r.items.length, sup: v.S.suppliers.length, lots: v.S.lots.filter(l => l.pid === p.id).length } })
  ok(rc.total === 300 && rc.items === 1 && rc.sup === 2 && rc.lots === 2, 'receive_goods: new supplier created, lot added: ' + JSON.stringify(rc))
  const dup = await vm(pg, async () => { const v = window.__vm; const p = v.S.products.find(x => x.code === 'P002'); try { await Logic.receive(v.S, { invoice: 'INV-2', supplier: 'ซัพพลายเออร์ B', day: '2026-01-01', items: [{ pid: p.id, qty: 1, unitCost: 1 }] }); return 'accepted' } catch (e) { return e.code } })
  ok(dup === '23505', 'duplicate invoice rejected (code 23505)')
  const adj = await vm(pg, async () => { const v = window.__vm; const p = v.S.products.find(x => x.code === 'P001'); const d = await Logic.adjust(v.S, p.id, 45, 'นับสต็อกไม่ตรง', ''); return { d, stock: v.stockMap[p.id] } })
  ok(adj.d === -5 && adj.stock === 45, 'adjust stock -5')
  const po = await vm(pg, async () => { const v = window.__vm; const p = v.S.products.find(x => x.code === 'P001'); const o = await Logic.createOrder(v.S, { supplier: 'ซัพพลายเออร์ A', day: '2026-02-01', note: 'ทดสอบ', items: [{ pid: p.id, qty: 30, unitCost: 8 }] }); const rr = await Logic.receive(v.S, { invoice: 'INV-PO', supplier: 'ซัพพลายเออร์ A', day: '2026-02-02', orderId: o.id, items: [{ pid: p.id, qty: 30, unitCost: 8 }] }); const o2 = v.S.orders.find(x => x.id === o.id); return { no: o.no, got: o2.items[0].got, status: o2.status, closed: o2.closed } })
  ok(po.no === 'PO00001' && po.got === 30 && po.status === 'closed' && po.closed, 'purchase order created and received against: ' + JSON.stringify(po))

  // product save + bulk drug type + grid
  const sp = await vm(pg, async () => { const v = window.__vm; const id = await Db.saveProduct(v.S, null, { code: 'P004', name: 'สินค้าใหม่', generic: '', category: 'อื่นๆ', unit: 'ชิ้น', price: 15, cost: 5, reorder: 2, note: '', type: 'sell', supplier: 'ซัพพลายเออร์ A', barcode: '8851234567890', location: 'A1', danger: true }); await Db.openStock(v.S, id, 12, 5); const p = v.S.products.find(x => x.id === id); return { id, danger: p.danger, sup: p.supplier, stock: v.stockMap[id], bar: p.barcode } })
  ok(sp.danger && sp.sup === 'ซัพพลายเออร์ A' && sp.stock === 12 && sp.bar === '8851234567890', 'new product saved with flags, supplier and opening stock: ' + JSON.stringify(sp))
  await vm(pg, () => { const v = window.__vm; const p = v.S.products.find(x => x.code === 'P001'); v.tab = 'manage'; v.mgMode = 'grid'; v.gset(p, 'price', '22'); v.gset(p, 'otc', false); v.gset(p, 'controlled', true); v.gset(p, 'stock', '40') })
  await pg.waitForTimeout(200)
  await vm(pg, () => window.__vm.gridSave()); await pg.waitForTimeout(200)
  await pg.fill('.modal input[type=password]', '482913'); await pg.click('.modal button:has-text("ยืนยัน")'); await pg.waitForTimeout(1200)
  const gp = (await q(`select p.price1, (select array_agg(type_code order by type_code) from product_drug_types where product_id=p.id) t, app.stock_of(p.id) s from products p where code='P001'`))[0]
  ok(Number(gp.price1) === 22 && gp.t.join() === 'controlled' && Number(gp.s) === 40, 'management grid saved price, drug types and stock adjustment together: ' + JSON.stringify(gp))

  // CSV import in database mode (products + members)
  const csv = await vm(pg, async () => { const v = window.__vm; let text = ''; v.csvDownload = (n, t) => { text = t }; v.exportProductsCsv(); const rows = Csv.parse(text); const h = rows[0], col = k => h.indexOf(k)
    rows[1][col('price')] = '31'; const nr = h.map(() => ''); nr[col('code')] = 'CSV1'; nr[col('name')] = 'สินค้าจาก CSV'; nr[col('price')] = '9.5'; nr[col('stock')] = '6'; nr[col('danger')] = '1'; rows.push(nr)
    v.csvPrepare('products', Csv.parse(Csv.encode(rows)), 'p.csv'); const counts = { ...v.csvImp.counts }; for (const r of v.csvImp.rows.filter(x => x.status === 'new' || x.status === 'change')) await v.csvApplyProduct(r)
    const np = v.S.products.find(x => x.code === 'CSV1'); return { counts, np: np && { price: np.price, danger: np.danger, stock: v.stockMap[np.id] } } })
  ok(csv.counts.new === 1 && csv.counts.change === 1 && csv.np && csv.np.price === 9.5 && csv.np.danger && csv.np.stock === 6, 'CSV import (products) saved to the database: ' + JSON.stringify(csv))
  const mem = await vm(pg, async () => { const v = window.__vm; let t = ''; v.csvDownload = (n, x) => { t = x }; v.exportMembersCsv(); const rows = Csv.parse(t); rows[1][rows[0].indexOf('phone')] = '0822223333'; rows.push(['M9001', 'สมาชิกจาก CSV', '0844445555', 'Sulfa:ผื่น', 'x'])
    v.csvPrepare('members', Csv.parse(Csv.encode(rows)), 'm.csv'); for (const r of v.csvImp.rows.filter(x => x.status !== 'same')) await v.csvApplyMember(r)
    const m = v.S.members.find(x => x.code === 'M9001'); return { n: v.S.members.length, ph: v.S.members[0].phone, al: m && m.allergies.length } })
  ok(mem.n === 2 && mem.al === 1 && mem.ph === '0822223333', 'CSV import (members) saved to the database: ' + JSON.stringify(mem))

  const rs = await vm(pg, async () => { const v = window.__vm; const t = { products: await Db.rows('v_products'), suppliers: await Db.rows('v_suppliers'), lots: await Db.rows('v_lots'), customers: await Db.rows('v_customers'), customer_allergies: await Db.rows('v_customer_allergies') }
    v.restoreFile = { at: '-', t }; v.dbRestorePrep('products'); const a = { ...v.csvImp.counts }
    t.products[0].price1 = 99; t.customers[0].phone = '0000'; v.dbRestorePrep('products'); const b = { ...v.csvImp.counts }; v.dbRestorePrep('members'); return { a, b, m: { ...v.csvImp.counts } } })
  ok(rs.a.change === 0 && rs.a.error === 0 && rs.b.change === 1 && rs.m.change === 1, 'restore from a backup file previews only the real differences: ' + JSON.stringify(rs))

  // reports and forms via the database
  const rep = await vm(pg, async () => { const v = window.__vm; const to = Date.now() + 864e5, from = to - 5 * 864e5; const r = await Db.reportSales({ from, to, group: 'flag' }); const k = await Db.kyData('11', { from, to }); const doc = Logic.buildKyFromRows(v.S, '11', { from, to }, k.rows); const k9 = await Db.kyData('9', { from, to }); return { total: r.totals.sales, flags: r.rows.map(x => x.key).join(), pages: doc.pages.length, rows: doc.pages[0] && doc.pages[0].rows.length, buyer: doc.pages[0] && doc.pages[0].rows[0] && doc.pages[0].rows[0].buyer, k9: k9.rows.length } })
  ok(rep.total === 234 && rep.pages === 1 && rep.rows === 1 && rep.buyer === 'สมหญิง ใจดี' && rep.k9 >= 3, 'reports and ข.ย. forms from the database: ' + JSON.stringify(rep))

  // SmartDrugstore import into the database (products, members, in-stock lots, last-30-day bills)
  const imp = await vm(pg, async () => {
    const v = window.__vm; const today = new Date().toISOString().slice(0, 10), old = '2020-01-05'
    const T = { tb_shopdetail: [{ shop_name: 'ร้านเดิม' }], tb_supplier: [{ sup_id: 'S1', sup_name: 'ซัพเดิม', sup_tel: '02' }],
      tb_product: [{ product_id: 'X001', product_bname: 'ยาเดิม หนึ่ง', product_group: 'แก้ปวด', product_unit_name: 'แผง', product_sale_price: '25', product_reorder: '3', product_active: '1', product_sup_id: 'S1', product_danger: '1', product_report11: '1', product_commonname: 'Gen1' },
                   { product_id: 'X002', product_bname: 'ยาเดิม สอง', product_group: 'ยาตา', product_unit_name: 'ขวด', product_sale_price: '50', product_reorder: '1', product_active: '1', product_sup_id: 'S1' }],
      tb_productall: [{ product_id: 'X001', recive_date: old, exp_date: '2030-01-01', value_recive: '10', value_now: '4', capacity: '12', produce_num: 'LOT-A', order_id: 'O1' },
                      { product_id: 'X002', recive_date: old, exp_date: '2029-01-01', value_recive: '5', value_now: '0', capacity: '30', produce_num: 'LOT-B', order_id: 'O1' }],
      tb_customer: [{ cus_id: 'C100', cus_name: 'ลูกค้าเดิม', cus_tel: '081', cus_druglose: 'Aspirin', cus_comment: 'ทดสอบ' }], tb_user: [], tb_order: [], tb_recivedetail: [],
      tb_sale: [{ bill_id: 'OLD-1', sale_date: today, sale_time: '10:00:00', Net_recive_M: '75', discount: '0', moneyComein: '100', moneyBack: '25', cus_id: 'C100', Login_name: 'earth', user_id: 'U1' }],
      tb_saledetail: [{ bill_id: 'OLD-1', pro_id: 'X001', product_name: 'ยาเดิม หนึ่ง', value: '3', price: '25', capacityPunit: '12', recive_date: old, produce_num: 'LOT-A' }] }
    const r = Importer.convert(T, 30)
    v.dbImp = { busy: false, msg: '', stats: r.stats, state: r.state, o: { products: true, members: true, lots: true, sales: true }, days: 30 }
    await v.dbImportApply()
    const S = v.S; const p1 = S.products.find(x => x.code === 'X001')
    return { err: v.dbImp && v.dbImp.error, p1: p1 && { danger: p1.danger, ky11: p1.ky11, sup: p1.supplier, price: p1.price }, stock: p1 && v.stockMap[p1.id], mem: S.members.some(m => m.code === 'C100'), sale: S.sales.some(x => x.no === 'OLD-1') } })
  ok(!imp.err && imp.p1 && imp.p1.danger && imp.p1.ky11 && imp.p1.sup === 'ซัพเดิม' && imp.stock === 4 && imp.mem && imp.sale, 'SmartDrugstore import (products, members, lots, bills): ' + JSON.stringify(imp))
  const inv = (await q(`select (select count(*) from lots l where qty_left <> coalesce((select sum(qty) from stock_movements m where m.lot_id=l.id),0)) bad, (select count(*) from sale_line_lots sll join sale_lines sl on sl.id=sll.sale_line_id join sales s on s.id=sl.sale_id where s.bill_no='OLD-1') alloc`))[0]
  ok(Number(inv.bad) === 0 && Number(inv.alloc) === 1, 'imported lots keep stock = sum of movements, bill linked to its lot: ' + JSON.stringify(inv))
  const again = await vm(pg, async () => { const v = window.__vm; const before = v.S.sales.length; await v.dbImportApply().catch(() => {}); return v.S.sales.length === before })
  ok(again === true, 'running the import twice does not duplicate bills')

  // supplier + settings + users
  const ss = await vm(pg, async () => { const v = window.__vm; v.vsNew(); v.vs.name = 'ผู้จำหน่ายใหม่'; v.vs.contact = 'คุณเอ'; v.vs.openTime = '08:00'; const p = v.S.products[0]; v.vs.terms.push({ pid: p.id, name: p.name, buy: 10, free: 1 }); await v.vsSave(); const s = v.S.suppliers.find(x => x.name === 'ผู้จำหน่ายใหม่'); return { c: s && s.contact, t: s && s.terms.length, o: s && s.openTime } })
  ok(ss.c === 'คุณเอ' && ss.t === 1 && ss.o === '08:00', 'supplier master saved with free-goods terms: ' + JSON.stringify(ss))
  await vm(pg, () => { window.__vm.S.settings.shopName = 'ร้านทดสอบ DB'; window.__vm.S.settings.shopPhone = '029999999'; window.__vm.S.settings.prog = { costMethod: 'avg', vatMode: 'included' } })
  await pg.waitForTimeout(1500)
  const shop = (await q('select name, phone, settings from shop'))[0]
  ok(shop.name === 'ร้านทดสอบ DB' && shop.phone === '029999999' && shop.settings.prog.costMethod === 'avg', 'shop settings auto-saved to the database')
  await vm(pg, async () => { const v = window.__vm; v.usNew(); v.us.name = 'พนักงานใหม่'; v.us.login = 'newbie'; v.usPass = 'abc123'; v.usPass2 = 'abc123'; v.us.perms = { pos: true, billsView: true }; v.usSave() })
  await pg.waitForTimeout(200); await pg.fill('.modal input[type=password]', '482913'); await pg.click('.modal button:has-text("ยืนยัน")'); await pg.waitForTimeout(1000)
  const nb = (await q(`select s.login, s.active, (select array_agg(perm_code order by perm_code) from staff_permissions where staff_id=s.id) p from staff s where login='newbie'`))[0]
  ok(nb && nb.p.join() === 'billsView,pos' && authUsers['newbie@mypharm.com'], 'new user: auth account created and staff privileges saved: ' + JSON.stringify(nb))
  // an account that already exists in Supabase Auth is given admin by the admin, then that person logs in
  await vm(pg, async () => { const v = window.__vm; v.usNew(); v.us.name = 'ผู้ดูแลคนที่สอง'; v.us.login = 'late'; v.us.admin = true; v.usPass = 'whatever1'; v.usPass2 = 'whatever1'; v.usSave() })
  await pg.waitForTimeout(200); await pg.fill('.modal input[type=password]', '482913'); await pg.click('.modal button:has-text("ยืนยัน")'); await pg.waitForTimeout(1000)
  const late = (await q(`select login, is_admin, auth_user_id from staff where login='late'`))[0]
  ok(late && late.is_admin && late.auth_user_id === null, 'admin can give admin to an account that already exists (not yet linked): ' + JSON.stringify(late))
  await pg.context().close()

  // ---------------- cashier ----------------
  pg = await open('cash', 'secret2')
  const c = await vm(pg, () => { const v = window.__vm; return { admin: v.me && v.me.admin, canVoid: v.can('voidSale'), canCost: v.can('viewCost'), cost: v.S.products[0].cost, tabs: v.visibleGroups.map(g => g.id).join(), lots: v.S.lots.length, users: v.S.users.length } })
  ok(!c.admin && !c.canVoid && !c.canCost && c.cost === 0 && c.users === 1, 'cashier: limited rights, cost hidden by the database: ' + JSON.stringify(c))
  const cs = await vm(pg, async () => { const v = window.__vm; const out = {}; try { await Logic.commitSale(v.S, { items: [{ pid: v.S.products.find(p => p.code === 'P002').id, name: 'x', qty: 1, price: 60 }], discount: 0, method: 'cash', received: 60 }); out.danger = 'sold' } catch (e) { out.danger = e.message }
    try { await Logic.adjust(v.S, v.S.products[0].id, 1, 'x', ''); out.adj = 'done' } catch (e) { out.adj = e.message }
    const ok1 = await Logic.commitSale(v.S, { items: [{ pid: v.S.products.find(p => p.code === 'P005').id, name: 'x', qty: 1, price: 22 }], discount: 0, method: 'cash', received: 22 }).then(() => 'sold', e => e.message); out.otc = ok1; return out })
  ok(/ไม่มีสิทธิ์/.test(cs.danger) && /ไม่มีสิทธิ์/.test(cs.adj) && cs.otc === 'sold', 'database blocks dangerous sale and stock adjust for cashier; OTC sale works: ' + JSON.stringify(cs))
  await pg.context().close()

  // staff row tied to a deleted/old auth account (e.g. email domain changed): the new login with the same name takes it over
  await q(`select save_staff(jsonb_build_object('login','moved','display_name','ย้ายโดเมน','is_admin',true,'permissions','[]'::jsonb,'auth_user_id','99999999-9999-9999-9999-999999999999'))`)
  const pm = await open('moved', 'secret4')
  const mv = await vm(pm, () => { const v = window.__vm; return { admin: v.me && v.me.admin } })
  ok(mv.admin, 'a login recreated under a new email domain takes over the old staff record: ' + JSON.stringify(mv))
  await pm.context().close()
  const pl = await open('late', 'secret3')
  const lt = await vm(pl, () => { const v = window.__vm; return { admin: v.me && v.me.admin, can: v.can('voidSale'), name: v.actor } })
  ok(lt.admin && lt.can, 'after the first login the account is linked and has admin rights: ' + JSON.stringify(lt))
  await pl.context().close()

  ok(errs.length === 0, 'no page errors ' + JSON.stringify(errs.slice(0, 3)))
  await browser.close(); await pool.end()
})().catch(e => { console.error('CRASH', e); process.exit(1) })
