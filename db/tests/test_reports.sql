-- Report and ข.ย. form tests on a small fixture. Run on a freshly created database with 01-04 applied (ids are assumed to start at 1). Rolls back.
\set ON_ERROR_STOP on
begin;
create schema tst;
grant usage on schema tst to public;
create or replace function tst.expect(cond boolean, msg text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok  - %', msg; end $$;
create or replace function tst.expect_error(stmt text, frag text, msg text) returns void language plpgsql as $$
begin
  begin execute stmt; exception when others then
    if sqlerrm like '%' || frag || '%' then raise notice 'ok  - %', msg; return; end if;
    raise exception 'FAILED: % (wrong error: %)', msg, sqlerrm;
  end;
  raise exception 'FAILED: % (no error raised)', msg;
end $$;

insert into categories (name) values ('ยาแก้ปวด');
insert into suppliers (name) values ('ซัพพลายเออร์ A');
insert into products (code, name, unit, price1, latest_cost, category_id, manufacturer, pack_size) values
  ('A','พาราเซตามอล','แผง',20,8,1,null,null), ('K','ยา ขย.11','ขวด',100,60,1,'ผู้ผลิต X','100 มล.');
insert into product_drug_types select id, 'ky11' from products where code = 'K';
insert into receipts (supplier_id, invoice_no, received_on, subtotal, total) values (1, 'INV1', '2026-01-05', 600, 600);
insert into lots (product_id, lot_no, received_on, qty_in, qty_left, unit_cost, supplier_id, source) select id, 'L1', '2026-01-05', 10, 7, 60, 1, 'receive' from products where code = 'K';
insert into receipt_lines (receipt_id, product_id, qty, unit_cost, eff_cost, lot_no, lot_id) select 1, product_id, 10, 60, 60, 'L1', id from lots;
update lots set receipt_line_id = 1;
insert into stock_movements (ts, product_id, lot_id, type, qty, ref_no) select '2026-01-05 09:00+07', product_id, id, 'receive', 10, 'INV1' from lots;
-- bill 1: K x2 + A x1, bill discount 10% (subtotal 220, total 198), rx data
insert into sales (bill_no, ts, sale_date, staff_name, subtotal, discount, total, method, buyer_name, buyer_addr, rx_prescriber, rx_prescriber_addr, rx_user, rx_user_age, rx_user_addr)
  values ('B1', '2026-01-10 10:30+07', '2026-01-10', 'ann', 220, 22, 198, 'cash', 'สมชาย', '1 ถ.ก', 'นพ.ดี', 'รพ.ก', 'สมชาย', '40', '1 ถ.ก');
insert into sale_lines (sale_id, line_no, product_id, name, unit, qty, unit_price, line_total, cost_total) values
  (1, 1, (select id from products where code='K'), 'ยา ขย.11', 'ขวด', 2, 100, 200, 120), (1, 2, (select id from products where code='A'), 'พาราเซตามอล', 'แผง', 1, 20, 20, 8);
insert into sale_line_lots values (1, 1, 2, 60);
insert into stock_movements (ts, product_id, lot_id, type, qty, ref_no) values ('2026-01-10 10:30+07', (select id from products where code='K'), 1, 'sale', -2, 'B1');
-- bill 2: void, must be ignored
insert into sales (bill_no, ts, sale_date, staff_name, subtotal, total, status) values ('B2', '2026-01-11 11:00+07', '2026-01-11', 'ann', 100, 100, 'void');
insert into sale_lines (sale_id, line_no, product_id, name, unit, qty, unit_price, line_total) values (2, 1, (select id from products where code='K'), 'ยา ขย.11', 'ขวด', 1, 100, 100);
-- bill 3: other income line (no product), another staff
insert into sales (bill_no, ts, sale_date, staff_name, subtotal, total, method) values ('B3', '2026-01-12 15:05+07', '2026-01-12', 'bob', 50, 50, 'transfer');
insert into sale_lines (sale_id, line_no, product_id, name, qty, unit_price, line_total) values (3, 1, null, 'ค่าบริการ', 1, 50, 50);

select tst.expect((select sales from report_sales('2026-01-01','2026-02-01','all') where key='__total') = 248.00, 'total = 198 (discounted) + 50, void bill ignored');
select tst.expect((select sales from report_sales('2026-01-01','2026-02-01','all') where key='__total') = 180 + 18 + 50, 'discount is spread proportionally over lines');
select tst.expect((select profit from report_sales('2026-01-01','2026-02-01','all') where key='__total') = 248 - 128, 'profit = sales - cost');
select tst.expect((select bills from report_sales('2026-01-01','2026-02-01','all') where key='__total') = 2, 'two bills counted');
select tst.expect((select sales from report_sales('2026-01-01','2026-02-01','staff') where key='bob') = 50, 'by staff');
select tst.expect((select sales from report_sales('2026-01-01','2026-02-01','method') where key='transfer') = 50, 'by method');
select tst.expect((select sales from report_sales('2026-01-01','2026-02-01','category') where key='รายรับอื่น') = 50, 'other income category');
select tst.expect((select label from report_sales('2026-01-01','2026-02-01','hour') where key='10') = '10:00 - 10:59', 'by hour (Bangkok time)');
select tst.expect((select sales from report_sales('2026-01-01','2026-02-01','flag') where key='ky11') = 180, 'by drug type ky11');
select tst.expect((select sales from report_sales('2026-01-01','2026-02-01','day', p_flag => 'none') where key='__total') = 18 + 50, 'filter: no special type');
select tst.expect((select qty from report_sales('2026-01-01','2026-02-01','all', p_q => 'ขย') where key='__total') = 2, 'text filter');
select tst.expect((select count(*) from report_sales('2026-02-01','2026-03-01','month')) = 1, 'empty period returns only the total row');

select tst.expect((select count(*) from report_ky9('2026-01-01','2026-01-31')) = 1 and (select qty from report_ky9('2026-01-01','2026-01-31')) = '10 ขวด', 'ky9 lists the receipt');
select tst.expect((select count(*) from report_ky9('2026-02-01','2026-02-28')) = 0, 'ky9 respects the period');
select tst.expect((select drugs from report_ky12('2026-01-01','2026-01-31')) = 'ยา ขย.11 2 ขวด, พาราเซตามอล 1 แผง', 'ky12 lists the prescription bill and drugs');
select tst.expect((select count(*) from report_ky12('2026-01-11','2026-01-31')) = 0, 'ky12 respects the period');
select tst.expect((select count(*) from report_ky_lots('11','2026-01-01','2026-01-31')) = 1, 'ky11: one lot, one sale row (void bill not included)');
select tst.expect((select remain from report_ky_lots('11','2026-01-01','2026-01-31')) = '8 ขวด', 'ky11 remaining after the sale = 10 - 2');
select tst.expect((select buyer from report_ky_lots('11','2026-01-01','2026-01-31')) = 'สมชาย', 'ky11 buyer name');
select tst.expect((select row_no from report_ky_lots('11','2026-02-01','2026-02-28')) is null, 'ky11: lot without sales in a later period and received earlier is not listed');
select tst.expect((select count(*) from report_ky_lots('10','2026-01-01','2026-01-31')) = 0, 'ky10: no controlled drugs, no pages');

-- permissions
select set_config('u.cash', gen_random_uuid()::text, false), set_config('u.phr', gen_random_uuid()::text, false), set_config('u.adm', gen_random_uuid()::text, false);
insert into staff (auth_user_id, login, display_name, is_admin) values (current_setting('u.adm')::uuid, 'adm', 'admin', true);
insert into staff (auth_user_id, login, display_name) values (current_setting('u.cash')::uuid, 'cash', 'cashier'), (current_setting('u.phr')::uuid, 'phr', 'pharm');
insert into staff_permissions select id, x from staff, unnest(array['pos','billsView']) x where login = 'cash';
insert into staff_permissions select id, x from staff, unnest(array['reports','forms']) x where login = 'phr';
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('u.cash'))::text, false);
select tst.expect_error($q$select * from report_sales('2026-01-01','2026-02-01','day')$q$, 'ไม่มีสิทธิ์', 'cashier cannot run sales reports');
select tst.expect_error($q$select * from report_ky9('2026-01-01','2026-02-01')$q$, 'ไม่มีสิทธิ์', 'cashier cannot run ข.ย. forms');
select set_config('request.jwt.claims', json_build_object('sub', current_setting('u.phr'))::text, false);
select tst.expect((select sales from report_sales('2026-01-01','2026-02-01','all') where key='__total') = 248 and (select cost is null and profit is null from report_sales('2026-01-01','2026-02-01','all') where key='__total'), 'without viewCost the report hides cost and profit');
select tst.expect((select count(*) from report_ky_lots('11','2026-01-01','2026-01-31')) = 1, 'forms right can run ข.ย. forms');
reset role;
rollback;
