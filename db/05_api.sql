-- =====================================================================
-- Pharmacy database: functions the app calls for settings and the PIN
-- Run after 01-04.
-- =====================================================================

-- the confirmation PIN lives in its own table that no view exposes; the app can only ask "is this PIN right?"
create table if not exists shop_secret (
  id       int primary key default 1 check (id = 1),
  pin_salt text,
  pin_hash text
);
insert into shop_secret (id) values (1) on conflict do nothing;
alter table shop_secret enable row level security;
revoke all on shop_secret from anon, authenticated;

create or replace function app.pin_digest(p_salt text, p_pin text) returns text language sql immutable as $$
  select encode(sha256(convert_to(p_salt || ':' || p_pin, 'UTF8')), 'hex')
$$;

create or replace function pin_is_set() returns boolean language sql stable security definer set search_path = public as $$
  select app.uid() is not null and exists (select 1 from shop_secret where pin_hash is not null)
$$;

create or replace function verify_pin(p_pin text) returns boolean language plpgsql stable security definer set search_path = public as $$
declare s shop_secret;
begin
  if app.uid() is null and not app.is_service() then raise exception 'ต้องเข้าสู่ระบบก่อน' using errcode = '42501'; end if;
  select * into s from shop_secret where id = 1;
  if s.pin_hash is null then return false; end if;
  return s.pin_hash = app.pin_digest(s.pin_salt, coalesce(p_pin, ''));
end $$;

-- first time (no PIN yet) or open mode: anyone logged in may set it. Otherwise an active admin who knows the old PIN.
create or replace function set_pin(p_old text, p_new text) returns void language plpgsql security definer set search_path = public as $$
declare s shop_secret; v_salt text;
begin
  if app.uid() is null and not app.is_service() then raise exception 'ต้องเข้าสู่ระบบก่อน' using errcode = '42501'; end if;
  if p_new is null or p_new !~ '^\d{4,8}$' then raise exception 'PIN ต้องเป็นตัวเลข 4-8 หลัก'; end if;
  if p_new = '1234' then raise exception 'ห้ามใช้ PIN 1234 ซึ่งเป็นค่าเริ่มต้น'; end if;
  select * into s from shop_secret where id = 1;
  if s.pin_hash is not null and not app.open_mode() and not app.is_service() then
    if not exists (select 1 from staff x where x.auth_user_id = app.uid() and x.is_admin and x.active) then raise exception 'เฉพาะผู้ดูแลระบบเท่านั้น' using errcode = '42501'; end if;
    if s.pin_hash <> app.pin_digest(s.pin_salt, coalesce(p_old, '')) then raise exception 'PIN เดิมไม่ถูกต้อง'; end if;
  end if;
  v_salt := encode(sha256(convert_to(gen_random_uuid()::text, 'UTF8')), 'hex');
  update shop_secret set pin_salt = v_salt, pin_hash = app.pin_digest(v_salt, p_new) where id = 1;
  insert into audit_log (staff_name, entity, entity_id, action) values (app.staff_name(), 'shop', '1', 'set_pin');
end $$;

