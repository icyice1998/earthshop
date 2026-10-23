# Earthshop - คู่มือสำหรับคนที่มาพัฒนาต่อ

ระบบ POS ร้านยา (แทน SmartDrugstore 2020) เป็นแอปไฟล์เดียว (`index.html`) ต่อกับ Supabase (PostgreSQL)

## โครงสร้างโปรเจกต์

```
index.html                  แอปทั้งหมด: Vue 3 (Options API) + Tailwind จาก CDN
db/01_schema.sql ... 08_supplies.sql   ตาราง ฟังก์ชัน สิทธิ์ รายงาน (รันตามลำดับ)
db/deploy_all.sql           รวม 01-08 สำหรับวางใน Supabase SQL Editor
db/tests/*.sql              เทสต์ฟังก์ชัน/สิทธิ์/รายงานในฐานข้อมูล
db/migrate_drgstr.py        แปลงข้อมูลจาก SmartDrugstore (drgstr.sql)
dev/dbtest/                 เทสต์ทั้งแอปในโหมดฐานข้อมูล (Node + Playwright + Postgres)
dev/mock/                   สร้างหน้าเดโม (ข้อมูลสมมติ)
tools/print-bridge/         bridge.js ส่งงานพิมพ์ไปเครื่องพิมพ์สลิปในวงแลน
```

## สองโหมดของแอป

- **โหมดเดิม**: เก็บข้อมูลเป็นเอกสาร JSON เดียว (Supabase ของโปรเจกต์เดิม) ล็อกอินด้วย `ชื่อผู้ใช้@knockdown-shop.com`
- **โหมดฐานข้อมูลใหม่** (`DB_MODE`): ใช้ตารางจริงบน Supabase ล็อกอินด้วย `ชื่อผู้ใช้@mypharm.com` เปิดโดยใส่ค่าในหน้า login หรือเปิดลิงก์ตั้งค่า:
  `index.html#dburl=https://<project>.supabase.co&dbkey=<publishable key>`
- ใช้ได้เฉพาะ anon / publishable key ห้ามใส่ service_role key หรือรหัสผ่านฐานข้อมูลในโค้ด ลิงก์ หรือ commit

## หลักการสำคัญของฐานข้อมูล

- ปฏิเสธโดยค่าเริ่มต้น: ผู้ใช้อ่านตารางตรงๆ ไม่ได้ อ่านผ่าน view `v_*` เท่านั้น (view ซ่อนต้นทุนถ้าไม่มีสิทธิ์ `viewCost`) และเขียนผ่านฟังก์ชัน `security definer` ที่เรียก `app.check_perm('...')`
- สต็อกเป็นแบบล็อต (FEFO: หมดอายุก่อนออกก่อน) และ `lots.qty_left` ต้องเท่ากับผลรวมของ `stock_movements` เสมอ (ตัวทริกเกอร์คุม) ห้ามแก้ตัวเลขตรงๆ
- เพิ่มตารางใหม่หลัง 03_security.sql ต้องสั่ง `enable row level security` และ `revoke all` เอง
- เพิ่มสิทธิ์ใหม่: เพิ่มแถวใน `permissions`, เพิ่มใน `PERM_GROUPS` ใน index.html และเช็กด้วย `can('...')` ในหน้า
- ถ้าเพิ่มฟังก์ชันใหม่ ให้ใส่ไว้ในไฟล์ `db/NN_*.sql` และสร้าง `deploy_all.sql` ใหม่:
  `cat 01_schema.sql ... 08_supplies.sql > deploy_all.sql` แล้วปิดท้ายด้วย `notify pgrst, 'reload schema';`

## รันเทสต์

ต้องมี PostgreSQL 16, Node.js 18+ และ Playwright (มี Chromium)

```
# 1) สร้างและเปิดฐานข้อมูลทดสอบ (ครั้งแรก)
initdb -D /tmp/pgtest -A trust
pg_ctl -D /tmp/pgtest -o "-p 55432 -k /tmp/pgtest" -l /tmp/pgtest.log start

# 2) เทสต์ทั้งแอปในโหมดฐานข้อมูล (สร้างฐาน pharm_app ใหม่ทุกครั้งจาก db/01-08)
cd dev/dbtest
npm install
PW=<path ของ playwright> node test_app_db.js     # ทุกบรรทัดต้องขึ้น "ok", ไม่มี FAIL

# 3) เทสต์ SQL เดี่ยวๆ
psql -p 55432 -h /tmp/pgtest -d <db> -f db/tests/test_functions.sql
```

- ตัวแปร: `PGSOCK` (โฟลเดอร์ socket, ค่าเริ่มต้น `/tmp/pgtest`), `PGPORT` (55432), `PW` (ที่อยู่ playwright), `LIB` (โฟลเดอร์ที่มี vue.js และ tw.js ถ้าไม่ต่อ CDN)
- ถ้า Postgres หยุดไปให้สั่ง `pg_ctl start` ใหม่ (ในคอนเทนเนอร์ต้องรันด้วยผู้ใช้ `postgres`)
- เปิดแอปในเทสต์ผ่าน `window.__vm` (instance ของ Vue) ดูตัวอย่างใน `test_app_db.js`
- เพิ่มฟีเจอร์แล้วให้เพิ่มเช็กใน `test_app_db.js` และรันให้ผ่านก่อน push

## พิมพ์สลิป/ฉลาก

- แอปวาดสลิปเป็นภาพบน canvas แล้วแปลงเป็นคำสั่ง ESC/POS raster (ภาษาไทยจึงไม่เพี้ยน) ส่งไป `tools/print-bridge/bridge.js` ซึ่งต่อ TCP พอร์ต 9100 ของเครื่องพิมพ์
- ทดสอบเครื่องพิมพ์ไม่ผ่านแอป: `node bridge.js --selftest <IP> 9100` (หรือ `test-printer.bat`)
- รายละเอียดอยู่ใน `tools/print-bridge/README.md`

## ข้อมูลที่ห้าม commit

ไฟล์ dump จากระบบเดิม (`drgstr.sql`), CSV รายชื่อยา/สมาชิกจริง, service_role key, รหัสผ่านฐานข้อมูล, ไฟล์ `.env`

## งานที่ยังไม่ทำในโหมดฐานข้อมูลใหม่

ส่งคืนผู้จำหน่าย, แกะแบ่งขาย (unpack), แก้ใบรับเข้าหลังบันทึก, บันทึก/นัดติดตามสมาชิก, ปิดวัน, กู้คืนทั้งระบบในหน้าเว็บ (ตอนนี้กู้คืนได้เฉพาะข้อมูลหลัก)
ฟังก์ชันเหล่านี้ตอนนี้ขึ้นข้อความ "ยังไม่รองรับในโหมดฐานข้อมูลใหม่" ดู `DB_UNSUPPORTED` ใน index.html

## ขั้นตอนส่งงาน

1. แตก branch จาก `stock-table-view`: `git checkout -b feature/<ชื่องาน>`
2. แก้ แล้วรันเทสต์ให้ผ่าน
3. push และเปิด Pull Request กลับเข้า `stock-table-view`
