-- Security tests: act as different logged-in users. Rolls back at the end.
\set ON_ERROR_STOP on
begin;
create schema tst;
grant usage on schema tst to public;
create or replace function tst.expect(cond boolean, msg text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok  - %', msg; end $$;
create or replace function tst.expect_error(stmt text, frag text, msg text) returns void language plpgsql as $$
begin
  begin execute stmt; exception when others then
    if sqlerrm like '%' || frag || '%' then raise notice 'ok  - % (%)', msg, left(sqlerrm, 70); return; end if;
    raise exception 'FAILED: % (wrong error: %)', msg, sqlerrm;
  end;
  raise exception 'FAILED: % (no error raised)', msg;
end $$;

-- fixtures as the service owner
insert into products (code, name, unit, price1, latest_cost) values ('S1','ยาสามัญ','แผง',20,8), ('D1','ยาอันตราย','แผง',90,40);
insert into product_drug_types select id, 'danger' from products where code = 'D1';
select set_config('t.s1', (select id::text from products where code='S1'), false), set_config('t.d1', (select id::text from products where code='D1'), false);
insert into lots (product_id, received_on, qty_in, qty_left, unit_cost, source) select id, current_date, 10, 0, 8, 'opening' from products where code in ('S1','D1');
insert into stock_movements (product_id, lot_id, type, qty) select product_id, id, 'opening', 10 from lots;
select set_config('u.admin',   gen_random_uuid()::text, false), set_config('u.cashier', gen_random_uuid()::text, false), set_config('u.pharm', gen_random_uuid()::text, false),
       set_config('u.off',     gen_random_uuid()::text, false), set_config('u.nobody',  gen_random_uuid()::text, false);

-- open mode: no admin exists yet, any logged-in user has full rights
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('u.nobody'))::text, false);
select tst.expect(app.open_mode(), 'before any admin exists the system is in open mode');
select tst.expect_error('select count(*) from products', 'permission denied', 'a logged-in user cannot read a table directly');
select tst.expect_error('select count(*) from sales', 'permission denied', 'cannot read sales table directly');
select tst.expect_error('update products set price1 = 1', 'permission denied', 'cannot write a table directly');
select tst.expect((select count(*) from v_products) = 2, 'open mode: can read the product view');
reset role;

-- set up staff
insert into staff (auth_user_id, login, display_name, is_admin) values (current_setting('u.admin')::uuid, 'adm', 'ผู้ดูแล', true);
insert into staff (auth_user_id, login, display_name) values (current_setting('u.cashier')::uuid, 'cash', 'พนักงานขาย'), (current_setting('u.pharm')::uuid, 'phr', 'เภสัชกร');
insert into staff (auth_user_id, login, display_name, active) values (current_setting('u.off')::uuid, 'off', 'ปิดใช้งาน', false);
insert into staff_permissions select id, x from staff, unnest(array['pos','members','billsView','sellOtc']) x where login = 'cash';
insert into staff_permissions select id, x from staff, unnest(array['pos','members','billsView','sellOtc','sellRx','adjustStock','viewCost','receive','stock','manage','report','reports','forms']) x where login = 'phr';

-- cashier
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('u.cashier'))::text, false);
select tst.expect(not app.open_mode(), 'an active admin exists: open mode is off');
select tst.expect((select count(*) from v_products) = 2 and (select latest_cost is null from v_products where code = 'S1'), 'cashier sees products but NOT the cost');
select tst.expect((select count(*) from v_receipts) = 0 and (select count(*) from v_audit_log) = 0 and (select count(*) from v_staff) = 0, 'cashier sees no receipts, audit log or staff list');
select tst.expect((select unit_cost is null from v_lots limit 1), 'cashier cannot see lot cost');
select tst.expect(commit_sale(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.s1')::bigint,'qty',1,'price',20)))) > 0, 'cashier can sell an ordinary drug');
select tst.expect_error($q$select commit_sale(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.d1')::bigint,'qty',1,'price',90))))$q$, 'ไม่มีสิทธิ์', 'cashier cannot sell a dangerous drug');
select tst.expect_error($q$select adjust_stock(current_setting('t.s1')::bigint, 5, 'x')$q$, 'ไม่มีสิทธิ์', 'cashier cannot adjust stock');
select tst.expect_error($q$select void_sale((select id from v_sales limit 1), 'x')$q$, 'ไม่มีสิทธิ์', 'cashier cannot void a bill');
select tst.expect_error($q$select receive_goods('{"supplier_name":"x","items":[{"product_id":1,"qty":1}]}'::jsonb)$q$, 'ไม่มีสิทธิ์', 'cashier cannot receive goods');
select tst.expect_error($q$select save_staff('{"login":"hack","is_admin":true}'::jsonb)$q$, 'เฉพาะผู้ดูแล', 'cashier cannot create an admin');
reset role;

-- pharmacist
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('u.pharm'))::text, false);
select tst.expect((select latest_cost = 8 from v_products where code = 'S1'), 'pharmacist (viewCost) sees the cost');
select tst.expect(commit_sale(jsonb_build_object('buyer', jsonb_build_object('name','คุณ ก'), 'items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.d1')::bigint,'qty',1,'price',90)))) > 0, 'pharmacist can sell a dangerous drug');
select tst.expect(adjust_stock(current_setting('t.s1')::bigint, 20, 'นับสต็อกไม่ตรง') = 11, 'pharmacist can adjust stock');
select tst.expect_error($q$select save_staff('{"login":"x"}'::jsonb)$q$, 'เฉพาะผู้ดูแล', 'pharmacist cannot manage staff');
reset role;

-- inactive and unlisted
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('u.off'))::text, false);
select tst.expect((select count(*) from v_products) = 0, 'inactive account sees nothing');
select tst.expect_error($q$select commit_sale(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.s1')::bigint,'qty',1,'price',20))))$q$, 'ไม่มีสิทธิ์', 'inactive account cannot sell');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid())::text, false);
select tst.expect(commit_sale(jsonb_build_object('items', jsonb_build_array(jsonb_build_object('product_id', current_setting('t.s1')::bigint,'qty',1,'price',20)))) > 0, 'a logged-in user who is not listed gets sales-clerk rights');
select tst.expect_error($q$select adjust_stock(current_setting('t.s1')::bigint, 1, 'x')$q$, 'ไม่มีสิทธิ์', 'unlisted user cannot adjust stock');
reset role;

-- admin
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('u.admin'))::text, false);
select tst.expect((select count(*) from v_staff) = 4, 'admin sees the staff list');
select tst.expect_error($q$select save_staff(jsonb_build_object('id', (select id::text from v_staff where login='adm'), 'login','adm','is_admin',false,'active',true))$q$, 'ผู้ดูแลที่ใช้งานอยู่อย่างน้อย', 'the last admin cannot be demoted');
reset role;
select tst.expect((select count(*) = 0 from lots l left join (select lot_id, sum(qty) q from stock_movements group by lot_id) m on m.lot_id = l.id where l.qty_left <> coalesce(m.q, 0)), 'stock invariant holds after all of that');
rollback;