-- p: { name, name_en, address, province, zip, phone, fax, tax_id, license_no, pharmacist_name, branch_code, branch_name, open_time, close_time, near_expiry_days, settings:{...merged} }
create or replace function save_shop(p jsonb) returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.check_perm('settings');
  update shop set
    name = coalesce(nullif(trim(p->>'name'), ''), name),
    name_en = case when p ? 'name_en' then p->>'name_en' else name_en end,
    address = case when p ? 'address' then p->>'address' else address end,
    province = case when p ? 'province' then p->>'province' else province end,
    zip = case when p ? 'zip' then p->>'zip' else zip end,
    phone = case when p ? 'phone' then p->>'phone' else phone end,
    fax = case when p ? 'fax' then p->>'fax' else fax end,
    tax_id = case when p ? 'tax_id' then p->>'tax_id' else tax_id end,
    license_no = case when p ? 'license_no' then p->>'license_no' else license_no end,
    pharmacist_name = case when p ? 'pharmacist_name' then p->>'pharmacist_name' else pharmacist_name end,
    branch_code = case when p ? 'branch_code' then p->>'branch_code' else branch_code end,
    branch_name = case when p ? 'branch_name' then p->>'branch_name' else branch_name end,
    open_time = case when p ? 'open_time' then nullif(p->>'open_time', '') else open_time end,
    close_time = case when p ? 'close_time' then nullif(p->>'close_time', '') else close_time end,
    near_expiry_days = coalesce((p->>'near_expiry_days')::int, near_expiry_days),
    settings = case when jsonb_typeof(p->'settings') = 'object' then settings || (p->'settings') else settings end
   where id = 1;
  insert into audit_log (staff_name, entity, entity_id, action) values (app.staff_name(), 'shop', '1', 'save');
end $$;

create or replace function has_admin() returns boolean language sql stable security definer set search_path = public as $$
  select app.uid() is not null and exists (select 1 from staff where is_admin and active)
$$;

-- opening stock for a new product (or a lot found on the shelf): creates a lot and its movement
create or replace function open_stock(p_product bigint, p_qty int, p_cost numeric default null, p_lot_no text default null, p_exp date default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_lot bigint; prod products;
begin
  perform app.check_perm('manage');
  select * into prod from products where id = p_product; if not found then raise exception 'ไม่พบสินค้า'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'จำนวนต้องมากกว่า 0'; end if;
  insert into lots (product_id, lot_no, exp_date, received_on, qty_in, qty_left, unit_cost, source)
  values (p_product, nullif(trim(p_lot_no), ''), p_exp, app.local_date(now()), p_qty, 0, coalesce(p_cost, prod.latest_cost), 'opening') returning id into v_lot;
  insert into stock_movements (product_id, lot_id, type, qty, note, staff_name) values (p_product, v_lot, 'opening', p_qty, 'ยอดยกมา', app.staff_name());
  if p_cost is not null then update products set latest_cost = p_cost where id = p_product; end if;
  return v_lot;
end $$;

create or replace view v_product_unpack as select * from product_unpack where app.has_perm('pos') or app.has_perm('stock') or app.has_perm('manage');
grant select on v_product_unpack to authenticated;

-- called once after login: a staff row created by an admin before the person's first login is linked to their auth account by login name
create or replace function claim_staff() returns void language plpgsql security definer set search_path = public as $$
declare v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb; v_login text;
begin
  if app.uid() is null then return; end if;
  v_login := lower(split_part(coalesce(v_claims->>'email', ''), '@', 1));
  if v_login = '' or exists (select 1 from staff x where x.auth_user_id = app.uid()) then return; end if;
  -- link by login name when the staff row is not linked yet, or is linked to a login that no longer exists (for example the account was deleted and created again with another email domain)
  if to_regclass('auth.users') is not null then
    execute 'update staff set auth_user_id = $1 where login = $2 and (auth_user_id is null or not exists (select 1 from auth.users u where u.id = staff.auth_user_id))' using app.uid(), v_login;
  else
    update staff set auth_user_id = app.uid() where login = v_login and auth_user_id is null;
  end if;
end $$;

do $$ declare f text; begin
  foreach f in array array['claim_staff()', 'has_admin()', 'open_stock(bigint,int,numeric,text,date)', 'pin_is_set()', 'verify_pin(text)', 'set_pin(text,text)', 'save_shop(jsonb)']
  loop execute format('revoke execute on function public.%s from public', f); execute format('grant execute on function public.%s to authenticated', f); end loop;
end $$;

-- the login screen shows the shop name before anyone is logged in: only the name is exposed, nothing else
create or replace function shop_public() returns text language sql stable security definer set search_path = public as $$
  select nullif(trim(name), '') from shop where id = 1
$$;
revoke execute on function shop_public() from public;
grant execute on function shop_public() to anon, authenticated;
