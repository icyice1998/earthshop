#!/usr/bin/env python3
"""Convert a SmartDrugstore MySQL dump (Navicat export, database drgstr) into the app's JSON state.

usage: python3 -I drgstr_to_state.py DUMP.sql OUTPUT.json [--sales-days N]

- reads the dump as TEXT only (nothing is executed)
- products, lots (cost, expiry, lot no.), receipts, suppliers, customers, users, shop info are converted
- bills are converted for the last N days (default 90); older bills are NOT imported (a lot's stock level still matches)
- NOT imported: passwords, ID-card numbers, birth dates, addresses, insurance data of customers, pictures
- the output contains real customer names / phones: keep it private, never commit it
"""
import re, sys, json, collections, hashlib
from datetime import datetime, timedelta

def parse_values(s):
    rows = []; i = 0; n = len(s)
    while i < n:
        if s[i] == '(':
            i += 1; row = []
            while True:
                while s[i] == ' ': i += 1
                if s[i] == "'":
                    j = i + 1; buf = []
                    while True:
                        ch = s[j]
                        if ch == '\\': buf.append(s[j + 1]); j += 2; continue
                        if ch == "'":
                            if j + 1 < n and s[j + 1] == "'": buf.append("'"); j += 2; continue
                            break
                        buf.append(ch); j += 1
                    row.append(''.join(buf)); i = j + 1
                else:
                    j = i
                    while s[j] not in ',)': j += 1
                    v = s[i:j]; row.append(None if v == 'NULL' else v); i = j
                if s[i] == ',': i += 1; continue
                if s[i] == ')': i += 1; break
            rows.append(row)
        else: i += 1
    return rows

def load(path, wanted):
    cols = {}; rows = collections.defaultdict(list); cur = None
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            if line.startswith('CREATE TABLE'):
                cur = re.match(r'CREATE TABLE `([^`]+)`', line).group(1); cols[cur] = []; continue
            if cur and not line.startswith(')'):
                m = re.match(r'\s*`([^`]+)` ', line)
                if m: cols[cur].append(m.group(1))
                continue
            if line.startswith(')'): cur = None
            if line.startswith('INSERT INTO'):
                m = re.match(r'INSERT INTO `([^`]+)` VALUES (.*);\s*$', line)
                if m and m.group(1) in wanted:
                    for r in parse_values(m.group(2)): rows[m.group(1)].append(dict(zip(cols[m.group(1)], r)))
    return rows

def num(v, d=0.0):
    try: return float(v)
    except (TypeError, ValueError): return d
def txt(v):
    v = '' if v is None else str(v).strip()
    return '' if v.lower() == 'null' else re.sub(r'\s+', ' ', v)
def date(v):
    v = txt(v)
    return '' if (not v or v.startswith('0000')) else v[:10]
def R2(x): return round(x + 1e-9, 2)
def R4(x): return round(x + 1e-9, 4)
def uid(prefix, key): return prefix + hashlib.md5(key.encode('utf-8')).hexdigest()[:10]

