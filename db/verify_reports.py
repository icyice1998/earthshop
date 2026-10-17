"""Recompute report numbers from the migration TSV files (independent of SQL) and compare with the SQL report functions.
Usage: python3 -I verify_reports.py OUTDIR   (database 'pharm' on the local test server)"""
import sys, subprocess, csv, collections, decimal, re
D = decimal.Decimal
out = sys.argv[1]
def rows(name):
    with open(f'{out}/{name}.tsv', encoding='utf-8') as f:
        for ln in f:
            yield [None if x == '\\N' else x for x in ln.rstrip('\n').split('\t')]
def q(sql):
    r = subprocess.run(['psql', '-h', '/tmp/pgtest', '-p', '55432', '-U', 'postgres', '-d', 'pharm', '-AtF|', '-c', sql], capture_output=True, text=True)
    if r.returncode: raise SystemExit(r.stderr)
    return [l.split('|') for l in r.stdout.strip().split('\n') if l]
def r2(x): return D(x).quantize(D('0.01'), rounding=decimal.ROUND_HALF_UP)
sales = {r[0]: r for r in rows('sales')}
flags = collections.defaultdict(set)
for pid, code in rows('product_drug_types'): flags[pid].add(code)
agg = {'month': collections.defaultdict(lambda: [set(), 0, D(0), D(0)]), 'staff': collections.defaultdict(lambda: [set(), 0, D(0), D(0)]), 'flag': collections.defaultdict(lambda: [set(), 0, D(0), D(0)])}
for r in rows('sale_lines'):
    s = sales[r[1]]
    if s[12] != 'ok': continue
    sub, tot = D(s[6]), D(s[8])
    rev = r2(D(r[6]) * D(r[7]) * (tot / sub if sub > 0 else 1)); cost = r2(D(r[10]))
    ks = {'month': [s[3][:7]], 'staff': [s[5] or '-'], 'flag': sorted(flags[r[3]]) or ['none']}
    for g, keys in ks.items():
        for k in keys:
            a = agg[g][k]; a[0].add(r[1]); a[1] += int(r[6]); a[2] += rev; a[3] += cost
bad = 0
for g in agg:
    sql = {x[0]: x for x in q(f"select key,bills,qty,sales,cost from report_sales('2000-01-01','2100-01-01','{g}') where key<>'__total'")}
    for k, a in agg[g].items():
        x = sql.get(k)
        ok = x and int(x[1]) == len(a[0]) and int(x[2]) == a[1] and abs(D(x[3]) - a[2]) < D('0.005') and abs(D(x[4]) - a[3]) < D('0.005')
        if not ok: bad += 1; print('DIFF', g, k, x, [len(a[0]), a[1], a[2], a[3]])
    if len(sql) != len(agg[g]): bad += 1; print('DIFF key count', g, len(sql), len(agg[g]))
    print(f'{g:6} {len(agg[g]):4} groups checked')
# ข.ย.9: every non-void receipt line of a non-supply product
n9 = q("select count(*) from report_ky9('2000-01-01','2100-01-01')")[0][0]
print('ky9 rows', n9)
# ข.ย.10/11: sale rows and running remain per lot
mv = collections.defaultdict(list)
for r in rows('stock_movements'): mv[r[2]].append(r)
lots_by_prod = collections.defaultdict(list)
for r in rows('lots'): lots_by_prod[r[1]].append(r[0])
for form, code in (('10', 'controlled'), ('11', 'ky11')):
    pids = [p for p, f in flags.items() if code in f]
    lots = {l for p in pids for l in lots_by_prod[p]}
    nsale = 0
    sl = {r[0]: r for r in rows('sale_lines')}
    for r in rows('sale_line_lots'):
        if r[1] in lots and sales[sl[r[0]][1]][12] == 'ok': nsale += 1
    got = q(f"select count(*) filter (where row_no>0) from report_ky_lots('{form}','2000-01-01','2100-01-01')")[0][0]
    ok = int(got) == nsale; bad += not ok
    print(f'ky{form} sale rows: python {nsale} sql {got}', 'ok' if ok else 'DIFF')
    # remain after each sale = running sum of movements at that sale (timestamps then id order)
    run = {}
    for l in lots:
        s = 0
        for m in sorted(mv[l], key=lambda m: (m[0], )):  # file order = id order
            s += int(m[4]); run[(l, m[5])] = s
    sqlr = q(f"select lot_id, bill_no, regexp_replace(remain, ' .*', '') from report_ky_lots('{form}','2000-01-01','2100-01-01') where row_no>0")
    wrong = [x for x in sqlr if (x[0], x[1]) in run and int(x[2]) != run[(x[0], x[1])]]
    print(f'ky{form} remain mismatches vs python:', len(wrong)); bad += len(wrong) > 0
print('RESULT', 'FAIL' if bad else 'OK'); sys.exit(1 if bad else 0)
