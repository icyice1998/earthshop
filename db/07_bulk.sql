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

-- delete a product that has no history; otherwise it must be switched off ("active" unticked) so old bills stay intact
create or replace function delete_product(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare prod products;
begin
  perform app.check_perm('manage');
  select * into prod from products where id = p_id;
  if not found then raise exception 'ไม่พบสินค้า'; end if;
  if exists (select 1 from stock_movements where product_id = p_id) or exists (select 1 from lots where product_id = p_id)
     or exists (select 1 from sale_lines where product_id = p_id) or exists (select 1 from receipt_lines where product_id = p_id)
     or exists (select 1 from purchase_order_lines where product_id = p_id) or exists (select 1 from supplier_return_lines where product_id = p_id)
     or exists (select 1 from product_bundles where part_id = p_id) or exists (select 1 from product_unpack where child_id = p_id) then
    raise exception 'สินค้านี้มีประวัติแล้ว (ขาย รับเข้า หรือสต็อก) ลบไม่ได้ ให้ปิดใช้งานแทน (เอาติ๊ก "ใช้งาน" ออก)';
  end if;
  delete from products where id = p_id;
  insert into audit_log (staff_name, entity, entity_id, action, detail) values (app.staff_name(), 'products', p_id::text, 'delete', jsonb_build_object('code', prod.code, 'name', prod.name));
end $$;
revoke execute on function delete_product(bigint) from public;
grant execute on function delete_product(bigint) to authenticated;

-- p: { ids: [bigint] } -> [ { id, ok, error } ]  (rows with history are refused one by one, the rest are deleted)
create or replace function bulk_delete_products(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; res jsonb := '[]'::jsonb;
begin
  perform app.check_perm('manage');
  if jsonb_typeof(p->'ids') <> 'array' then raise exception 'ไม่มีรายการ'; end if;
  if jsonb_array_length(p->'ids') > 500 then raise exception 'ลบทีละไม่เกิน 500 รายการ'; end if;
  for v_id in select (x)::bigint from jsonb_array_elements_text(p->'ids') x loop
    begin
      perform delete_product(v_id);
      res := res || jsonb_build_array(jsonb_build_object('id', v_id, 'ok', true));
    exception when others then
      res := res || jsonb_build_array(jsonb_build_object('id', v_id, 'ok', false, 'error', sqlerrm));
    end;
  end loop;
  return res;
end $$;
revoke execute on function bulk_delete_products(jsonb) from public;
grant execute on function bulk_delete_products(jsonb) to authenticated;

-- deleting a member keeps the bills (they just no longer point at the member); allergies go with the member
create or replace function delete_customer(p_id bigint) returns void language plpgsql security definer set search_path = public as $$
declare c customers;
begin
  perform app.check_perm('members');
  select * into c from customers where id = p_id;
  if not found then raise exception 'ไม่พบสมาชิก'; end if;
  update sales set customer_id = null where customer_id = p_id;
  delete from customers where id = p_id;
  insert into audit_log (staff_name, entity, entity_id, action, detail) values (app.staff_name(), 'customers', p_id::text, 'delete', jsonb_build_object('code', c.code, 'name', c.name));
end $$;

create or replace function bulk_delete_customers(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; res jsonb := '[]'::jsonb;
begin
  perform app.check_perm('members');
  if jsonb_typeof(p->'ids') <> 'array' then raise exception 'ไม่มีรายการ'; end if;
  if jsonb_array_length(p->'ids') > 500 then raise exception 'ลบทีละไม่เกิน 500 รายการ'; end if;
  for v_id in select (x)::bigint from jsonb_array_elements_text(p->'ids') x loop
    begin
      perform delete_customer(v_id);
      res := res || jsonb_build_array(jsonb_build_object('id', v_id, 'ok', true));
    exception when others then
      res := res || jsonb_build_array(jsonb_build_object('id', v_id, 'ok', false, 'error', sqlerrm));
    end;
  end loop;
  return res;
end $$;
revoke execute on function delete_customer(bigint) from public;
revoke execute on function bulk_delete_customers(jsonb) from public;
grant execute on function delete_customer(bigint) to authenticated;
grant execute on function bulk_delete_customers(jsonb) to authenticated;
