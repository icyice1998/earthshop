#!/usr/bin/env python3
"""Migrate a SmartDrugstore MySQL dump (Navicat export of database `drgstr`) into the new PostgreSQL schema.

usage:
  python3 -I migrate_drgstr.py DUMP.sql OUTDIR [--sales-days N]

It READS the dump as text (nothing in it is executed) and writes tab-separated files plus load.sql into OUTDIR.
Then load them into an empty database that already has 01_schema.sql, 02_functions.sql, 03_security.sql applied:

  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f OUTDIR/load.sql        # run from inside OUTDIR (it uses relative \\copy paths)
  psql "$DATABASE_URL" -f verify.sql                                  # compare with OUTDIR/expected.json

Full history is migrated by default. --sales-days N limits bills to the last N days (stock is still exact).

NOT migrated on purpose: passwords, bill-edit passwords, ID-card numbers, birth dates, customer addresses,
health-insurance data, pictures. The output contains customer names and phone numbers: keep it private, never commit it.
"""
import sys, os, re, json, collections, importlib.util
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('conv', os.path.join(HERE, '..', 'dev', 'migrate', 'drgstr_to_state.py'))
conv = importlib.util.module_from_spec(spec); spec.loader.exec_module(conv)
load, num, txt, date, R2, R4 = conv.load, conv.num, conv.txt, conv.date, conv.R2, conv.R4

TZ = '+07:00'

def esc(v):
    if v is None: return '\\N'
    if isinstance(v, bool): return 't' if v else 'f'
    s = str(v)
    return s.replace('\\', '\\\\').replace('\t', '\\t').replace('\n', '\\n').replace('\r', '\\r')

class Out:
    def __init__(self, d): self.d = d; self.files = {}; self.counts = collections.Counter(); self.cols = {}
    def open(self, table, cols):
        self.cols[table] = cols; self.files[table] = open(os.path.join(self.d, table + '.tsv'), 'w', encoding='utf-8', newline='\n')
    def row(self, table, *vals):
        assert len(vals) == len(self.cols[table]), (table, len(vals), len(self.cols[table]))
        self.files[table].write('\t'.join(esc(v) for v in vals) + '\n'); self.counts[table] += 1
    def close(self):
        for f in self.files.values(): f.close()

def nz(v):
    v = txt(v); return v if v else None

