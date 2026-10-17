New relational database (PostgreSQL / Supabase) for the pharmacy app

Files
  01_schema.sql      tables, constraints, triggers
  02_functions.sql   sell / receive / adjust / void functions (SECURITY DEFINER)
  03_security.sql    RLS deny-by-default, read views without cost, role checks
  migrate_drgstr.py  SmartDrugstore dump -> CSV + load.sql (no passwords migrated)
  verify.py          compares loaded database with expected.json (local test use)
  tests/             SQL tests for functions and security

Local test
  python3 -I migrate_drgstr.py DUMP.sql OUTDIR
  createdb pharm; psql -d pharm -f 01_schema.sql -f 02_functions.sql -f 03_security.sql
  cd OUTDIR; psql -d pharm -v ON_ERROR_STOP=1 -f load.sql

Deploy to your own Supabase project
  1. Supabase dashboard > SQL Editor: run 01, 02, 03 in order.
  2. Load data from your own computer with psql using the project connection string
     (Settings > Database). Keep that password private; do not paste it in chat or commit it.
  3. Create staff logins in Authentication, then link each to a staff row.
  4. Never commit OUTDIR: it contains customer and sales data.

Verified on the real dump: 87,842 bills, 154,742 lines, 4,234 lots, stock 6,497 units,
sales total 8,097,736.00, lot quantity = sum of movements for every lot.
