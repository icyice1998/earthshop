New relational database (PostgreSQL / Supabase) for the pharmacy app

Files
  01_schema.sql      tables, constraints, triggers
  02_functions.sql   sell / receive / adjust / void functions (SECURITY DEFINER)
  03_security.sql    RLS deny-by-default, read views without cost, role checks
  04_reports.sql     report_sales, report_ky9, report_ky12, report_ky_lots (ข.ย.10/11/13)
  migrate_drgstr.py  SmartDrugstore dump -> CSV + load.sql (no passwords migrated)
  verify.py          compares loaded database with expected.json (local test use)
  verify_reports.py  recomputes report and ข.ย. numbers in Python from the migration files and compares
  tests/             SQL tests for functions and security

Local test
  python3 -I migrate_drgstr.py DUMP.sql OUTDIR
  createdb pharm; psql -d pharm -f 01_schema.sql -f 02_functions.sql -f 03_security.sql -f 04_reports.sql
  cd OUTDIR; psql -d pharm -v ON_ERROR_STOP=1 -f load.sql

Deploy to your own Supabase project
  1. Supabase dashboard > SQL Editor: run 01, 02, 03, 04 in order.
  2. Load data from your own computer with psql using the project connection string
     (Settings > Database). Keep that password private; do not paste it in chat or commit it.
  3. Create staff logins in Authentication, then link each to a staff row.
  4. Never commit OUTDIR: it contains customer and sales data.

Verified on the real dump: 87,842 bills, 154,742 lines, 4,234 lots, stock 6,497 units,
sales total 8,097,736.00, lot quantity = sum of movements for every lot.

Reports (call as supabase.rpc or select * from ...)
  report_sales(from, to, group, staff, method, category, flag, q)
      group: day month hour staff category method product flag all; last row key __total
      needs right "reports"; cost and profit are NULL without "viewCost"
  report_ky9(from, to, only9n)    report_ky12(from, to)    report_ky_lots('10'|'11'|'13', from, to, pids)
      need right "forms"
Verified against Python recomputation on the real history: month, staff and drug-type groups,
ข.ย.10 (69 sale rows) and ข.ย.11 (2 sale rows) including remaining quantity after each sale.
The imported history contains no prescription fields, so ข.ย.12 is empty until new bills carry them.

Connect the app to your own Supabase project (database mode)
  A. Create the project (Supabase dashboard). Authentication > Providers > Email: turn OFF "Confirm email".
  B. SQL Editor: paste the whole of deploy_all.sql and run it once (01-06). If you ran 01-05 earlier, run only 06_import.sql.
  C. Authentication > Users > Add user: email  <your login name>@mypharm.com  and a password
     (tick "Auto Confirm User"). The part before @ is the login name you type in the app.
  D. Load SmartDrugstore data. Easiest: inside the app, Settings > สำรอง / กู้คืน / นำเข้า > นำเข้าจาก SmartDrugstore,
     choose the .sql file (products, members, in-stock lots, last 30 days of bills; about 20 seconds for 90 MB).
     Full history instead (optional, from your own computer; keep the DB password private):
       python3 -I migrate_drgstr.py DRGSTR.sql OUTDIR
       cd OUTDIR
       psql "postgresql://postgres:<DB-PASSWORD>@db.<project-ref>.supabase.co:5432/postgres" -v ON_ERROR_STOP=1 -f load.sql
     Do this before the first login so the imported staff rows exist; then step E.
  E. Open the app, on the login screen choose "ตั้งค่าการเชื่อมต่อฐานข้อมูลใหม่", paste the Project URL and the
     anon / publishable key (Settings > API). Log in. The first login creates the administrator and the PIN.
  The anon key is public by design (the database rules protect the data). Never paste the service_role key
  or the database password into the app, GitHub or a chat.

Tests
  psql -f tests/test_functions.sql / test_security.sql / test_reports.sql on a fresh database with 01-05 applied
  cd ../dev/dbtest && npm install && node test_app_db.js   (the real app against local PostgreSQL, 23 checks)