def main():
    if len(sys.argv) < 3: print(__doc__); sys.exit(1)
    src, out = sys.argv[1], sys.argv[2]
    days = int(sys.argv[sys.argv.index('--sales-days') + 1]) if '--sales-days' in sys.argv else 90
    T = load(src, {'tb_product', 'tb_productall', 'tb_recivedetail', 'tb_order', 'tb_supplier', 'tb_customer', 'tb_user', 'tb_shopdetail', 'tb_sale', 'tb_saledetail', 'tb_productgroup', 'tb_uses_dosage'})
    rep = {}
    # ---------- shop
    sh = (T['tb_shopdetail'] or [{}])[0]
    settings = {'pin': '1234', 'shopName': txt(sh.get('shop_name')) or 'ร้านยา', 'nearExpiryDays': 90,
                'shopAddress': ' '.join(x for x in [txt(sh.get('shop_address')), txt(sh.get('shop_province')), txt(sh.get('shop_zip'))] if x),
                'shopPhone': txt(sh.get('shop_tel')), 'shopTaxId': txt(sh.get('shop_tax')), 'pharmacistName': txt(sh.get('doc_name')), 'licenseNo': txt(sh.get('certificate_number'))}
    # ---------- suppliers
    sup_by_id = {}; suppliers = []
    for s in T['tb_supplier']:
        nm = txt(s['sup_name'])
        if not nm: continue
        o = {'id': uid('s', s['sup_id']), 'name': nm, 'phone': txt(s['sup_tel']), 'note': ' '.join(x for x in [txt(s['sup_address']), txt(s['sup_province']), ('เลขผู้เสียภาษี ' + txt(s['sup_tax'])) if txt(s['sup_tax']) else ''] if x)}
        suppliers.append(o); sup_by_id[txt(s['sup_id'])] = o
    # ---------- lots first (to derive latest cost)
    lots_raw = T['tb_productall']
    latest_cost = {}
    for r in sorted(lots_raw, key=lambda r: date(r['recive_date'])):
        c = num(r['capacity'])
        if c > 0: latest_cost[txt(r['product_id'])] = R4(c)
    # ---------- products
    cat_names = {txt(g['group_name']) for g in T['tb_productgroup']}
    products = []; pid_of = {}
    for p in T['tb_product']:
        code = txt(p['product_id'])
        if not code: continue
        pid = 'p' + code; pid_of[code] = pid
        grp = txt(p['product_group']); cat = grp if grp and grp != '#ไม่ระบุ#' else 'อื่นๆ'
        prices = {str(n): R2(num(p['product_sale_price%d' % n])) for n in (2, 3, 4, 5) if num(p['product_sale_price%d' % n]) > 0}
        o = {'id': pid, 'code': code, 'name': txt(p['product_bname']) or code, 'generic': txt(p['product_commonname']), 'category': cat, 'unit': txt(p['product_unit_name']) or 'ชิ้น',
             'cost': latest_cost.get(code, 0), 'price': R2(num(p['product_sale_price'])), 'reorder': int(num(p['product_reorder'])), 'note': '', 'active': txt(p['product_active']) != '0',
             'barcode': txt(p['product_barcode']), 'location': txt(p['product_stay']), 'regNo': txt(p['product_id_number']),
             'supplier': (sup_by_id.get(txt(p['product_sup_id'])) or {}).get('name', ''), 'expWarnDays': int(num(p['product_warning'])), 'orderQty': int(num(p['product_buy_limit'])),
             'usage': txt(p['prscdosage']), 'type': 'sell',
             'danger': txt(p['product_danger']) == '1', 'controlled': txt(p['product_eff']) == '1', 'otc': txt(p['product_OTC_Drug']) == '1', 'offsys': txt(p['drugout']) == '1',
             'autolabel': txt(p['printauto']) == '1', 'ky9n': txt(p['Report9N']) == '1', 'ky11': txt(p['product_report11']) not in ('', '0'), 'ky13': txt(p['product_report13']) not in ('', '0')}
        if prices: o['prices'] = prices
        products.append(o)
    prod_by_id = {p['id']: p for p in products}
    # ---------- receipts + lots + movements
    order_sup = {txt(o['order_number']): txt(o['sup_id']) for o in T['tb_order']}
    lots = []; lot_key = {}; lot_by_pk = collections.defaultdict(list)
    for r in lots_raw:
        code = txt(r['product_id'])
        if code not in pid_of: continue
        rd = date(r['recive_date']); ex = date(r['exp_date'])
        lid = uid('L', '|'.join([code, ex, rd, txt(r['order_id']), txt(r['produce_num'])]))
        q_in, q_now = int(num(r['value_recive'])), int(num(r['value_now']))
        lot = {'id': lid, 'pid': pid_of[code], 'lotNo': txt(r['produce_num']), 'expiry': ex, 'qtyIn': q_in, 'qtyLeft': q_now, 'cost': R4(num(r['capacity'])),
               'receivedAt': (rd or '2000-01-01') + 'T09:00:00+07:00', 'source': 'receive' if txt(r['order_id']) else 'opening', '_order': txt(r['order_id']), '_rd': rd, '_ex': ex}
        lots.append(lot); lot_key[(code, ex, rd, txt(r['order_id']))] = lot
        lot_by_pk[(code, rd, txt(r['produce_num']))].append(lot)
        lot_by_pk[(code, txt(r['produce_num']))].append(lot)
    receipts = {}
    for r in T['tb_recivedetail']:
        code = txt(r['product_id']); on = txt(r['order_number'])
        if code not in pid_of: continue
        lot = lot_key.get((code, date(r['EXP_date']), date(r['recive_date']), on))
        sp = sup_by_id.get(txt(r['sup_id'])) or sup_by_id.get(order_sup.get(on, ''))
        rc = receipts.setdefault(on, {'id': uid('r', on), 'ts': (date(r['recive_date']) or '2000-01-01') + 'T09:00:00+07:00', 'day': date(r['recive_date']), 'invoice': on, 'supplier': sp['name'] if sp else '', 'supplierId': sp['id'] if sp else '', 'items': [], 'discount': 0, 'invoiceTotal': None, 'orderId': '', 'by': 'ย้ายจากระบบเดิม', 'status': 'ok'})
        p = prod_by_id[pid_of[code]]; qty = int(num(r['value_recive'])); free = int(num(r['premium'])); uc = R4(num(r['price_Punit']))
        rc['items'].append({'pid': p['id'], 'name': p['name'], 'unit': p['unit'], 'qty': qty, 'freeQty': free, 'unitCost': uc, 'lineDiscount': 0, 'effCost': uc, 'lotNo': lot['lotNo'] if lot else '', 'expiry': date(r['EXP_date']), 'lotId': lot['id'] if lot else ''})
        if lot: lot['_rc'] = rc['id']
    for rc in receipts.values():
        rc['subtotal'] = R2(sum(i['qty'] * i['unitCost'] for i in rc['items'])); rc['total'] = rc['subtotal']
    # ---------- members
    members = []; mem_of = {}
    for i, c in enumerate(T['tb_customer']):
        nm = txt(c['cus_name'])
        if not nm: continue
        al = [x.strip() for x in re.split(r'[\n,;]+', str(c['cus_druglose'] or '')) if x.strip() and x.strip().lower() != 'null']
        m = {'id': uid('m', c['cus_id']), 'code': txt(c['cus_id']), 'name': nm, 'phone': txt(c['cus_tel']), 'allergies': [{'drug': a, 'reaction': ''} for a in al], 'note': txt(c['cus_comment']), 'createdAt': datetime.utcnow().isoformat() + 'Z', 'by': 'ย้ายจากระบบเดิม'}
        members.append(m); mem_of[txt(c['cus_id'])] = m['id']
    # ---------- users (no passwords, no permissions guessed)
    users = []; user_name = {}
    cashier = None
    for u in T['tb_user']:
        lg = txt(u['login_name']).lower()
        if not lg: continue
        user_name[txt(u['user_id']).upper()] = txt(u['user_name']) or lg; user_name[lg] = txt(u['user_name']) or lg
        t0, t1 = txt(u['TimeStart'])[:5], txt(u['TimeStop'])[:5]
        users.append({'id': uid('u', lg), 'empId': txt(u['user_id']), 'name': txt(u['user_name']) or lg, 'login': lg, 'role': 'ย้ายมา (กำหนดสิทธิ์ใหม่)', 'active': True, 'admin': False,
                      'workStart': '' if t0 in ('', '00:00') and t1 in ('', '00:00') else t0, 'workEnd': '' if t0 in ('', '00:00') and t1 in ('', '00:00') else t1,
                      'perms': {'pos': True, 'members': True, 'billsView': True, 'sellOtc': True}})
    # ---------- sales (last N days)
    sales_raw = T['tb_sale']
    maxd = max(date(s['sale_date']) for s in sales_raw if date(s['sale_date']))
    cutoff = (datetime.strptime(maxd, '%Y-%m-%d') - timedelta(days=days - 1)).strftime('%Y-%m-%d')
    det = collections.defaultdict(list)
    for d in T['tb_saledetail']: det[txt(d['bill_id'])].append(d)
    sales = []; movements = []; unmatched = 0; lines_n = 0; sale_alloc_qty = collections.Counter(); sql_tot = 0.0; app_tot = 0.0; bad_tot = 0
    for s in sales_raw:
        bd = date(s['sale_date'])
        if not bd or bd < cutoff: continue
        no = txt(s['bill_id']); items = []
        for d in det.get(no, []):
            code = txt(d['pro_id']); p = prod_by_id.get(pid_of.get(code, ''))
            qty = int(num(d['value'])); price = R2(num(d['price'])); cpu = num(d['capacityPunit'])
            lot = None
            c = lot_by_pk.get((code, date(d['recive_date']), txt(d['produce_num']))) or lot_by_pk.get((code, txt(d['produce_num'])))
            if txt(d['produce_num']) and c: lot = c[0] if len(c) == 1 else sorted(c, key=lambda l: l['_rd'])[-1]
            it = {'pid': p['id'] if p else None, 'name': (txt(d['product_name']) or (p['name'] if p else code)), 'unit': p['unit'] if p else '', 'qty': qty, 'price': price, 'costTotal': R2(qty * cpu), 'allocs': []}
            if lot and p: it['allocs'].append({'lotId': lot['id'], 'qty': qty, 'cost': R4(cpu), 'pid': p['id']}); sale_alloc_qty[lot['id']] += qty
            else: unmatched += 1
            items.append(it); lines_n += 1
        if not items: continue
        sub = R2(sum(i['qty'] * i['price'] for i in items)); disc = R2(num(s['discount'])); total = R2(num(s['Net_recive_M'], sub - disc))
        sql_tot += total
        if abs((sub - disc) - total) > 0.05: bad_tot += 1
        tm = txt(s['sale_time']) or '12:00:00'
        who = user_name.get(txt(s['Login_name']).lower()) or user_name.get(txt(s['user_id']).upper()) or txt(s['Login_name']) or txt(s['user_id'])
        sale = {'id': uid('b', no), 'no': no, 'ts': bd + 'T' + tm + '+07:00', 'day': bd, 'items': items, 'subtotal': sub, 'discount': disc, 'total': total, 'method': 'cash', 'received': R2(num(s['moneyComein'], total)), 'change': R2(num(s['moneyBack'])),
                'status': 'ok', 'by': who, 'backdated': False, 'noStock': False, 'imported': True, 'memberId': mem_of.get(txt(s['cus_id']), '')}
        if txt(s['doc_name']):
            sale['rx'] = {'doc': txt(s['doc_name']), 'docAddr': txt(s['doc_address']), 'user': txt(s['cus_usename']), 'age': txt(s['cus_useage']), 'addr': txt(s['cus_useaddress'])}
            if txt(s['cus_usename']): sale['buyer'] = {'name': txt(s['cus_usename']), 'addr': txt(s['cus_useaddress']), 'type': 'ผู้บริโภค'}
        sales.append(sale); app_tot += total
    sales.sort(key=lambda x: x['ts'])
    # ---------- movements so that qtyLeft == sum(movements) for every lot
    sale_by_no = {s['no']: s for s in sales}
    mv = []
    for lot in lots:
        kind = 'receive' if lot.get('_rc') else 'opening'
        mv.append({'id': uid('v', lot['id'] + 'in'), 'ts': lot['receivedAt'], 'pid': lot['pid'], 'type': kind, 'qty': lot['qtyIn'], 'lotId': lot['id'], 'ref': '', 'note': 'ย้ายจากระบบเดิม', 'by': 'ย้ายจากระบบเดิม'})
    for s in sales:
        for it in s['items']:
            for a in it['allocs']:
                mv.append({'id': uid('v', s['no'] + a['lotId']), 'ts': s['ts'], 'pid': a['pid'], 'type': 'sale', 'qty': -a['qty'], 'lotId': a['lotId'], 'ref': s['no'], 'note': '', 'by': s['by']})
    sums = collections.Counter()
    for m in mv: sums[m['lotId']] += m['qty']
    for lot in lots:
        diff = lot['qtyLeft'] - sums[lot['id']]
        if diff:
            mv.append({'id': uid('v', lot['id'] + 'fix'), 'ts': (maxd or '2026-01-01') + 'T23:59:00+07:00', 'pid': lot['pid'], 'type': 'adjust', 'qty': diff, 'lotId': lot['id'], 'ref': '', 'note': 'ปรับให้ตรงยอดคงเหลือของระบบเดิม', 'by': 'ย้ายจากระบบเดิม'})
    mv.sort(key=lambda m: m['ts'])
    for lot in lots:
        for k in [k for k in lot if k.startswith('_')]: del lot[k]
    state = {'products': products, 'lots': lots, 'movements': mv, 'sales': sales, 'receipts': sorted(receipts.values(), key=lambda r: r['ts']), 'returns': [], 'issues': [], 'closings': [], 'orders': [], 'members': members, 'memberNotes': [], 'followups': [],
             'suppliers': suppliers, 'users': users, 'seq': {'sale': 0, 'ret': 0, 'mem': len(members), 'po': 0}, 'settings': settings}
    json.dump(state, open(out, 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))
    # ---------- self-check report
    mvs = collections.Counter()
    for m in mv: mvs[m['lotId']] += m['qty']
    bad_lots = sum(1 for l in lots if mvs[l['id']] != l['qtyLeft'])
    stock_sql = sum(int(num(r['value_now'])) for r in lots_raw)
    stock_app = sum(l['qtyLeft'] for l in lots)
    print(json.dumps({'products': len(products), 'lots': len(lots), 'lots_in_stock': sum(1 for l in lots if l['qtyLeft'] > 0), 'receipts': len(receipts), 'suppliers': len(suppliers), 'members': len(members), 'users': len(users),
        'sales_window': {'from': cutoff, 'to': maxd, 'bills': len(sales), 'lines': lines_n, 'lines_without_lot': unmatched, 'total_app': R2(app_tot), 'bills_total_mismatch': bad_tot},
        'stock_units': {'sql': stock_sql, 'app': stock_app}, 'lots_movement_mismatch': bad_lots, 'movements': len(mv), 'size_mb': round(len(json.dumps(state, ensure_ascii=False)) / 1e6, 2)}, ensure_ascii=False, indent=1))

if __name__ == '__main__': main()
