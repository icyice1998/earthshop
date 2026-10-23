# Mock data for the sandbox

mock_state.json  full app state: 258 products (50 original + 208 mock), ~90 days of bills,
                 receipts with lots / expiry (some expired, some near expiry), 8 members,
                 2 supplier returns, voided bills, a few low and out-of-stock items.
generate_mock.js rebuilds it with the app's own Logic (so lots, movements and bills stay consistent).
                 Uses a fixed random seed; dates are relative to today.

Load it (your own Supabase test copy only, never the shop's real database):
1. open the test copy, log in
2. ตั้งค่า (Settings) -> paste the contents of mock_state.json into the backup box
3. press restore (กู้คืน), enter PIN 1234

Rebuild:  node dev/mock/generate_mock.js   (needs playwright and chromium; env PW / CHROME override paths)
