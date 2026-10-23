-- =====================================================================
-- Pharmacy database: security
-- Deny by default. Logged-in users cannot read or write tables directly.
-- They READ through views (which hide costs from people without the "viewCost" right)
-- and WRITE only through the checked functions in 02_functions.sql.
-- =====================================================================
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon')          then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;

do $$ declare t record; begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t.tablename);
    execute format('revoke all on public.%I from anon, authenticated', t.tablename);
  end loop;
end $$;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public;
revoke execute on all functions in schema app from public;

-- ---------- read views ---------------------------------------------------
create or replace view v_shop as select * from shop where app.uid() is not null or app.is_service();
create or replace view v_me as
  select s.id, s.login, s.display_name, s.emp_id, s.role_label, s.is_admin, s.active, s.work_start, s.work_end,
         coalesce((select array_agg(perm_code order by perm_code) from staff_permissions where staff_id = s.id), '{}') as permissions
    from staff s where s.auth_user_id = app.uid();
create or replace view v_staff as
  select s.id, s.login, s.display_name, s.emp_id, s.license_no, s.role_label, s.is_admin, s.active, s.work_start, s.work_end,
         coalesce((select array_agg(perm_code order by perm_code) from staff_permissions where staff_id = s.id), '{}') as permissions
    from staff s where app.is_service() or app.open_mode() or exists (select 1 from staff a where a.auth_user_id = app.uid() and a.is_admin and a.active);
create or replace view v_permissions as select * from permissions where app.uid() is not null or app.is_service();
create or replace view v_categories as select * from categories where app.uid() is not null or app.is_service();
create or replace view v_drug_types as select * from drug_types where app.uid() is not null or app.is_service();
create or replace view v_suppliers as select * from suppliers where app.has_perm('receive') or app.has_perm('stock') or app.has_perm('manage');
create or replace view v_supplier_terms as select * from supplier_terms where app.has_perm('receive') or app.has_perm('stock') or app.has_perm('manage');
create or replace view v_customers as select * from customers where app.has_perm('members') or app.has_perm('pos');
create or replace view v_customer_allergies as select * from customer_allergies where app.has_perm('members') or app.has_perm('pos');
create or replace view v_products as
  select p.id, p.code, p.name, p.generic_name, p.category_id, c.name as category, p.unit, p.barcode, p.location, p.reg_no, p.manufacturer, p.pack_size, p.supplier_id,
         p.reorder_point, p.order_qty, p.exp_warn_days, p.price1, p.price2, p.price3, p.price4, p.price5,
         case when app.has_perm('viewCost') then p.latest_cost end as latest_cost,
         p.is_supply, p.active, p.usage_text, p.indication, p.warning_text, p.storage_text, p.meal_time, p.storage_type, p.note,
         coalesce((select array_agg(type_code order by type_code) from product_drug_types d where d.product_id = p.id), '{}') as drug_types,
         app.stock_of(p.id) as stock_qty
    from products p left join categories c on c.id = p.category_id
   where app.has_perm('pos') or app.has_perm('stock') or app.has_perm('manage') or app.has_perm('receive');
create or replace view v_product_drug_types as select * from product_drug_types where app.has_perm('pos') or app.has_perm('stock') or app.has_perm('manage');
create or replace view v_product_bundles as select * from product_bundles where app.has_perm('pos') or app.has_perm('stock') or app.has_perm('manage');
create or replace view v_lots as
  select l.id, l.product_id, l.lot_no, l.exp_date, l.received_on, l.qty_in, l.qty_left, l.supplier_id, l.source,
         case when app.has_perm('viewCost') then l.unit_cost end as unit_cost
    from lots l where app.has_perm('stock') or app.has_perm('manage') or app.has_perm('receive') or app.has_perm('pos');
create or replace view v_stock_movements as
  select m.* from stock_movements m where app.has_perm('stock') or app.has_perm('manage');
create or replace view v_sales as
  select s.* from sales s where app.has_perm('billsView') or app.has_perm('report') or app.has_perm('reports');
create or replace view v_sale_lines as
  select l.id, l.sale_id, l.line_no, l.product_id, l.name, l.unit, l.qty, l.unit_price, l.line_discount, l.line_total, s.sale_date, s.status as sale_status,
         case when app.has_perm('viewCost') then l.cost_total end as cost_total
    from sale_lines l join sales s on s.id = l.sale_id
   where app.has_perm('billsView') or app.has_perm('report') or app.has_perm('reports');
create or replace view v_receipts as select * from receipts where app.has_perm('receive');
create or replace view v_receipt_lines as
  select l.*, r.received_on, r.status as receipt_status from receipt_lines l join receipts r on r.id = l.receipt_id where app.has_perm('receive');
create or replace view v_purchase_orders as select * from purchase_orders where app.has_perm('receive');
create or replace view v_purchase_order_lines as
  select l.*, o.status as po_status, o.ordered_on from purchase_order_lines l join purchase_orders o on o.id = l.po_id where app.has_perm('receive');
create or replace view v_closings as select * from daily_closings where app.has_perm('report');
create or replace view v_audit_log as select * from audit_log where app.is_service() or exists (select 1 from staff s where s.auth_user_id = app.uid() and s.is_admin and s.active);

-- views run with the owner's rights (so the closed tables can be read), each one filters by permission itself
do $$ declare v record; begin
  for v in select viewname from pg_views where schemaname = 'public' and viewname like 'v\_%' loop
    execute format('grant select on public.%I to authenticated', v.viewname);
  end loop;
end $$;

-- ---------- callable functions (the only way to change data) -------------
do $$ declare f text; begin
  foreach f in array array['commit_sale(jsonb)', 'void_sale(bigint,text)', 'receive_goods(jsonb)', 'void_receipt(bigint,text)', 'adjust_stock(bigint,int,text,text)',
                           'adjust_lot(bigint,int,text,text)', 'adjust_lot_cost(bigint,numeric)', 'create_purchase_order(jsonb)', 'cancel_purchase_order(bigint)',
                           'close_purchase_order(bigint)', 'set_drug_type(bigint[],text,boolean)', 'save_product(jsonb)', 'save_supplier(jsonb)', 'save_customer(jsonb)', 'save_staff(jsonb)']
  loop execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;
grant usage on schema app to authenticated;
grant execute on function app.uid(), app.has_perm(text), app.stock_of(bigint), app.local_date(timestamptz), app.find_duplicate_receipt(bigint, text), app.staff_name(), app.open_mode(), app.is_service() to authenticated;
grant usage on schema public to authenticated;
