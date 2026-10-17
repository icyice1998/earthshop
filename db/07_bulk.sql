-- =====================================================================
-- Pharmacy database: bulk save for CSV upload and the management grid
-- Run after 01-06. Safe to run more than once.
-- Each item is saved on its own, so one bad row does not stop the others; the result lists what happened to every row.
-- =====================================================================

-- p: { items: [ { ...save_product fields..., stock?: counted quantity } ] }
-- returns [ { code, id, ok, error } ]
create or replace function bulk_save_products(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; res jsonb := '[]'::jsonb; v_id bigint; v_counted int;
begin
  perform app.check_perm('manage');
  if jsonb_typeof(p->'items') <> 'array' then raise exception 'ไม่มีรายการ'; end if;
  if jsonb_array_length(p->'items') > 500 then raise exception 'ส่งทีละไม่เกิน 500 รายการ'; end if;
  for it in select * from jsonb_array_elements(p->'items') loop
    begin
      -- a row sent again after a lost connection finds its product by code instead of failing as a duplicate
      if nullif(it->>'id', '') is null then
        select id into v_id from products where code = trim(it->>'code');
        if v_id is not null then it := jsonb_set(it, '{id}', to_jsonb(v_id)); end if;
      end if;
      v_id := save_product(it - 'stock');
      if it ? 'stock' and nullif(it->>'stock', '') is not null then
        v_counted := (it->>'stock')::int;
        if v_counted is distinct from app.stock_of(v_id) and not exists (select 1 from product_bundles where bundle_id = v_id) then
          perform adjust_stock(v_id, v_counted, 'ปรับจากไฟล์ CSV / ตารางจัดการ', null);
        end if;
      end if;
      res := res || jsonb_build_array(jsonb_build_object('code', it->>'code', 'id', v_id, 'ok', true));
    exception when others then
      res := res || jsonb_build_array(jsonb_build_object('code', it->>'code', 'ok', false, 'error', sqlerrm));
    end;
  end loop;
  return res;
end $$;

-- p: { items: [ { id?, code, name, phone, note, allergies: [{drug, reaction}] } ] }
create or replace function bulk_save_customers(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; res jsonb := '[]'::jsonb; v_id bigint;
begin
  perform app.check_perm('members');
  if jsonb_typeof(p->'items') <> 'array' then raise exception 'ไม่มีรายการ'; end if;
  if jsonb_array_length(p->'items') > 500 then raise exception 'ส่งทีละไม่เกิน 500 รายการ'; end if;
  for it in select * from jsonb_array_elements(p->'items') loop
    begin
      if nullif(it->>'id', '') is null and nullif(it->>'code', '') is not null then
        select id into v_id from customers where code = it->>'code';
        if v_id is not null then it := jsonb_set(it, '{id}', to_jsonb(v_id)); end if;
      end if;
      v_id := save_customer(it);
      res := res || jsonb_build_array(jsonb_build_object('code', it->>'code', 'id', v_id, 'ok', true));
    exception when others then
      res := res || jsonb_build_array(jsonb_build_object('code', it->>'code', 'ok', false, 'error', sqlerrm));
    end;
  end loop;
  return res;
end $$;

revoke execute on function bulk_save_products(jsonb) from public;
revoke execute on function bulk_save_customers(jsonb) from public;
grant execute on function bulk_save_products(jsonb) to authenticated;
grant execute on function bulk_save_customers(jsonb) to authenticated;
