# Earthshop print bridge (slip / receipt printer on the LAN)

Why: the app runs in a web browser, which cannot talk to a network printer directly. This tiny program runs on a PC in
the shop and passes the receipt to the printer (for example the D300H at 192.168.1.146, raw port 9100).

1. Install Node.js (version 16 or newer) on the PC that will stay on in the shop: https://nodejs.org
2. Copy `bridge.js` (and `start-bridge.bat` on Windows) to that PC. Double-click `start-bridge.bat`, or run `node bridge.js --port 9101`.
3. In the app: Settings > ตั้งค่าโปรแกรม > เครื่องพิมพ์สลิป (LAN). Enter the printer IP and port, the bridge address
   (`http://localhost:9101` if the app runs in a browser on the same PC), press "ตรวจสอบ" and then "ทดสอบพิมพ์".
4. To start it automatically with Windows: press Win+R, type `shell:startup`, and put a shortcut to `start-bridge.bat` there.

Notes
- The receipt is drawn as an image in the browser, so Thai text prints correctly on any ESC/POS printer.
- The bridge only talks to addresses inside your shop network (192.168.x.x, 10.x.x.x, 172.16-31.x.x) and only answers
  web pages on its allow-list (the app on GitHub Pages, localhost, local files). Add another address with `--origin https://...`.
- If the app runs on a tablet or phone, start the bridge with `--lan` on the shop PC and use `http://<that PC's IP>:9101` as the bridge address.
  A page served over https may be blocked from calling plain http on another device by the browser; use the shop PC's browser for slip printing in that case.
- Chrome may ask once to allow the site to connect to devices on your local network. Choose Allow.

## Printing from a mobile phone

Two ways, pick one.

**A. Phone opens the app from the shop PC (works on Android and iPhone)**
1. On the shop PC run `start-bridge-phone.bat` (or `node bridge.js --port 9101 --serve`). The first run downloads the app; add `--update` later to refresh it.
2. The window prints the addresses, for example `http://192.168.1.50:9101/`. Open that address in the phone's browser (the phone must be on the shop Wi-Fi). Give the shop PC a fixed IP in the router so the address never changes.
3. Log in as usual. The first time on a phone, press the small link under the login button, paste the project address and key once.
4. Settings > Program > เครื่องพิมพ์สลิป: turn on, keep "ผ่านโปรแกรมสะพานพิมพ์". The bridge address is filled in automatically. Receipts now print on the D300H.
   Windows Firewall may ask to allow Node.js on the private network the first time. Choose Allow.

**B. Android phone with the RawBT app (no PC needed)**
1. Install RawBT from Play Store, add the printer as a Network (TCP/IP) printer: IP 192.168.1.146, port 9100.
2. In the app choose "ผ่านแอป RawBT" in the slip printer setting. The first print asks which app should open the link; choose RawBT.
iPhone has no equivalent of RawBT, so use way A.
