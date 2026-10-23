-- =====================================================================
-- Pharmacy database: business functions (all stock changes go through these)
-- Each function is one transaction. Lots are locked while stock is taken (FEFO).
-- =====================================================================

-- ---------- who is calling -------------------------------------------
-- JWT subject of the current request (works with Supabase and PostgREST).
create or replace function app.uid() returns uuid language sql stable as $$
  select nullif(coalesce(
           nullif(current_setting('request.jwt.claim.sub', true), ''),
           nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
         ), '')::uuid
$$;

-- True only for the trusted back-end roles. NOTE: inside SECURITY DEFINER functions current_user is the
-- function owner, so we look at the role the request was made AS (set role / PostgREST), else the session user.
create or replace function app.is_service() returns boolean language sql stable as $$
  select coalesce(nullif(current_setting('role', true), 'none'), session_user) in ('postgres', 'service_role', 'supabase_admin')
$$;

-- No active admin yet = open mode (everyone logged in has full rights), same as the app.
create or replace function app.open_mode() returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from staff where is_admin and active)
$$;

create or replace function app.has_perm(p text) returns boolean language sql stable security definer set search_path = public as $$
  select app.is_service()
      or (app.uid() is not null and app.open_mode())
      or exists (
           select 1 from staff s
            where s.auth_user_id = app.uid() and s.active
              and (s.is_admin or exists (select 1 from staff_permissions sp where sp.staff_id = s.id and sp.perm_code = p)))
      or (app.uid() is not null
          and not exists (select 1 from staff s where s.auth_user_id = app.uid())      -- logged in but not listed
          and p = any (array['pos', 'members', 'billsView', 'sellOtc']))
$$;

create or replace function app.check_perm(p text) returns void language plpgsql stable as $$
begin
  if not app.has_perm(p) then raise exception 'ไม่มีสิทธิ์: %', p using errcode = '42501'; end if;
end $$;

create or replace function app.staff_name() returns text language sql stable security definer set search_path = public as $$
  select coalesce((select display_name from staff where auth_user_id = app.uid() limit 1), case when app.is_service() then 'system' else 'unknown' end)
$$;

create or replace function app.local_date(t timestamptz) returns date language sql immutable as $$
  select (t at time zone 'Asia/Bangkok')::date
$$;

-- ---------- stock keeps itself consistent -----------------------------
-- lots.qty_left is always the sum of its movements (the trigger applies each movement).
create or replace function app.apply_movement() returns trigger language plpgsql as $$
begin
  update lots set qty_left = qty_left + new.qty where id = new.lot_id;
  return new;
end $$;
create trigger stock_movements_apply after insert on stock_movements
  for each row execute function app.apply_movement();

create or replace function app.stock_of(p_product bigint) returns int language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from product_bundles where bundle_id = p_product)
      then (select coalesce(min(floor(app.stock_of(b.part_id)::numeric / b.qty))::int, 0) from product_bundles b where b.bundle_id = p_product)
    else (select coalesce(sum(qty_left), 0)::int from lots where product_id = p_product)
  end
$$;

-- take stock first-expiry-first-out; returns what was taken from which lot
create or replace function app.fefo_take(p_product bigint, p_qty int, p_ts timestamptz, p_type movement_type, p_ref text, p_note text)
returns table (lot_id bigint, qty int, unit_cost numeric) language plpgsql as $$
declare need int := p_qty; l record; q int; staff text := app.staff_name();
begin
  if p_qty <= 0 then raise exception 'จำนวนต้องมากกว่า 0'; end if;
  for l in select id, qty_left, lots.unit_cost as uc from lots
            where product_id = p_product and qty_left > 0
            order by exp_date nulls last, received_on, id
            for update
  loop
    exit when need <= 0;
    q := least(l.qty_left, need);
    insert into stock_movements (ts, product_id, lot_id, type, qty, ref_no, note, staff_name) values (p_ts, p_product, l.id, p_type, -q, p_ref, p_note, staff);
    need := need - q;
    lot_id := l.id; qty := q; unit_cost := l.uc; return next;
  end loop;
  if need > 0 then
    raise exception 'สต็อกไม่พอ (%: ขาดอีก %)', (select name from products where id = p_product), need;
  end if;
end $$;

