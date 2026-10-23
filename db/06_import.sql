-- =====================================================================
-- Pharmacy database: in-app import from SmartDrugstore (admin only)
-- Run after 01-05. Safe to run on a project that already has 01-05 (adds one column and one function).
-- =====================================================================
alter table lots add column if not exists legacy_key text;
create unique index if not exists lots_legacy_key_idx on lots (legacy_key) where legacy_key is not null;

-- p: { kind: 'lots' | 'sales' | 'finalize', rows: [...] }
--   lots     rows: { key, product_code, lot_no, exp_date, received_on, qty_in, unit_cost }
--   sales    rows: { bill_no, ts, staff, customer_code, subtotal, discount, total, method, received, change, buyer:{name,addr,type}, rx:{doc,doc_addr,user,age,addr},
--                    lines:[{ product_code, name, unit, qty, price, cost_total, allocs:[{ key, qty }] }] }
--   finalize rows: { key, qty_left }   (adjusts each imported lot to the stock the old program showed)
-- Already imported rows are skipped, so a failed import can simply be run again.
create or replace function import_smart(p jsonb) returns int language plpgsql security definer set search_path = public as $$
declare k text := p->>'kind'; r jsonb; ln jsonb; al jsonb; n int := 0; v_pid bigint; v_lot lots; v_sale bigint; v_line bigint; v_ts timestamptz; v_take int; v_diff int;
begin
  if not (app.is_service() or app.open_mode() or exists (select 1 from staff s where s.auth_user_id = app.uid() and s.is_admin and s.active)) then
    raise exception 'เฉพาะผู้ดูแลระบบเท่านั้น' using errcode = '42501';
  end if;
  if k = 'lots' then
    for r in select * from jsonb_array_elements(p->'rows') loop
      select id into v_pid from products where code = r->>'product_code';
      if v_pid is null or exists (select 1 from lots where legacy_key = r->>'key') then continue; end if;
      insert into lots (product_id, lot_no, exp_date, received_on, qty_in, qty_left, unit_cost, source, legacy_key)
      values (v_pid, nullif(r->>'lot_no', ''), nullif(r->>'exp_date', '')::date, coalesce(nullif(r->>'received_on', '')::date, current_date), greatest((r->>'qty_in')::int, 0), 0,
              coalesce((r->>'unit_cost')::numeric, 0), 'opening', r->>'key') returning * into v_lot;
      if v_lot.qty_in > 0 then
        insert into stock_movements (ts, product_id, lot_id, type, qty, note, staff_name)
        values ((coalesce(nullif(r->>'received_on', ''), '2000-01-01') || ' 09:00+07')::timestamptz, v_pid, v_lot.id, 'opening', v_lot.qty_in, 'ย้ายจากระบบเดิม', 'ย้ายจากระบบเดิม');
      end if;
      n := n + 1;
    end loop;
  elsif k = 'sales' then
    for r in select * from jsonb_array_elements(p->'rows') loop
      if exists (select 1 from sales where bill_no = r->>'bill_no') then continue; end if;
      v_ts := (r->>'ts')::timestamptz;
      insert into sales (bill_no, ts, sale_date, customer_id, staff_name, subtotal, discount, total, method, received, change_amount, status, buyer_name, buyer_addr, buyer_type,
                         rx_prescriber, rx_prescriber_addr, rx_user, rx_user_age, rx_user_addr, imported)
      values (r->>'bill_no', v_ts, app.local_date(v_ts), (select id from customers where code = nullif(r->>'customer_code', '')), r->>'staff', coalesce((r->>'subtotal')::numeric, 0), coalesce((r->>'discount')::numeric, 0),
              coalesce((r->>'total')::numeric, 0), coalesce(nullif(r->>'method', ''), 'cash'), (r->>'received')::numeric, (r->>'change')::numeric, 'ok',
              nullif(r#>>'{buyer,name}', ''), r#>>'{buyer,addr}', r#>>'{buyer,type}', r#>>'{rx,doc}', r#>>'{rx,doc_addr}', r#>>'{rx,user}', r#>>'{rx,age}', r#>>'{rx,addr}', true) returning id into v_sale;
      for ln in select * from jsonb_array_elements(r->'lines') loop
        select id into v_pid from products where code = nullif(ln->>'product_code', '');
        insert into sale_lines (sale_id, line_no, product_id, name, unit, qty, unit_price, line_total, cost_total)
        values (v_sale, (select coalesce(max(line_no), 0) + 1 from sale_lines where sale_id = v_sale), v_pid, coalesce(nullif(ln->>'name', ''), 'สินค้า'), ln->>'unit', greatest((ln->>'qty')::int, 1),
                coalesce((ln->>'price')::numeric, 0), round(greatest((ln->>'qty')::int, 1) * coalesce((ln->>'price')::numeric, 0), 2), coalesce((ln->>'cost_total')::numeric, 0)) returning id into v_line;
        for al in select * from jsonb_array_elements(coalesce(ln->'allocs', '[]'::jsonb)) loop
          select * into v_lot from lots where legacy_key = al->>'key' for update;
          if not found then continue; end if;
          v_take := least((al->>'qty')::int, v_lot.qty_left);
          if v_take <= 0 then continue; end if;
          insert into sale_line_lots (sale_line_id, lot_id, qty, unit_cost) values (v_line, v_lot.id, v_take, v_lot.unit_cost)
            on conflict (sale_line_id, lot_id) do update set qty = sale_line_lots.qty + excluded.qty;
          insert into stock_movements (ts, product_id, lot_id, type, qty, ref_no, staff_name) values (v_ts, v_lot.product_id, v_lot.id, 'sale', -v_take, r->>'bill_no', r->>'staff');
        end loop;
      end loop;
      n := n + 1;
    end loop;
  elsif k = 'finalize' then
    for r in select * from jsonb_array_elements(p->'rows') loop
      select * into v_lot from lots where legacy_key = r->>'key' for update;
      if not found then continue; end if;
      v_diff := greatest((r->>'qty_left')::int, 0) - v_lot.qty_left;
      if v_diff <> 0 then
        insert into stock_movements (product_id, lot_id, type, qty, note, staff_name) values (v_lot.product_id, v_lot.id, 'adjust', v_diff, 'ปรับให้ตรงยอดคงเหลือของระบบเดิม', 'ย้ายจากระบบเดิม');
        n := n + 1;
      end if;
    end loop;
  else
    raise exception 'ไม่รู้จักชนิดข้อมูล: %', k;
  end if;
  return n;
end $$;
revoke execute on function import_smart(jsonb) from public;
grant execute on function import_smart(jsonb) to authenticated;
