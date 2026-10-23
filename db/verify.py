import json,subprocess,sys
exp=json.load(open(sys.argv[1]+'/expected.json'))
def q(sql):
    return subprocess.run(['psql','-h','/tmp/pgtest','-p','55432','-U','postgres','-d','pharm','-Atc',sql],capture_output=True,text=True).stdout.strip()
Q={'sales':'select count(*) from sales','sale_lines':'select count(*) from sale_lines','sale_line_lots':'select count(*) from sale_line_lots',
'sales_total':"select coalesce(sum(total),0) from sales where status='ok'",'sale_qty':'select sum(qty) from sale_lines',
'lots':'select count(*) from lots','stock_units':'select sum(qty_left) from lots','lots_in_stock':'select count(*) from lots where qty_left>0',
'stock_movements':'select count(*) from stock_movements','receipts':'select count(*) from receipts','receipt_lines':'select count(*) from receipt_lines',
'purchase_orders':'select count(*) from purchase_orders','purchase_order_lines':'select count(*) from purchase_order_lines','customers':'select count(*) from customers',
'staff':'select count(*) from staff','drug_interactions':'select count(*) from drug_interactions','cash_drawer_events':'select count(*) from cash_drawer_events',
'login_history':'select count(*) from login_history','bill_edits':'select count(*) from bill_edits','stock_transfers':'select count(*) from stock_transfers','supplier_returns':'select count(*) from supplier_returns'}
bad=0
for k,sql in Q.items():
    g=float(q(sql) or 0); e=float(exp.get(k,0))
    ok=abs(g-e)<0.5; bad+=not ok
    print(f"{k:22}{e:>14.2f}{g:>14.2f}  {'ok' if ok else 'DIFF'}")
print('invariant lots vs movements:',q("select count(*) from lots l where qty_left <> coalesce((select sum(qty) from stock_movements m where m.lot_id=l.id),0)"))
sys.exit(bad)