-- ---------- selling ---------------------------------------------------
-- p: { customer_id, method, received, discount, at, deduct, note,
--      buyer:{name,addr,type}, rx:{doc,doc_addr,user,age,addr},
--      items:[{product_id, qty, price, name}] }
create or replace function commit_sale(p jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare
  it jsonb; prod products; lot record; part record;
  v_ts timestamptz := coalesce((p->>'at')::timestamptz, now());
  v_deduct boolean := coalesce((p->>'deduct')::boolean, true);
  v_sub numeric := 0; v_disc numeric; v_total numeric; v_method text := coalesce(p->>'method', 'cash'); v_recv numeric;
  v_sale bigint; v_line bigint; v_no text; v_qty int; v_price numeric; v_cost numeric; v_name text;
  v_need_buyer boolean := false; v_buyer jsonb := coalesce(p->'buyer', '{}'::jsonb); v_rx jsonb := p->'rx';
begin
  perform app.check_perm('pos');
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'ตะกร้าว่าง'; end if;
  if v_ts > now() + interval '1 minute' then raise exception 'เลือกวันที่ในอนาคตไม่ได้'; end if;

  -- validate lines first (permissions on drug types, banned, buyer rules)
  for it in select * from jsonb_array_elements(p->'items') loop
    v_qty := (it->>'qty')::int; v_price := coalesce((it->>'price')::numeric, 0);
    if v_qty is null or v_qty <= 0 then raise exception 'จำนวนต้องมากกว่า 0'; end if;
    if v_price < 0 then raise exception 'ราคาติดลบ'; end if;
    v_sub := v_sub + v_qty * v_price;
    if it->>'product_id' is not null then
      select * into prod from products where id = (it->>'product_id')::bigint;
      if not found then raise exception 'ไม่พบสินค้า'; end if;
      if exists (select 1 from product_drug_types where product_id = prod.id and type_code = 'banned') then raise exception '% เป็นยาห้ามขาย', prod.name; end if;
      if exists (select 1 from product_drug_types where product_id = prod.id and type_code in ('danger', 'controlled', 'ky8', 'ky11')) then
        if not app.has_perm('sellRx') then raise exception 'ไม่มีสิทธิ์ขาย % (ยาอันตราย / ควบคุม)', prod.name using errcode = '42501'; end if;
      end if;
      if exists (select 1 from product_drug_types where product_id = prod.id and type_code = 'otc') and not app.has_perm('sellOtc') then
        raise exception 'ไม่มีสิทธิ์ขายยา OTC' using errcode = '42501';
      end if;
      if exists (select 1 from product_drug_types where product_id = prod.id and type_code in ('controlled', 'ky11', 'ky13')) then v_need_buyer := true; end if;
    end if;
  end loop;
  if v_need_buyer and coalesce(trim(v_buyer->>'name'), '') = '' then raise exception 'ต้องระบุชื่อ-สกุลผู้ซื้อ (ยาควบคุม / ข.ย.11 / ข.ย.13)'; end if;
  if v_rx is not null and (coalesce(trim(v_rx->>'doc'), '') = '' or coalesce(trim(v_rx->>'user'), '') = '') then raise exception 'ใบสั่งยา (ข.ย.12) ต้องมีชื่อผู้สั่งยาและผู้ใช้ยา'; end if;

  v_disc := least(greatest(coalesce((p->>'discount')::numeric, 0), 0), v_sub);
  v_total := round(v_sub - v_disc, 2);
  v_recv := case when v_method = 'cash' then coalesce((p->>'received')::numeric, v_total) else v_total end;
  if v_method = 'cash' and v_recv < v_total then raise exception 'รับเงินไม่พอ'; end if;

  v_no := 'B' || lpad(nextval('bill_seq')::text, 6, '0');
  insert into sales (bill_no, ts, sale_date, customer_id, staff_name, subtotal, discount, total, method, received, change_amount, buyer_name, buyer_addr, buyer_type,
                     rx_prescriber, rx_prescriber_addr, rx_user, rx_user_age, rx_user_addr, note)
  values (v_no, v_ts, app.local_date(v_ts), nullif(p->>'customer_id', '')::bigint, app.staff_name(), round(v_sub, 2), round(v_disc, 2), v_total, v_method, v_recv, round(v_recv - v_total, 2),
          nullif(trim(v_buyer->>'name'), ''), nullif(trim(v_buyer->>'addr'), ''), coalesce(nullif(v_buyer->>'type', ''), case when v_need_buyer or v_rx is not null then 'ผู้บริโภค' end),
          v_rx->>'doc', v_rx->>'doc_addr', v_rx->>'user', v_rx->>'age', v_rx->>'addr', p->>'note')
  returning id into v_sale;

  for it in select * from jsonb_array_elements(p->'items') loop
    v_qty := (it->>'qty')::int; v_price := coalesce((it->>'price')::numeric, 0); v_cost := 0;
    if it->>'product_id' is not null then
      select * into prod from products where id = (it->>'product_id')::bigint;
      v_name := coalesce(nullif(it->>'name', ''), prod.name);
    else
      prod := null; v_name := coalesce(nullif(it->>'name', ''), 'รายรับอื่น');
    end if;
    insert into sale_lines (sale_id, line_no, product_id, name, unit, qty, unit_price, line_total, cost_total)
    values (v_sale, (select coalesce(max(line_no), 0) + 1 from sale_lines where sale_id = v_sale), prod.id, v_name, prod.unit, v_qty, v_price, round(v_qty * v_price, 2), 0)
    returning id into v_line;
    if prod.id is not null then
      if v_deduct then
        if exists (select 1 from product_bundles where bundle_id = prod.id) then
          for part in select b.part_id, b.qty from product_bundles b where b.bundle_id = prod.id loop
            for lot in select * from app.fefo_take(part.part_id, part.qty * v_qty, v_ts, 'sale', v_no, 'ในชุด ' || prod.name) loop
              insert into sale_line_lots (sale_line_id, lot_id, qty, unit_cost) values (v_line, lot.lot_id, lot.qty, lot.unit_cost)
                on conflict (sale_line_id, lot_id) do update set qty = sale_line_lots.qty + excluded.qty;
              v_cost := v_cost + lot.qty * lot.unit_cost;
            end loop;
          end loop;
        else
          for lot in select * from app.fefo_take(prod.id, v_qty, v_ts, 'sale', v_no, null) loop
            insert into sale_line_lots (sale_line_id, lot_id, qty, unit_cost) values (v_line, lot.lot_id, lot.qty, lot.unit_cost);
            v_cost := v_cost + lot.qty * lot.unit_cost;
          end loop;
        end if;
      else
        v_cost := v_qty * prod.latest_cost;
      end if;
      update sale_lines set cost_total = round(v_cost, 2) where id = v_line;
    end if;
  end loop;
  return v_sale;
end $$;

create or replace function void_sale(p_sale bigint, p_reason text default null) returns void language plpgsql security definer set search_path = public as $$
declare s sales; r record;
begin
  perform app.check_perm('voidSale');
  select * into s from sales where id = p_sale for update;
  if not found then raise exception 'ไม่พบบิล'; end if;
  if s.status <> 'ok' then raise exception 'บิลนี้ถูกยกเลิกไปแล้ว'; end if;
  for r in select sll.lot_id, sll.qty, l.product_id from sale_line_lots sll join sale_lines sl on sl.id = sll.sale_line_id join lots l on l.id = sll.lot_id where sl.sale_id = p_sale loop
    insert into stock_movements (ts, product_id, lot_id, type, qty, ref_no, note, staff_name) values (now(), r.product_id, r.lot_id, 'void', r.qty, s.bill_no, p_reason, app.staff_name());
  end loop;
  update sales set status = 'void', void_reason = p_reason, voided_at = now(), voided_by = app.staff_name() where id = p_sale;
end $$;

-- ---------- receiving -------------------------------------------------
create or replace function app.find_duplicate_receipt(p_supplier bigint, p_invoice text) returns bigint language sql stable as $$
  select id from receipts
   where status = 'ok' and p_invoice is not null and trim(p_invoice) <> ''
     and lower(trim(invoice_no)) = lower(trim(p_invoice)) and supplier_id is not distinct from p_supplier
   order by id desc limit 1
$$;

-- p: { supplier_id | supplier_name, invoice_no, received_on, discount, invoice_total, po_id, force,
--      items:[{product_id, qty, free_qty, unit_cost, lot_no, exp_date}] }
-- free goods and the bill discount are spread into the lot cost: (qty*cost - share) / (qty + free)
create or replace function receive_goods(p jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare
  it jsonb; v_sup bigint := nullif(p->>'supplier_id', '')::bigint; v_rc bigint; v_line bigint; v_lot bigint; prod products;
  v_sub numeric := 0; v_disc numeric; v_share numeric; v_qty int; v_free int; v_uc numeric; v_eff numeric; v_day date := coalesce((p->>'received_on')::date, app.local_date(now()));
  v_po bigint := nullif(p->>'po_id', '')::bigint; v_inv text := nullif(trim(p->>'invoice_no'), ''); v_ts timestamptz := now();
begin
  perform app.check_perm('receive');
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'ยังไม่มีรายการ'; end if;
  if v_sup is null and coalesce(trim(p->>'supplier_name'), '') <> '' then
    select id into v_sup from suppliers where lower(name) = lower(trim(p->>'supplier_name')) limit 1;
    if v_sup is null then insert into suppliers (name) values (trim(p->>'supplier_name')) returning id into v_sup; end if;
  end if;
  if app.find_duplicate_receipt(v_sup, v_inv) is not null and not coalesce((p->>'force')::boolean, false) then
    raise exception 'เลขที่บิลนี้เคยรับเข้าแล้ว (รับซ้ำให้ส่ง force = true)' using errcode = '23505';
  end if;
  for it in select * from jsonb_array_elements(p->'items') loop
    select * into prod from products where id = (it->>'product_id')::bigint;
    if not found then raise exception 'ไม่พบสินค้า'; end if;
    if exists (select 1 from product_bundles where bundle_id = prod.id) then raise exception '% เป็นยาชุด ให้รับเข้าที่ตัวยาแต่ละตัว', prod.name; end if;
    if coalesce((it->>'qty')::int, 0) <= 0 then raise exception 'จำนวนของ % ต้องมากกว่า 0', prod.name; end if;
    if coalesce((it->>'free_qty')::int, 0) < 0 or coalesce((it->>'unit_cost')::numeric, 0) < 0 then raise exception 'ตัวเลขของ % ไม่ถูกต้อง', prod.name; end if;
    v_sub := v_sub + (it->>'qty')::int * coalesce((it->>'unit_cost')::numeric, 0);
  end loop;
  v_disc := least(greatest(coalesce((p->>'discount')::numeric, 0), 0), v_sub);
  insert into receipts (supplier_id, invoice_no, received_on, po_id, subtotal, discount, total, invoice_total, staff_name)
  values (v_sup, v_inv, v_day, v_po, round(v_sub, 2), round(v_disc, 2), round(v_sub - v_disc, 2), nullif(p->>'invoice_total', '')::numeric, app.staff_name()) returning id into v_rc;
  for it in select * from jsonb_array_elements(p->'items') loop
    v_qty := (it->>'qty')::int; v_free := coalesce((it->>'free_qty')::int, 0); v_uc := coalesce((it->>'unit_cost')::numeric, 0);
    v_share := case when v_sub > 0 then round(v_disc * v_qty * v_uc / v_sub, 4) else 0 end;
    v_eff := round((v_qty * v_uc - v_share) / (v_qty + v_free), 4);
    insert into receipt_lines (receipt_id, product_id, qty, free_qty, unit_cost, line_discount, eff_cost, lot_no, exp_date)
    values (v_rc, (it->>'product_id')::bigint, v_qty, v_free, v_uc, v_share, v_eff, nullif(trim(it->>'lot_no'), ''), nullif(it->>'exp_date', '')::date) returning id into v_line;
    insert into lots (product_id, lot_no, exp_date, received_on, qty_in, qty_left, unit_cost, supplier_id, receipt_line_id, source)
    values ((it->>'product_id')::bigint, nullif(trim(it->>'lot_no'), ''), nullif(it->>'exp_date', '')::date, v_day, v_qty + v_free, 0, v_eff, v_sup, v_line, 'receive') returning id into v_lot;
    update receipt_lines set lot_id = v_lot where id = v_line;
    insert into stock_movements (ts, product_id, lot_id, type, qty, ref_no, note, staff_name)
    values (v_ts, (it->>'product_id')::bigint, v_lot, 'receive', v_qty + v_free, v_inv, case when v_free > 0 then 'แถม ' || v_free end, app.staff_name());
    update products set latest_cost = v_eff, updated_at = now() where id = (it->>'product_id')::bigint;
    if v_po is not null then
      update purchase_order_lines set received_qty = received_qty + v_qty where po_id = v_po and product_id = (it->>'product_id')::bigint;
    end if;
  end loop;
  if v_po is not null then perform app.refresh_po_status(v_po); end if;
  return v_rc;
end $$;

create or replace function app.refresh_po_status(p_po bigint) returns void language plpgsql as $$
declare tot int; got int; st text;
begin
  select count(*), count(*) filter (where received_qty >= qty) into tot, got from purchase_order_lines where po_id = p_po;
  select status into st from purchase_orders where id = p_po;
  if st = 'cancel' then return; end if;
  update purchase_orders set status = case when tot > 0 and got = tot then 'closed'
                                           when exists (select 1 from purchase_order_lines where po_id = p_po and received_qty > 0) then 'partial' else 'open' end
   where id = p_po;
end $$;

create or replace function void_receipt(p_receipt bigint, p_reason text default null) returns void language plpgsql security definer set search_path = public as $$
declare r receipts; l record; lot lots;
begin
  perform app.check_perm('editReceipt');
  select * into r from receipts where id = p_receipt for update;
  if not found then raise exception 'ไม่พบบิลรับเข้า'; end if;
  if r.status = 'void' then raise exception 'บิลนี้ถูกยกเลิกแล้ว'; end if;
  for l in select rl.*, rl.qty + rl.free_qty as total_qty from receipt_lines rl where rl.receipt_id = p_receipt loop
    select * into lot from lots where id = l.lot_id for update;
    if lot.qty_left <> lot.qty_in then raise exception 'ยาในบิลนี้ถูกขายหรือใช้ไปบางส่วนแล้ว ยกเลิกบิลไม่ได้ ใช้ปรับสต็อกแทน'; end if;
  end loop;
  for l in select rl.*, rl.qty + rl.free_qty as total_qty from receipt_lines rl where rl.receipt_id = p_receipt loop
    insert into stock_movements (ts, product_id, lot_id, type, qty, ref_no, note, staff_name) values (now(), l.product_id, l.lot_id, 'receipt_void', -l.total_qty, r.invoice_no, p_reason, app.staff_name());
    if r.po_id is not null then update purchase_order_lines set received_qty = greatest(received_qty - l.qty, 0) where po_id = r.po_id and product_id = l.product_id; end if;
  end loop;
  update receipts set status = 'void', void_reason = p_reason where id = p_receipt;
  if r.po_id is not null then perform app.refresh_po_status(r.po_id); end if;
end $$;

-- ---------- adjusting stock --------------------------------------------
create or replace function adjust_stock(p_product bigint, p_counted int, p_reason text, p_note text default null) returns int language plpgsql security definer set search_path = public as $$
declare cur int; diff int; v_lot bigint; prod products; lbl text := coalesce(p_reason, '') || coalesce(' - ' || p_note, '');
begin
  perform app.check_perm('adjustStock');
  select * into prod from products where id = p_product; if not found then raise exception 'ไม่พบสินค้า'; end if;
  if exists (select 1 from product_bundles where bundle_id = p_product) then raise exception 'ยาชุดปรับสต็อกที่ตัวยาแต่ละตัว'; end if;
  if p_counted is null or p_counted < 0 then raise exception 'จำนวนไม่ถูกต้อง'; end if;
  cur := app.stock_of(p_product); diff := p_counted - cur;
  if diff = 0 then raise exception 'จำนวนเท่าเดิม'; end if;
  if diff > 0 then
    insert into lots (product_id, received_on, qty_in, qty_left, unit_cost, source) values (p_product, app.local_date(now()), diff, 0, prod.latest_cost, 'adjust') returning id into v_lot;
    insert into stock_movements (product_id, lot_id, type, qty, note, staff_name) values (p_product, v_lot, 'adjust', diff, lbl, app.staff_name());
  else
    perform app.fefo_take(p_product, -diff, now(), 'adjust', null, lbl);
  end if;
  return diff;
end $$;

create or replace function adjust_lot(p_lot bigint, p_new_qty int, p_reason text, p_note text default null) returns int language plpgsql security definer set search_path = public as $$
declare l lots; diff int;
begin
  perform app.check_perm('adjustStock');
  select * into l from lots where id = p_lot for update; if not found then raise exception 'ไม่พบล็อต'; end if;
  if p_new_qty is null or p_new_qty < 0 then raise exception 'จำนวนไม่ถูกต้อง'; end if;
  diff := p_new_qty - l.qty_left; if diff = 0 then raise exception 'จำนวนเท่าเดิม'; end if;
  insert into stock_movements (product_id, lot_id, type, qty, note, staff_name) values (l.product_id, p_lot, 'adjust', diff, coalesce(p_reason, '') || coalesce(' - ' || p_note, '') || ' (ล็อต ' || coalesce(l.lot_no, '-') || ')', app.staff_name());
  return diff;
end $$;

create or replace function adjust_lot_cost(p_lot bigint, p_new_cost numeric) returns void language plpgsql security definer set search_path = public as $$
declare l lots;
begin
  perform app.check_perm('adjustStock');
  select * into l from lots where id = p_lot for update; if not found then raise exception 'ไม่พบล็อต'; end if;
  if p_new_cost is null or p_new_cost < 0 then raise exception 'ราคาทุนไม่ถูกต้อง'; end if;
  if round(p_new_cost, 4) = l.unit_cost then raise exception 'ราคาทุนเท่าเดิม'; end if;
  insert into stock_movements (product_id, lot_id, type, qty, note, staff_name) values (l.product_id, p_lot, 'cost_adjust', 0, 'ทุน ' || l.unit_cost || ' → ' || round(p_new_cost, 4), app.staff_name());
  update lots set unit_cost = round(p_new_cost, 4) where id = p_lot;
end $$;

-- ---------- purchase orders --------------------------------------------
create sequence if not exists po_seq;
create or replace function create_purchase_order(p jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare v_sup bigint := nullif(p->>'supplier_id', '')::bigint; v_po bigint; it jsonb;
begin
  perform app.check_perm('receive');
  if v_sup is null and coalesce(trim(p->>'supplier_name'), '') <> '' then
    select id into v_sup from suppliers where lower(name) = lower(trim(p->>'supplier_name')) limit 1;
    if v_sup is null then insert into suppliers (name) values (trim(p->>'supplier_name')) returning id into v_sup; end if;
  end if;
  if v_sup is null then raise exception 'ใส่ชื่อผู้จำหน่ายก่อน'; end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'ยังไม่มีรายการที่สั่ง'; end if;
  insert into purchase_orders (no, supplier_id, ordered_on, note, staff_name)
  values ('PO' || lpad(nextval('po_seq')::text, 5, '0'), v_sup, coalesce((p->>'ordered_on')::date, app.local_date(now())), p->>'note', app.staff_name()) returning id into v_po;
  for it in select * from jsonb_array_elements(p->'items') loop
    insert into purchase_order_lines (po_id, product_id, qty, unit_cost) values (v_po, (it->>'product_id')::bigint, (it->>'qty')::int, coalesce((it->>'unit_cost')::numeric, 0));
  end loop;
  return v_po;
end $$;

create or replace function cancel_purchase_order(p_po bigint) returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.check_perm('receive');
  if exists (select 1 from purchase_order_lines where po_id = p_po and received_qty > 0) then raise exception 'ใบนี้รับของไปแล้วบางส่วน ใช้ปิดใบสั่งซื้อแทน'; end if;
  update purchase_orders set status = 'cancel' where id = p_po;
end $$;

create or replace function close_purchase_order(p_po bigint) returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.check_perm('receive');
  update purchase_orders set status = 'closed' where id = p_po and status in ('open', 'partial');
end $$;

-- ---------- product drug types (bulk assign screen) ---------------------
create or replace function set_drug_type(p_products bigint[], p_type text, p_on boolean) returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform app.check_perm('manage');
  if p_on then
    insert into product_drug_types (product_id, type_code) select unnest(p_products), p_type on conflict do nothing;
  else
    delete from product_drug_types where product_id = any (p_products) and type_code = p_type;
  end if;
  get diagnostics n = row_count;
  insert into audit_log (staff_name, entity, entity_id, action, detail) values (app.staff_name(), 'product_drug_types', p_type, case when p_on then 'add' else 'remove' end, jsonb_build_object('products', p_products));
  return n;
end $$;

-- ---------- master data (checked writes) --------------------------------
-- p: { id?, code, name, generic_name, category, unit, barcode, location, reg_no, manufacturer, pack_size, supplier_id,
--      reorder_point, order_qty, exp_warn_days, price1..price5, usage_text, indication, warning_text, storage_text,
--      meal_time, storage_type, note, active, drug_types:[codes] }
create or replace function save_product(p jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint := nullif(p->>'id', '')::bigint; v_cat int; v_old products;
begin
  perform app.check_perm('manage');
  if coalesce(trim(p->>'name'), '') = '' or coalesce(trim(p->>'code'), '') = '' then raise exception 'ต้องมีรหัสและชื่อสินค้า'; end if;
  if nullif(p->>'category', '') is not null then
    insert into categories (name) values (trim(p->>'category')) on conflict (name) do nothing;
    select id into v_cat from categories where name = trim(p->>'category');
  end if;
  if v_id is null then
    insert into products (code, name, generic_name, category_id, unit, barcode, location, reg_no, manufacturer, pack_size, supplier_id, reorder_point, order_qty, exp_warn_days,
                          price1, price2, price3, price4, price5, usage_text, indication, warning_text, storage_text, meal_time, storage_type, note, active, is_supply)
    values (trim(p->>'code'), trim(p->>'name'), p->>'generic_name', v_cat, coalesce(nullif(p->>'unit', ''), 'ชิ้น'), nullif(p->>'barcode', ''), p->>'location', p->>'reg_no', p->>'manufacturer', p->>'pack_size',
            nullif(p->>'supplier_id', '')::bigint, coalesce((p->>'reorder_point')::int, 0), coalesce((p->>'order_qty')::int, 0), coalesce((p->>'exp_warn_days')::int, 0),
            coalesce((p->>'price1')::numeric, 0), (p->>'price2')::numeric, (p->>'price3')::numeric, (p->>'price4')::numeric, (p->>'price5')::numeric,
            p->>'usage_text', p->>'indication', p->>'warning_text', p->>'storage_text', nullif(p->>'meal_time', ''), nullif(p->>'storage_type', ''), p->>'note',
            coalesce((p->>'active')::boolean, true), coalesce((p->>'is_supply')::boolean, false)) returning id into v_id;
  else
    select * into v_old from products where id = v_id for update; if not found then raise exception 'ไม่พบสินค้า'; end if;
    update products set code = trim(p->>'code'), name = trim(p->>'name'), generic_name = p->>'generic_name', category_id = v_cat, unit = coalesce(nullif(p->>'unit', ''), unit),
      barcode = nullif(p->>'barcode', ''), location = p->>'location', reg_no = p->>'reg_no', manufacturer = p->>'manufacturer', pack_size = p->>'pack_size',
      supplier_id = nullif(p->>'supplier_id', '')::bigint, reorder_point = coalesce((p->>'reorder_point')::int, 0), order_qty = coalesce((p->>'order_qty')::int, 0), exp_warn_days = coalesce((p->>'exp_warn_days')::int, 0),
      price1 = coalesce((p->>'price1')::numeric, 0), price2 = (p->>'price2')::numeric, price3 = (p->>'price3')::numeric, price4 = (p->>'price4')::numeric, price5 = (p->>'price5')::numeric,
      usage_text = p->>'usage_text', indication = p->>'indication', warning_text = p->>'warning_text', storage_text = p->>'storage_text',
      meal_time = nullif(p->>'meal_time', ''), storage_type = nullif(p->>'storage_type', ''), note = p->>'note', active = coalesce((p->>'active')::boolean, true), updated_at = now()
     where id = v_id;
    if v_old.price1 <> coalesce((p->>'price1')::numeric, 0) or v_old.active <> coalesce((p->>'active')::boolean, true) then
      insert into audit_log (staff_name, entity, entity_id, action, detail) values (app.staff_name(), 'products', v_id::text, 'update',
        jsonb_build_object('price1', jsonb_build_array(v_old.price1, coalesce((p->>'price1')::numeric, 0)), 'active', jsonb_build_array(v_old.active, coalesce((p->>'active')::boolean, true))));
    end if;
  end if;
  if jsonb_typeof(p->'drug_types') = 'array' then
    delete from product_drug_types where product_id = v_id;
    insert into product_drug_types select v_id, x from jsonb_array_elements_text(p->'drug_types') x on conflict do nothing;
  end if;
  if p ? 'latest_cost' then update products set latest_cost = greatest(coalesce((p->>'latest_cost')::numeric, 0), 0) where id = v_id; end if;
  if p ? 'bundle' then
    delete from product_bundles where bundle_id = v_id;
    if jsonb_typeof(p->'bundle') = 'array' then
      insert into product_bundles (bundle_id, part_id, qty) select v_id, (x->>'part_id')::bigint, (x->>'qty')::int from jsonb_array_elements(p->'bundle') x where (x->>'part_id')::bigint <> v_id on conflict do nothing;
    end if;
  end if;
  if p ? 'unpack' then
    delete from product_unpack where parent_id = v_id;
    if jsonb_typeof(p->'unpack') = 'object' and coalesce((p->'unpack'->>'ratio')::int, 0) >= 2 then
      insert into product_unpack (parent_id, child_id, ratio) values (v_id, (p->'unpack'->>'child_id')::bigint, (p->'unpack'->>'ratio')::int);
    end if;
  end if;
  return v_id;
end $$;

create or replace function save_supplier(p jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint := nullif(p->>'id', '')::bigint;
begin
  perform app.check_perm('receive');
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'ใส่ชื่อผู้จำหน่ายก่อน'; end if;
  if v_id is null then
    insert into suppliers (code, name, address, province, zip, phone, fax, tax_id, contact_name, contact_mobile, open_time, close_time, note)
    values (nullif(p->>'code', ''), trim(p->>'name'), p->>'address', p->>'province', p->>'zip', p->>'phone', p->>'fax', p->>'tax_id', p->>'contact_name', p->>'contact_mobile',
            nullif(p->>'open_time', ''), nullif(p->>'close_time', ''), p->>'note') returning id into v_id;
  else
    update suppliers set code = nullif(p->>'code', ''), name = trim(p->>'name'), address = p->>'address', province = p->>'province', zip = p->>'zip', phone = p->>'phone', fax = p->>'fax',
      tax_id = p->>'tax_id', contact_name = p->>'contact_name', contact_mobile = p->>'contact_mobile', open_time = nullif(p->>'open_time', ''), close_time = nullif(p->>'close_time', ''),
      note = p->>'note', active = coalesce((p->>'active')::boolean, true) where id = v_id;
  end if;
  if jsonb_typeof(p->'terms') = 'array' then
    delete from supplier_terms where supplier_id = v_id;
    insert into supplier_terms (supplier_id, product_id, buy_qty, free_qty)
      select v_id, (t->>'product_id')::bigint, (t->>'buy_qty')::int, (t->>'free_qty')::int from jsonb_array_elements(p->'terms') t
       where coalesce((t->>'buy_qty')::int, 0) > 0 and coalesce((t->>'free_qty')::int, 0) > 0 and exists (select 1 from products where id = (t->>'product_id')::bigint)
      on conflict do nothing;
  end if;
  return v_id;
end $$;

create or replace function save_customer(p jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint := nullif(p->>'id', '')::bigint; a jsonb;
begin
  perform app.check_perm('members');
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'ใส่ชื่อก่อน'; end if;
  if v_id is null then
    insert into customers (code, name, phone, note) values (nullif(p->>'code', ''), trim(p->>'name'), p->>'phone', p->>'note') returning id into v_id;
  else
    update customers set code = nullif(p->>'code', ''), name = trim(p->>'name'), phone = p->>'phone', note = p->>'note' where id = v_id;
  end if;
  if jsonb_typeof(p->'allergies') = 'array' then
    delete from customer_allergies where customer_id = v_id;
    for a in select * from jsonb_array_elements(p->'allergies') loop
      if coalesce(trim(a->>'drug'), '') <> '' then insert into customer_allergies (customer_id, drug, reaction) values (v_id, trim(a->>'drug'), a->>'reaction'); end if;
    end loop;
  end if;
  return v_id;
end $$;

-- p: { login, display_name, emp_id, license_no, role_label, is_admin, active, work_start, work_end, permissions:[codes], auth_user_id }
create or replace function save_staff(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_login text := lower(trim(p->>'login')); others int;
begin
  if not (app.is_service() or app.open_mode() or exists (select 1 from staff s where s.auth_user_id = app.uid() and s.is_admin and s.active)) then
    raise exception 'เฉพาะผู้ดูแลระบบเท่านั้น' using errcode = '42501';
  end if;
  if v_login is null or v_login = '' or v_login ~ '[\s@]' then raise exception 'ชื่อ Login ไม่ถูกต้อง'; end if;
  if v_id is null then
    insert into staff (auth_user_id, login, emp_id, display_name, license_no, role_label, is_admin, active, work_start, work_end)
    values (nullif(p->>'auth_user_id', '')::uuid, v_login, p->>'emp_id', coalesce(nullif(trim(p->>'display_name'), ''), v_login), p->>'license_no', p->>'role_label',
            coalesce((p->>'is_admin')::boolean, false), coalesce((p->>'active')::boolean, true), nullif(p->>'work_start', '')::time, nullif(p->>'work_end', '')::time) returning id into v_id;
  else
    select count(*) into others from staff where id <> v_id and is_admin and active;
    if others = 0 and exists (select 1 from staff where is_admin and active) and not (coalesce((p->>'is_admin')::boolean, false) and coalesce((p->>'active')::boolean, true)) then
      raise exception 'ต้องมีผู้ดูแลที่ใช้งานอยู่อย่างน้อย 1 คน';
    end if;
    update staff set auth_user_id = coalesce(nullif(p->>'auth_user_id', '')::uuid, auth_user_id), login = v_login, emp_id = p->>'emp_id', display_name = coalesce(nullif(trim(p->>'display_name'), ''), v_login),
      license_no = p->>'license_no', role_label = p->>'role_label', is_admin = coalesce((p->>'is_admin')::boolean, false), active = coalesce((p->>'active')::boolean, true),
      work_start = nullif(p->>'work_start', '')::time, work_end = nullif(p->>'work_end', '')::time where id = v_id;
  end if;
  if jsonb_typeof(p->'permissions') = 'array' then
    delete from staff_permissions where staff_id = v_id;
    insert into staff_permissions select v_id, x from jsonb_array_elements_text(p->'permissions') x where x in (select code from permissions);
  end if;
  insert into audit_log (staff_name, entity, entity_id, action, detail) values (app.staff_name(), 'staff', v_id::text, 'save', jsonb_build_object('login', v_login, 'admin', coalesce((p->>'is_admin')::boolean, false)));
  return v_id;
end $$;