def main():
    if len(sys.argv) < 3: print(__doc__); sys.exit(1)
    src, outdir = sys.argv[1], sys.argv[2]
    days = int(sys.argv[sys.argv.index('--sales-days') + 1]) if '--sales-days' in sys.argv else None
    os.makedirs(outdir, exist_ok=True)
    T = load(src, {'tb_product', 'tb_productall', 'tb_recivedetail', 'tb_order', 'tb_orderdetail', 'tb_supplier', 'tb_customer', 'tb_user', 'tb_shopdetail', 'tb_sale', 'tb_saledetail',
                   'tb_drawer', 'tb_userhistory', 'tb_sale_edit', 'tb_saledetail_edit', 'tb_transfer_product', 'tb_transfer_prodetail', 'tb_interaction', 'tb_return', 'tb_returndetail', 'tb_productsticker'})
    O = Out(outdir)
    cols = {
        'categories': ['id', 'name'],
        'suppliers': ['id', 'code', 'name', 'address', 'province', 'zip', 'phone', 'fax', 'tax_id', 'contact_name', 'contact_mobile', 'open_time', 'close_time'],
        'products': ['id', 'code', 'name', 'generic_name', 'category_id', 'unit', 'barcode', 'location', 'reg_no', 'supplier_id', 'reorder_point', 'order_qty', 'exp_warn_days', 'price1', 'price2', 'price3', 'price4', 'price5', 'latest_cost', 'active', 'usage_text'],
        'product_drug_types': ['product_id', 'type_code'],
        'product_usage_templates': ['product_id', 'name', 'dosage_th', 'dosage_en', 'time_th', 'time_en', 'comment_th', 'comment_en', 'keep_th', 'keep_en'],
        'customers': ['id', 'code', 'name', 'phone', 'note'],
        'customer_allergies': ['customer_id', 'drug', 'reaction'],
        'staff': ['login', 'emp_id', 'display_name', 'license_no', 'role_label', 'active', 'work_start', 'work_end'],
        'purchase_orders': ['id', 'no', 'supplier_id', 'ordered_on', 'appoint_receive_on', 'appoint_pay_on', 'amount', 'doc_no', 'status', 'legacy_status', 'staff_name'],
        'purchase_order_lines': ['po_id', 'product_id', 'qty', 'unit_cost', 'received_qty'],
        'receipts': ['id', 'supplier_id', 'invoice_no', 'received_on', 'po_id', 'subtotal', 'discount', 'total', 'status', 'staff_name'],
        'receipt_lines': ['id', 'receipt_id', 'product_id', 'qty', 'free_qty', 'unit_cost', 'line_discount', 'eff_cost', 'lot_no', 'exp_date', 'lot_id'],
        'lots': ['id', 'product_id', 'lot_no', 'exp_date', 'received_on', 'qty_in', 'qty_left', 'unit_cost', 'supplier_id', 'receipt_line_id', 'source'],
        'stock_movements': ['ts', 'product_id', 'lot_id', 'type', 'qty', 'ref_no', 'note', 'staff_name'],
        'sales': ['id', 'bill_no', 'ts', 'sale_date', 'customer_id', 'staff_name', 'subtotal', 'discount', 'total', 'method', 'received', 'change_amount', 'status', 'buyer_name', 'buyer_addr', 'buyer_type', 'rx_prescriber', 'rx_prescriber_addr', 'rx_user', 'rx_user_age', 'rx_user_addr', 'imported'],
        'sale_lines': ['id', 'sale_id', 'line_no', 'product_id', 'name', 'unit', 'qty', 'unit_price', 'line_discount', 'line_total', 'cost_total'],
        'sale_line_lots': ['sale_line_id', 'lot_id', 'qty', 'unit_cost'],
        'cash_drawer_events': ['ts', 'staff_name', 'comment'],
        'login_history': ['login', 'login_at', 'logout_at'],
        'bill_edits': ['bill_no', 'edited_on', 'staff_login', 'ip_address', 'old_total', 'old_discount', 'old_net', 'diff', 'old_lines'],
        'stock_transfers': ['id', 'transfer_no', 'branch_code', 'branch_name', 'transferred_on', 'total', 'staff_name'],
        'stock_transfer_lines': ['transfer_id', 'product_code', 'product_name', 'qty', 'unit_price', 'line_total', 'exp_date', 'lot_no'],
        'drug_interactions': ['type1', 'code1', 'name1', 'type2', 'code2', 'name2', 'effect'],
        'supplier_returns': ['id', 'return_no', 'supplier_id', 'returned_on', 'refund', 'status'],
        'supplier_return_lines': ['return_id', 'product_id', 'lot_id', 'qty', 'unit_cost'],
    }
    for t, c in cols.items(): O.open(t, c)
    exp = {}  # expected figures straight from the source, for verify.sql

    # ---------- shop ----------
    sh = (T['tb_shopdetail'] or [{}])[0]
    shop = {'name': txt(sh.get('shop_name')), 'name_en': nz(sh.get('shop_name_eng')), 'address': nz(sh.get('shop_address')), 'province': nz(sh.get('shop_province')), 'zip': nz(sh.get('shop_zip')),
            'phone': nz(sh.get('shop_tel')), 'fax': nz(sh.get('shop_fax')), 'tax_id': nz(sh.get('shop_tax')), 'license_no': nz(sh.get('certificate_number')), 'pharmacist_name': nz(sh.get('doc_name')),
            'branch_code': nz(sh.get('branch_id')), 'branch_name': nz(sh.get('branch_name')), 'open_time': nz(sh.get('time_open')), 'close_time': nz(sh.get('time_close'))}

    # ---------- suppliers ----------
    sup_id = {}; n = 0
    for s in T['tb_supplier']:
        if not txt(s['sup_name']): continue
        n += 1; sup_id[txt(s['sup_id'])] = n
        O.row('suppliers', n, nz(s['sup_id']), txt(s['sup_name']), nz(s['sup_address']), nz(s['sup_province']), nz(s['sup_zip']), nz(s['sup_tel']), nz(s['sup_fax']), nz(s['sup_tax']), nz(s['contact_name']), nz(s['contact_mobile']), nz(s['time_open']), nz(s['time_close']))
    exp['suppliers'] = n

    # ---------- lots (first, to know the latest cost) ----------
    lots_raw = T['tb_productall']
    latest_cost = {}
    for r in sorted(lots_raw, key=lambda r: date(r['recive_date'])):
        if num(r['capacity']) > 0: latest_cost[txt(r['product_id'])] = R4(num(r['capacity']))

    # ---------- categories + products ----------
    cat_id = {}
    def cat_of(name):
        name = name if name and name != '#ไม่ระบุ#' else 'อื่นๆ'
        if name not in cat_id:
            cat_id[name] = len(cat_id) + 1; O.row('categories', cat_id[name], name)
        return cat_id[name]
    prod_id = {}; n = 0
    FLAGS = [('product_danger', '1', 'danger'), ('product_eff', '1', 'controlled'), ('product_OTC_Drug', '1', 'otc'), ('drugout', '1', 'offsys'), ('printauto', '1', 'autolabel'), ('Report9N', '1', 'ky9n')]
    flag_counts = collections.Counter()
    for p in T['tb_product']:
        code = txt(p['product_id'])
        if not code: continue
        n += 1; prod_id[code] = n
        O.row('products', n, code, txt(p['product_bname']) or code, nz(p['product_commonname']), cat_of(txt(p['product_group'])), txt(p['product_unit_name']) or 'ชิ้น', nz(p['product_barcode']), nz(p['product_stay']), nz(p['product_id_number']),
              sup_id.get(txt(p['product_sup_id'])), int(num(p['product_reorder'])), int(num(p['product_buy_limit'])), int(num(p['product_warning'])), R2(num(p['product_sale_price'])),
              *[(R2(num(p['product_sale_price%d' % k])) if num(p['product_sale_price%d' % k]) > 0 else None) for k in (2, 3, 4, 5)], latest_cost.get(code, 0), txt(p['product_active']) != '0', nz(p['prscdosage']))
        for col, val, tc in FLAGS:
            if txt(p[col]) == val: O.row('product_drug_types', n, tc); flag_counts[tc] += 1
        for col, tc in (('product_report11', 'ky11'), ('product_report13', 'ky13')):
            if txt(p[col]) not in ('', '0'): O.row('product_drug_types', n, tc); flag_counts[tc] += 1
    exp['products'] = n; exp['flags'] = dict(flag_counts)
    for s in T['tb_productsticker']:
        code = txt(s['product_id'])
        if code in prod_id and any(txt(s[k]) for k in ('dosage_th', 'time_th', 'comment_th', 'keep_th')):
            O.row('product_usage_templates', prod_id[code], None, nz(s['dosage_th']), nz(s['dosage_en']), nz(s['time_th']), nz(s['time_en']), nz(s['comment_th']), nz(s['comment_en']), nz(s['keep_th']), nz(s['keep_en']))

    # ---------- customers (name, phone, note, allergies only) ----------
    cus_id = {}; n = 0; na = 0
    for c in T['tb_customer']:
        if not txt(c['cus_name']): continue
        n += 1; cus_id[txt(c['cus_id'])] = n
        O.row('customers', n, nz(c['cus_id']), txt(c['cus_name']), nz(c['cus_tel']), nz(c['cus_comment']))
        for a in re.split(r'[\n,;]+', str(c['cus_druglose'] or '')):
            if a.strip() and a.strip().lower() != 'null': O.row('customer_allergies', n, a.strip(), None); na += 1
    exp['customers'] = n; exp['allergies'] = na

    # ---------- staff (no passwords) ----------
    user_name = {}; n = 0
    for u in T['tb_user']:
        lg = txt(u['login_name']).lower()
        if not lg: continue
        n += 1; nm = txt(u['user_name']) or lg; user_name[lg] = nm; user_name[txt(u['user_id']).upper()] = nm
        t0, t1 = txt(u['TimeStart'])[:8], txt(u['TimeStop'])[:8]; none = t0 in ('', '00:00:00') and t1 in ('', '00:00:00')
        O.row('staff', lg, nz(u['user_id']), nm, nz(u['CerNo']), 'ย้ายมาจากระบบเดิม', True, None if none else t0, None if none else t1)
    exp['staff'] = n

    # ---------- purchase orders ----------
    order_sup = {}; po_id = {}; n = 0
    status_map = {'Y': 'closed', 'N': 'open', 'W': 'partial'}
    for o in T['tb_order']:
        on = txt(o['order_number'])
        if not on or on in po_id: continue
        n += 1; po_id[on] = n; order_sup[on] = txt(o['sup_id'])
        O.row('purchase_orders', n, on, sup_id.get(txt(o['sup_id'])), date(o['date_order']) or None, date(o['date_appoint_recive']) or None, date(o['date_appoint_pay']) or None, R2(num(o['must_pay'])), nz(o['docno']),
              status_map.get(txt(o['status']), 'closed'), nz(o['status']), None)
    exp['purchase_orders'] = n
    recv_by_order = collections.Counter()
    for r in T['tb_recivedetail']: recv_by_order[(txt(r['order_number']), txt(r['product_id']))] += int(num(r['value_recive']))
    npl = 0; seen_pl = set()
    for d in T['tb_orderdetail']:
        on, code = txt(d['order_number']), txt(d['pro_id'])
        if on not in po_id or code not in prod_id or int(num(d['value_order'])) <= 0 or (on, code) in seen_pl: continue
        seen_pl.add((on, code)); npl += 1
        O.row('purchase_order_lines', po_id[on], prod_id[code], int(num(d['value_order'])), R4(num(d['price'])), min(recv_by_order[(on, code)], int(num(d['value_order']))))
    exp['purchase_order_lines'] = npl

    # ---------- lots, receipts, receipt lines ----------
    lot_rows = []; lot_key = {}; lot_by_pk = collections.defaultdict(list)
    for r in lots_raw:
        code = txt(r['product_id'])
        if code not in prod_id: continue
        lot = {'id': len(lot_rows) + 1, 'code': code, 'pid': prod_id[code], 'lot_no': nz(r['produce_num']), 'exp': date(r['exp_date']) or None, 'rd': date(r['recive_date']) or '2000-01-01',
               'q_in': int(num(r['value_recive'])), 'q_left': max(int(num(r['value_now'])), 0), 'cost': R4(num(r['capacity'])), 'order': txt(r['order_id']), 'sup': sup_id.get(txt(r['sup_id'])) or sup_id.get(order_sup.get(txt(r['order_id']), '')), 'rl': None, 'sold': 0}
        lot_rows.append(lot); lot_key[(code, date(r['exp_date']) or None, lot['rd'] if date(r['recive_date']) else '2000-01-01', lot['order'])] = lot
        lot_by_pk[(code, date(r['recive_date']), txt(r['produce_num']))].append(lot); lot_by_pk[(code, txt(r['produce_num']))].append(lot)
    rc_id = {}; rl_n = 0; rc_lines = collections.defaultdict(list)
    for r in T['tb_recivedetail']:
        if txt(r['product_id']) in prod_id: rc_lines[txt(r['order_number'])].append(r)
    for on, lines in rc_lines.items():
        rid = len(rc_id) + 1; rc_id[on] = rid
        day = max(date(l['recive_date']) for l in lines) or '2000-01-01'
        sub = R2(sum(int(num(l['value_recive'])) * num(l['price_Punit']) for l in lines))
        O.row('receipts', rid, sup_id.get(txt(lines[0]['sup_id'])) or sup_id.get(order_sup.get(on, '')), on, day, po_id.get(on), sub, 0, sub, 'ok', 'ย้ายจากระบบเดิม')
        for l in lines:
            code = txt(l['product_id']); lot = lot_key.get((code, date(l['EXP_date']) or None, date(l['recive_date']) or '2000-01-01', on))
            qty = int(num(l['value_recive'])); free = int(num(l['premium']))
            if qty <= 0: continue
            rl_n += 1; uc = R4(num(l['price_Punit']))
            O.row('receipt_lines', rl_n, rid, prod_id[code], qty, free, uc, 0, uc, lot['lot_no'] if lot else None, date(l['EXP_date']) or None, lot['id'] if lot else None)
            if lot and lot['rl'] is None: lot['rl'] = rl_n
    exp['receipts'] = len(rc_id); exp['receipt_lines'] = rl_n

    # ---------- sales (all history unless --sales-days) ----------
    sales_raw = T['tb_sale']
    maxd = max(date(s['sale_date']) for s in sales_raw if date(s['sale_date']))
    cutoff = (datetime.strptime(maxd, '%Y-%m-%d') - timedelta(days=days - 1)).strftime('%Y-%m-%d') if days else '0000-00-00'
    det = collections.defaultdict(list)
    for d in T['tb_saledetail']: det[txt(d['bill_id'])].append(d)
    sale_n = 0; line_n = 0; alloc_n = 0; lines_nolot = 0; tot_sum = 0.0; sub_sum = 0.0; qty_sum = 0; mism = 0
    movements = []   # (ts, pid, lot, type, qty, ref, note, staff)
    for s in sorted(sales_raw, key=lambda s: (date(s['sale_date']), txt(s['sale_time']), txt(s['bill_id']))):
        bd = date(s['sale_date'])
        if not bd or bd < cutoff: continue
        no = txt(s['bill_id']); dl = det.get(no, [])
        if not dl: continue
        sale_n += 1
        sub = R2(sum(int(num(d['value'])) * num(d['price']) for d in dl)); disc = R2(num(s['discount'])); total = R2(num(s['Net_recive_M'], sub - disc))
        if abs(sub - disc - total) > 0.05: mism += 1
        tot_sum += total; sub_sum += sub
        who = user_name.get(txt(s['Login_name']).lower()) or user_name.get(txt(s['user_id']).upper()) or nz(s['Login_name']) or nz(s['user_id'])
        ts = bd + 'T' + (txt(s['sale_time']) or '12:00:00') + TZ
        has_rx = bool(txt(s['doc_name']))
        O.row('sales', sale_n, no, ts, bd, cus_id.get(txt(s['cus_id'])), who, sub, disc, total, 'cash', (lambda r, c: (total, 0.0) if abs(r) > 1e8 or abs(c) > 1e8 else (r, c))(R2(num(s['moneyComein'], total)), R2(num(s['moneyBack'])))[0], (lambda r, c: 0.0 if abs(r) > 1e8 or abs(c) > 1e8 else c)(R2(num(s['moneyComein'], total)), R2(num(s['moneyBack']))), 'ok',
              nz(s['cus_usename']) if has_rx else None, nz(s['cus_useaddress']) if has_rx else None, 'ผู้บริโภค' if has_rx and txt(s['cus_usename']) else None,
              nz(s['doc_name']), nz(s['doc_address']), nz(s['cus_usename']) if has_rx else None, nz(s['cus_useage']) if has_rx else None, nz(s['cus_useaddress']) if has_rx else None, True)
        for k, d in enumerate(dl, 1):
            code = txt(d['pro_id']); pid = prod_id.get(code); qty = int(num(d['value'])); price = R2(num(d['price'])); cpu = num(d['capacityPunit'])
            if qty <= 0: continue
            line_n += 1; qty_sum += qty
            pname = txt(d['product_name']) or (txt(next((p['product_bname'] for p in [] ), '')) or code)
            O.row('sale_lines', line_n, sale_n, k, pid, pname if txt(d['product_name']) else code, None, qty, price, 0, R2(qty * price), R2(qty * cpu))
            c = lot_by_pk.get((code, date(d['recive_date']), txt(d['produce_num']))) or lot_by_pk.get((code, txt(d['produce_num'])))
            lot = None
            if txt(d['produce_num']) and c: lot = c[0] if len(c) == 1 else sorted(c, key=lambda l: l['rd'])[-1]
            if lot and pid:
                alloc_n += 1; lot['sold'] += qty
                O.row('sale_line_lots', line_n, lot['id'], qty, R4(cpu)); movements.append((ts, pid, lot['id'], 'sale', -qty, no, None, who))
            else: lines_nolot += 1
    exp['sales'] = sale_n; exp['sale_lines'] = line_n; exp['sale_line_lots'] = alloc_n; exp['sales_total'] = R2(tot_sum); exp['sales_subtotal'] = R2(sub_sum); exp['sale_qty'] = qty_sum; exp['lines_without_lot'] = lines_nolot; exp['bills_total_mismatch'] = mism

    # ---------- lots + stock movements so that qty_left == sum(movements) ----------
    for lot in lot_rows:
        src_kind = 'receive' if lot['rl'] is not None else 'opening'
        O.row('lots', lot['id'], lot['pid'], lot['lot_no'], lot['exp'], lot['rd'], lot['q_in'], lot['q_left'], lot['cost'], lot['sup'], lot['rl'], src_kind)
        movements.append((lot['rd'] + 'T09:00:00' + TZ, lot['pid'], lot['id'], src_kind, lot['q_in'], None, 'ย้ายจากระบบเดิม', 'ย้ายจากระบบเดิม'))
        diff = lot['q_left'] - (lot['q_in'] - lot['sold'])
        if diff: movements.append((maxd + 'T23:59:00' + TZ, lot['pid'], lot['id'], 'adjust', diff, None, 'ปรับให้ตรงยอดคงเหลือของระบบเดิม', 'ย้ายจากระบบเดิม'))
    for m in sorted(movements, key=lambda m: m[0]): O.row('stock_movements', *m)
    exp['lots'] = len(lot_rows); exp['stock_units'] = sum(l['q_left'] for l in lot_rows); exp['lots_in_stock'] = sum(1 for l in lot_rows if l['q_left'] > 0); exp['stock_movements'] = len(movements)

    # ---------- history tables ----------
    for d in T['tb_drawer']:
        if date(d['date']): O.row('cash_drawer_events', date(d['date']) + 'T' + (txt(d['time']) or '00:00:00') + TZ, nz(d['User_id']), nz(d['comment']))
    def dmy(v, t):
        m = re.match(r'(\d{1,2})/(\d{1,2})/(\d{4})', txt(v))
        if not m: return None
        y = int(m.group(3)); y = y - 543 if y > 2400 else y
        return '%04d-%02d-%02dT%s%s' % (y, int(m.group(2)), int(m.group(1)), txt(t) or '00:00:00', TZ)
    for u in T['tb_userhistory']:
        li = dmy(u['LoginDate'], u['LoginTime'])
        if li: O.row('login_history', txt(u['LoginName']).lower(), li, dmy(u['LogoutDate'], u['LogoutTime']))
    edit_lines = collections.defaultdict(list)
    for d in T['tb_saledetail_edit']: edit_lines[txt(d['bill_id'])].append({'product': txt(d['pro_id']), 'qty': int(num(d['value'])), 'price': num(d['price'])})
    for e in T['tb_sale_edit']:
        O.row('bill_edits', txt(e['bill_id']), date(e['date_edit']) or None, nz(e['Login_name']), nz(e['IPAddress']), R2(num(e['total_price'])), R2(num(e['discount'])), R2(num(e['Net_recive_M'])), R2(num(e['DifEdit'])), json.dumps(edit_lines.get(txt(e['bill_id']), []), ensure_ascii=False))
    tr_id = {}
    for t in T['tb_transfer_product']:
        tn = txt(t['tran_bill_id'])
        if tn and tn not in tr_id:
            tr_id[tn] = len(tr_id) + 1; O.row('stock_transfers', tr_id[tn], tn, nz(t['tran_branchid']), nz(t['tran_branchname']), date(t['tran_date']) or None, R2(num(t['tran_Total'])), nz(t['tran_officerName']))
    for t in T['tb_transfer_prodetail']:
        if txt(t['tran_bill_id']) in tr_id:
            O.row('stock_transfer_lines', tr_id[txt(t['tran_bill_id'])], nz(t['product_id']), nz(t['product_name']), int(num(t['product_value'])), R2(num(t['product_price'])), R2(num(t['total'])), date(t['exp_date']) or None, nz(t['lot']))
    for i in T['tb_interaction']: O.row('drug_interactions', nz(i['type1']), nz(i['code1']), nz(i['name1']), nz(i['type2']), nz(i['code2']), nz(i['name2']), nz(i['effect']))
    ret_id = {}
    for r in T['tb_return']:
        rn = txt(r['return_number'])
        if rn and rn not in ret_id: ret_id[rn] = len(ret_id) + 1; O.row('supplier_returns', ret_id[rn], rn, sup_id.get(txt(r['sup_id'])), date(r['return_date']) or '2000-01-01', R2(num(r['money_dept'])), 'ok')
    for d in T['tb_returndetail']:
        rn, code = txt(d['return_number']), txt(d['pro_id'])
        if rn in ret_id and code in prod_id and int(num(d['return_value'])) > 0:
            cands = [l for l in lot_rows if l['code'] == code and l['exp'] == (date(d['exp_date']) or None)]
            O.row('supplier_return_lines', ret_id[rn], prod_id[code], cands[0]['id'] if cands else None, int(num(d['return_value'])), R4(num(d['pricePunit'])))
    O.close()
    for t, k in {'interactions': 'drug_interactions', 'drawer': 'cash_drawer_events', 'logins': 'login_history', 'bill_edits': 'bill_edits', 'transfers': 'stock_transfers', 'returns': 'supplier_returns'}.items(): exp[k] = O.counts[k]

    # ---------- load.sql ----------
    order = ['categories', 'suppliers', 'products', 'product_drug_types', 'product_usage_templates', 'customers', 'customer_allergies', 'staff', 'purchase_orders', 'purchase_order_lines', 'receipts',
             'receipt_lines', 'lots', 'stock_movements', 'sales', 'sale_lines', 'sale_line_lots', 'cash_drawer_events', 'login_history', 'bill_edits', 'stock_transfers', 'stock_transfer_lines',
             'drug_interactions', 'supplier_returns', 'supplier_return_lines']
    L = ['-- generated by migrate_drgstr.py. Run with: psql DATABASE_URL -v ON_ERROR_STOP=1 -f load.sql   (from this folder)',
         'begin;', "set local session_replication_role = replica;   -- load history without firing the stock trigger (quantities are already final)",
         "update shop set " + ', '.join("%s = %s" % (k, "'" + v.replace("'", "''") + "'" if v else 'null') for k, v in shop.items()) + ' where id = 1;']
    for t in order:
        L.append("\\copy %s (%s) from '%s.tsv' with (format text)" % (t, ', '.join(cols[t]), t))
    # lots.receipt_line_id is set in the file; receipt_lines.lot_id too (lots and receipt_lines reference each other: loaded with checks off)
    for t, c in [('categories', 'id'), ('suppliers', 'id'), ('products', 'id'), ('customers', 'id'), ('purchase_orders', 'id'), ('receipts', 'id'), ('receipt_lines', 'id'), ('lots', 'id'), ('sales', 'id'), ('sale_lines', 'id'),
                 ('stock_transfers', 'id'), ('supplier_returns', 'id')]:
        L.append("select setval(pg_get_serial_sequence('%s', '%s'), coalesce((select max(%s) from %s), 1));" % (t, c, c, t))
    L += ["insert into audit_log (staff_name, entity, entity_id, action, detail) values ('migration', 'database', 'drgstr', 'import', '%s'::jsonb);" % json.dumps(exp).replace("'", "''"),
          "set local session_replication_role = origin;", 'commit;', 'analyze;']
    open(os.path.join(outdir, 'load.sql'), 'w', encoding='utf-8').write('\n'.join(L) + '\n')
    json.dump(exp, open(os.path.join(outdir, 'expected.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(json.dumps(exp, ensure_ascii=False, indent=1))

if __name__ == '__main__': main()
