-- =====================================================================
-- Pharmacy database: reports and ข.ย. 9 / 10 / 11 / 12 / 13 forms
-- Same rules as the app (Logic.salesReport / Logic.buildKy).
-- Run after 01-03. Callable by logged-in users; permission "reports" / "forms",
-- cost and profit are NULL unless the user has "viewCost".
-- =====================================================================

-- ---------- sales report -------------------------------------------------
-- p_group: day | month | hour | staff | category | method | product | flag | all
-- p_flag : drug type code, or 'none' = products with no special type
-- last row has key '__total' (bills counted once)
create or replace function report_sales(
  p_from timestamptz, p_to timestamptz, p_group text default 'day',
  p_staff text default null, p_method text default null, p_category text default null,
  p_flag text default null, p_q text default null)
returns table (key text, label text, bills bigint, qty bigint, sales numeric, cost numeric, profit numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_cost boolean;
begin
  perform app.check_perm('reports');
  v_cost := app.has_perm('viewCost');
  return query
  with ln as (
    select s.id as sale_id, s.ts, s.sale_date, coalesce(nullif(s.staff_name, ''), '-') as staff_key, s.method,
           l.product_id, l.name, l.qty,
           coalesce(c.name, 'อื่นๆ') as cat0, p.id is not null as has_p,
           round(l.qty * l.unit_price * case when s.subtotal > 0 then s.total / s.subtotal else 1 end, 2) as rev,
           round(l.cost_total, 2) as cst
      from sales s
      join sale_lines l on l.sale_id = s.id
      left join products p on p.id = l.product_id
      left join categories c on c.id = p.category_id
     where s.status = 'ok' and s.ts >= p_from and s.ts <= p_to
       and (p_staff is null or p_staff = '' or coalesce(nullif(s.staff_name, ''), '-') = p_staff)
       and (p_method is null or p_method = '' or s.method = p_method)
       and (p_q is null or trim(p_q) = '' or lower(l.name) like '%' || lower(trim(p_q)) || '%' or lower(coalesce(p.generic_name, '')) like '%' || lower(trim(p_q)) || '%')
  ), f as (
    select ln.*, case when has_p then cat0 else 'รายรับอื่น' end as cat
      from ln
     where (p_flag is null or p_flag = '' or
            case when p_flag = 'none' then not (has_p and exists (select 1 from product_drug_types t where t.product_id = ln.product_id))
                 else has_p and exists (select 1 from product_drug_types t where t.product_id = ln.product_id and t.type_code = p_flag) end)
  ), g as (
    select f.*, k.k, k.lbl
      from f
      cross join lateral (
        select * from (
          select case p_group
            when 'day'      then to_char(f.sale_date, 'YYYY-MM-DD')
            when 'month'    then to_char(f.sale_date, 'YYYY-MM')
            when 'hour'     then lpad(extract(hour from f.ts at time zone 'Asia/Bangkok')::int::text, 2, '0')
            when 'staff'    then f.staff_key
            when 'category' then f.cat
            when 'method'   then f.method
            when 'product'  then coalesce(f.product_id::text, f.name)
            else 'all' end as k,
          case p_group
            when 'day'      then to_char(f.sale_date, 'YYYY-MM-DD')
            when 'month'    then to_char(f.sale_date, 'YYYY-MM')
            when 'hour'     then lpad(extract(hour from f.ts at time zone 'Asia/Bangkok')::int::text, 2, '0') || ':00 - ' || lpad(extract(hour from f.ts at time zone 'Asia/Bangkok')::int::text, 2, '0') || ':59'
            when 'staff'    then case when f.staff_key = '-' then '(ไม่ระบุ)' else f.staff_key end
            when 'category' then f.cat
            when 'method'   then case when f.method = 'cash' then 'เงินสด' else 'โอน' end
            when 'product'  then f.name
            else 'ทั้งหมด' end as lbl
          where p_group <> 'flag'
          union all
          select t.type_code, dt.label from product_drug_types t join drug_types dt on dt.code = t.type_code
           where p_group = 'flag' and f.has_p and t.product_id = f.product_id
          union all
          select 'none', 'ไม่มีประเภทพิเศษ'
           where p_group = 'flag' and not (f.has_p and exists (select 1 from product_drug_types t where t.product_id = f.product_id))
        ) z
      ) k
  ), agg as (
    select g.k, min(g.lbl) as lbl, count(distinct g.sale_id) as bills, sum(g.qty) as qty, sum(g.rev) as sales, sum(g.cst) as cost
      from g group by g.k
  ), tot as (
    select count(distinct sale_id) as bills, sum(qty) as qty, sum(rev) as sales, sum(cst) as cost from f
  )
  select u.k, u.lbl, u.bills, u.qty, u.sales, u.cost, u.profit from (
  select a.k, a.lbl, a.bills, a.qty::bigint, a.sales, case when v_cost then a.cost end as cost, case when v_cost then a.sales - a.cost end as profit
    from agg a
  union all
  select '__total', 'รวม', coalesce(t.bills, 0), coalesce(t.qty, 0)::bigint, coalesce(t.sales, 0), case when v_cost then coalesce(t.cost, 0) end,
         case when v_cost then coalesce(t.sales, 0) - coalesce(t.cost, 0) end
    from tot t
  ) u order by (u.k = '__total'), case when p_group in ('day', 'month', 'hour') then 0 else 1 end, u.k;
end $$;
-- note: ordering for non-time groups (best sellers first) is done by the caller on "sales"

-- ---------- ข.ย.9 (purchases) ---------------------------------------------
create or replace function report_ky9(p_from date, p_to date, p_only9n boolean default false)
returns table (no bigint, ts timestamptz, doc_date date, supplier text, drug text, lot_no text, qty text, note text, missing_lot boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform app.check_perm('forms');
  return query
  select row_number() over (order by r.created_at, l.id), r.created_at, r.received_on, coalesce(sp.name, ''),
         p.name || case when coalesce(p.pack_size, '') <> '' then ' (' || p.pack_size || ')' else '' end,
         coalesce(l.lot_no, ''), (l.qty + l.free_qty)::text || ' ' || coalesce(p.unit, ''),
         trim(case when l.free_qty > 0 then 'แถม ' || l.free_qty || ' ' else '' end || case when coalesce(r.invoice_no, '') <> '' then 'บิล ' || r.invoice_no else '' end),
         coalesce(l.lot_no, '') = ''
    from receipts r
    join receipt_lines l on l.receipt_id = r.id
    join products p on p.id = l.product_id
    left join suppliers sp on sp.id = r.supplier_id
   where r.status <> 'void' and r.received_on between p_from and p_to and not p.is_supply
     and (not p_only9n or exists (select 1 from product_drug_types t where t.product_id = p.id and t.type_code = 'ky9n'))
   order by 2, 1;
end $$;

-- ---------- ข.ย.12 (prescription sales) -----------------------------------
create or replace function report_ky12(p_from date, p_to date)
returns table (no bigint, ts timestamptz, doc_date date, prescriber text, prescriber_addr text, user_name text, age text, addr text, drugs text, note text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform app.check_perm('forms');
  return query
  select row_number() over (order by s.ts, s.id), s.ts, s.sale_date, s.rx_prescriber, s.rx_prescriber_addr,
         coalesce(nullif(s.rx_user, ''), s.buyer_name, ''), s.rx_user_age, coalesce(nullif(s.rx_user_addr, ''), s.buyer_addr, ''),
         (select string_agg(l.name || ' ' || l.qty || ' ' || coalesce(l.unit, ''), ', ' order by l.line_no) from sale_lines l where l.sale_id = s.id and l.product_id is not null),
         'บิล ' || s.bill_no
    from sales s
   where s.status = 'ok' and s.rx_prescriber is not null and s.sale_date between p_from and p_to
   order by s.ts, s.id;
end $$;

-- ---------- ข.ย.10 / 11 / 13 (one page per drug lot) ----------------------
-- p_form: '10' (controlled) | '11' (ky11) | '13' (ky13); p_pids overrides the product set.
-- One row per sale from the lot; a lot with no sale in the period but received in it gives one row with row_no = 0.
create or replace function report_ky_lots(p_form text, p_from date, p_to date, p_pids bigint[] default null)
returns table (product_id bigint, drug text, maker text, lot_id bigint, lot_no text, pack text, from_supplier text, qty_in text, date_in date, reg_no text,
               row_no bigint, sale_date date, qty text, buyer text, addr text, buyer_type text, remain text, bill_no text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_code text := case p_form when '10' then 'controlled' when '11' then 'ky11' when '13' then 'ky13' end;
begin
  perform app.check_perm('forms');
  if v_code is null and p_pids is null then raise exception 'ฟอร์มไม่ถูกต้อง: %', p_form; end if;
  return query
  with prods as (
    select p.* from products p
     where case when p_pids is not null then p.id = any (p_pids)
                else exists (select 1 from product_drug_types t where t.product_id = p.id and t.type_code = v_code) end
  ), lt as (
    select l.id, l.product_id, l.lot_no, l.qty_in,
           coalesce((select r.received_on from receipt_lines rl join receipts r on r.id = rl.receipt_id where rl.lot_id = l.id and r.status <> 'void' limit 1), l.received_on) as date_in,
           (select sp.name from receipt_lines rl join receipts r on r.id = rl.receipt_id left join suppliers sp on sp.id = r.supplier_id where rl.lot_id = l.id and r.status <> 'void' limit 1) as sup
      from lots l where l.product_id in (select id from prods)
  ), al as (
    select sl.lot_id, s.id as sale_id, s.bill_no, s.ts, s.sale_date, s.buyer_name, s.buyer_addr, s.buyer_type, s.customer_id, a.qty,
           row_number() over (partition by sl.lot_id, s.bill_no order by sl.line_id) as rn
      from (select sll.lot_id, sll.sale_line_id as line_id, sll.qty, l.sale_id from sale_line_lots sll join sale_lines l on l.id = sll.sale_line_id) sl
      join sale_line_lots a on a.sale_line_id = sl.line_id and a.lot_id = sl.lot_id
      join sales s on s.id = sl.sale_id
     where s.status = 'ok' and s.sale_date between p_from and p_to and sl.lot_id in (select id from lt)
  ), mv as (
    select m.lot_id, m.ref_no, sum(m.qty) over (partition by m.lot_id order by m.ts, m.id) as run,
           row_number() over (partition by m.lot_id, m.ref_no order by m.ts, m.id) as rn
      from stock_movements m
     where m.lot_id in (select id from lt) and (m.type = 'sale' or true)
  ), mvs as (
    select m2.lot_id, m2.ref_no, m2.run, m2.rn
      from mv m2 join stock_movements x on x.lot_id = m2.lot_id and x.ref_no is not distinct from m2.ref_no and x.type = 'sale'
     group by m2.lot_id, m2.ref_no, m2.run, m2.rn
  ), rows as (
    select lt.id as lot_id, row_number() over (partition by lt.id order by al.ts, al.sale_id) as row_no, al.sale_date, al.qty, al.bill_no,
           coalesce(nullif(al.buyer_name, ''), c.name, '') as buyer, coalesce(al.buyer_addr, '') as addr, coalesce(al.buyer_type, '') as btype,
           (select m.run from mvs m where m.lot_id = lt.id and m.ref_no = al.bill_no and m.rn = al.rn) as remain
      from lt join al on al.lot_id = lt.id left join customers c on c.id = al.customer_id
  )
  select p.id, p.name || case when coalesce(p.generic_name, '') <> '' then ' (' || p.generic_name || ')' else '' end, coalesce(p.manufacturer, ''),
         lt.id, coalesce(lt.lot_no, ''), coalesce(p.pack_size, ''), coalesce(lt.sup, ''), lt.qty_in || ' ' || coalesce(p.unit, ''), lt.date_in, coalesce(p.reg_no, ''),
         coalesce(r.row_no, 0), r.sale_date, case when r.qty is null then null else r.qty || ' ' || coalesce(p.unit, '') end, r.buyer, r.addr, r.btype,
         case when r.remain is null then null else r.remain || ' ' || coalesce(p.unit, '') end, r.bill_no
    from lt
    join prods p on p.id = lt.product_id
    left join rows r on r.lot_id = lt.id
   where r.lot_id is not null or lt.date_in between p_from and p_to
   order by p.name, coalesce(lt.lot_no, ''), lt.id, coalesce(r.row_no, 0);
end $$;

do $$ declare f text; begin
  foreach f in array array['report_sales(timestamptz,timestamptz,text,text,text,text,text,text)', 'report_ky9(date,date,boolean)', 'report_ky12(date,date)', 'report_ky_lots(text,date,date,bigint[])']
  loop execute format('revoke execute on function public.%s from public', f); execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;
