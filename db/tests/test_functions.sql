-- Self-checking tests for the business functions. Runs inside a transaction and rolls back.
-- usage: psql -v ON_ERROR_STOP=1 -d DB -f tests/test_functions.sql
\set ON_ERROR_STOP on
begin;
create or replace function pg_temp.expect(cond boolean, msg text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok  - %', msg; end $$;
create or replace function pg_temp.expect_error(stmt text, frag text, msg text) returns void language plpgsql as $$
begin
  begin execute stmt; exception when others then
    if sqlerrm like '%' || frag || '%' then raise notice 'ok  - % (%)', msg, sqlerrm; return; end if;
    raise exception 'FAILED: % (wrong error: %)', msg, sqlerrm;
  end;
  raise exception 'FAILED: % (no error raised)', msg;
end $$;

-- fixtures (service role = superuser here)
insert into suppliers (name) values ('บ.ทดสอบ');
insert into products (code, name, unit, price1, latest_cost) values ('T1', 'ยาทดสอบ A', 'แผง', 30, 0), ('T2', 'ยาทดสอบ B', 'ขวด', 50, 0), ('KIT', 'ชุดทดสอบ', 'ชุด', 10, 0), ('RX', 'ยาควบคุมทดสอบ', 'แผง', 100, 0), ('BAN', 'ยาห้ามขาย', 'แผง', 5, 0);
insert into product_bundles (bundle_id, part_id, qty) select (select id from products where code='KIT'), id, 1 from products where code in ('T1','T2');
insert into product_drug_types select id, 'controlled' from products where code='RX';
insert into product_drug_types select id, 'banned' from products where code='BAN';
select set_config('t.a', (select id::text from products where code='T1'), true), set_config('t.b', (select id::text from products where code='T2'), true), set_config('t.kit', (select id::text from products where code='KIT'), true),
       set_config('t.rx', (select id::text from products where code='RX'), true), set_config('t.ban', (select id::text from products where code='BAN'), true);

-- 1. receiving with free goods and a bill discount
select receive_goods(jsonb_build_object('supplier_name','บ.ทดสอบ','invoice_no','INV-1','received_on','2026-10-01','discount',10,'invoice_total',90,
  'items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.a')::bigint, 'qty',10,'free_qty',2,'unit_cost',10,'lot_no','L1','exp_date','2027-12-31')))) as rc \gset
select pg_temp.expect((select qty_in = 12 and qty_left = 12 and unit_cost = 7.5 from lots where product_id = current_setting('t.a')::bigint), 'lot has 12 units at cost 7.50 (free goods + discount spread)');
select pg_temp.expect((select total = 90 and subtotal = 100 and discount = 10 from receipts where id = :rc), 'receipt subtotal 100, discount 10, total 90');
select pg_temp.expect((select latest_cost = 7.5 from products where id = current_setting('t.a')::bigint), 'product latest_cost updated to 7.50');
select pg_temp.expect_error($q$select receive_goods('{"supplier_name":"บ.ทดสอบ","invoice_no":" inv-1 ","items":[{"product_id":1,"qty":1}]}'::jsonb)$q$, 'เคยรับเข้าแล้ว', 'duplicate invoice is refused (case / space insensitive)');
-- second lot with a nearer expiry
select receive_goods(jsonb_build_object('supplier_name','บ.ทดสอบ','invoice_no','INV-2','received_on','2026-10-02',
  'items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.a')::bigint, 'qty',5,'unit_cost',9,'lot_no','L2','exp_date','2026-12-31'),
                             jsonb_build_object('product_id', current_setting('t.b')::bigint, 'qty',20,'unit_cost',20,'lot_no','B1','exp_date','2028-01-01')))) as rc2 \gset

-- 2. selling takes the earliest expiry first
select commit_sale(jsonb_build_object('method','cash','received',500,'items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.a')::bigint,'qty',7,'price',30)))) as s1 \gset
select pg_temp.expect((select qty_left = 0 from lots where lot_no = 'L2'), 'FEFO: nearer-expiry lot L2 (5) emptied first');
select pg_temp.expect((select qty_left = 10 from lots where lot_no = 'L1'), 'FEFO: remaining 2 taken from L1 (12 -> 10)');
select pg_temp.expect((select cost_total = round(5*9 + 2*7.5, 2) from sale_lines where sale_id = :s1), 'cost of goods sold uses the real lot costs (60.00)');
select pg_temp.expect((select total = 210 and change_amount = 290 from sales where id = :s1), 'bill total 210, change 290');
select pg_temp.expect((select count(*) = 2 from sale_line_lots sll join sale_lines sl on sl.id = sll.sale_line_id where sl.sale_id = :s1), 'two lot allocations stored');
select pg_temp.expect_error($q$select commit_sale(jsonb_build_object('method','cash','received',10,'items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.a')::bigint,'qty',1,'price',30))))$q$, 'รับเงินไม่พอ', 'cash short is refused');
select pg_temp.expect_error($q$select commit_sale(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.a')::bigint,'qty',999,'price',30))))$q$, 'สต็อกไม่พอ', 'selling more than stock is refused');
select pg_temp.expect_error($q$select commit_sale(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.ban')::bigint,'qty',1,'price',5))))$q$, 'ยาห้ามขาย', 'banned drug cannot be sold');
select pg_temp.expect((select app.stock_of(current_setting('t.a')::bigint)) = 10, 'stock_of = 10');

-- 3. kit (bundle) deducts every part
select commit_sale(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.kit')::bigint,'qty',2,'price',10)))) as s2 \gset
select pg_temp.expect((select app.stock_of(current_setting('t.a')::bigint)) = 8 and (select app.stock_of(current_setting('t.b')::bigint)) = 18, 'selling 2 kits takes 2 of each part');
select pg_temp.expect((select app.stock_of(current_setting('t.kit')::bigint)) = 8, 'kit stock = min of parts (8)');

-- 4. void returns stock to the same lots
select void_sale(:s1, 'test');
select pg_temp.expect((select qty_left = 5 from lots where lot_no = 'L2') and (select qty_left = 10 - 2 + 2 from lots where lot_no = 'L1'), 'void puts stock back into the original lots');
select pg_temp.expect_error($q$select void_sale((select max(id) from sales where status = 'void'))$q$, 'ยกเลิกไปแล้ว', 'a bill cannot be voided twice');

-- 5. buyer rules for controlled drugs and prescriptions
select receive_goods(jsonb_build_object('supplier_name','บ.ทดสอบ','invoice_no','INV-3','items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.rx')::bigint,'qty',10,'unit_cost',60,'lot_no','R1','exp_date','2027-06-01')))) as rc3 \gset
select pg_temp.expect_error($q$select commit_sale(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.rx')::bigint,'qty',1,'price',100))))$q$, 'ผู้ซื้อ', 'controlled drug needs a buyer name');
select commit_sale(jsonb_build_object('buyer', jsonb_build_object('name','คุณทดสอบ','addr','1 ถนน'), 'rx', jsonb_build_object('doc','นพ.ทดสอบ','user','คุณทดสอบ','age','40'),
  'items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.rx')::bigint,'qty',2,'price',100)))) as s3 \gset
select pg_temp.expect((select buyer_name = 'คุณทดสอบ' and rx_prescriber = 'นพ.ทดสอบ' and rx_user_age = '40' from sales where id = :s3), 'buyer and prescription (ข.ย.12) data stored on the bill');

-- 6. adjustments
select adjust_stock(current_setting('t.a')::bigint, 20, 'นับสต็อกไม่ตรง') as d1 \gset
select pg_temp.expect(:d1 = 5 and app.stock_of(current_setting('t.a')::bigint) = 20, 'adjust up from 15 to 20 creates a new lot (+5)');
select adjust_stock(current_setting('t.a')::bigint, 3, 'ยาเสียหาย') as d2 \gset
select pg_temp.expect(:d2 = -17 and app.stock_of(current_setting('t.a')::bigint) = 3, 'adjust down takes FEFO (-17)');
select adjust_lot_cost((select id from lots where lot_no = 'L1'), 8.25);
select pg_temp.expect((select unit_cost = 8.25 from lots where lot_no = 'L1'), 'lot cost corrected without touching quantity');

-- 7. a receipt can be voided only while untouched
select pg_temp.expect_error(format('select void_receipt(%s)', :rc), 'ถูกขายหรือใช้ไป', 'receipt with sold stock cannot be voided');
select receive_goods(jsonb_build_object('supplier_name','บ.ทดสอบ','invoice_no','INV-6','items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.b')::bigint,'qty',3,'unit_cost',20,'lot_no','B9')))) as rc6 \gset
select void_receipt(:rc6, 'คีย์ผิด');
select pg_temp.expect((select status = 'void' from receipts where id = :rc6) and (select qty_left = 0 from lots where lot_no = 'B9'), 'untouched receipt voided and its stock removed');
select pg_temp.expect_error(format('select void_receipt(%s)', :rc3), 'ถูกขายหรือใช้ไป', 'a receipt whose stock was partly sold cannot be voided (controlled lot R1)');

-- 8. purchase order flow
select create_purchase_order(jsonb_build_object('supplier_name','บ.ทดสอบ','items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.a')::bigint,'qty',10,'unit_cost',9), jsonb_build_object('product_id', current_setting('t.b')::bigint,'qty',5,'unit_cost',20)))) as po \gset
select pg_temp.expect((select status = 'open' from purchase_orders where id = :po), 'new order is open');
select receive_goods(jsonb_build_object('supplier_name','บ.ทดสอบ','invoice_no','INV-4','po_id',:po,'items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.a')::bigint,'qty',10,'unit_cost',9)))) as rc4 \gset
select pg_temp.expect((select status = 'partial' from purchase_orders where id = :po), 'order is partial after receiving one line');
select receive_goods(jsonb_build_object('supplier_name','บ.ทดสอบ','invoice_no','INV-5','po_id',:po,'items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.b')::bigint,'qty',5,'unit_cost',20)))) as rc5 \gset
select pg_temp.expect((select status = 'closed' from purchase_orders where id = :po), 'order is closed when everything arrived');
select void_receipt(:rc5, 'x');
select pg_temp.expect((select status = 'partial' from purchase_orders where id = :po), 'voiding a receipt reopens the order to partial');

-- 9. THE invariant: qty_left equals the sum of the movements for every lot
select pg_temp.expect((select count(*) = 0 from lots l left join (select lot_id, sum(qty) q from stock_movements group by lot_id) m on m.lot_id = l.id where l.qty_left <> coalesce(m.q, 0)), 'every lot: qty_left = sum of its movements');
select pg_temp.expect((select count(*) = 0 from lots where qty_left < 0), 'no negative stock');
rollback;
