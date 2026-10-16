"""Builds a self-contained demo page (mock data, fake login, no real Supabase) from index.html.
usage: python3 dev/mock/build_demo.py OUTPUT.html [--standalone]
--standalone wraps the page in a full HTML document (for GitHub Pages / any static host)."""
import re, sys, os
root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
out_path = sys.argv[1]; standalone = '--standalone' in sys.argv
s = open(os.path.join(root, 'index.html'), encoding='utf-8').read()
mock = open(os.path.join(root, 'dev/mock/mock_state.json'), encoding='utf-8').read()
stub = open(os.path.join(root, 'dev/mock/demo_stub.js'), encoding='utf-8').read()
assert '</script' not in mock
style = re.search(r'<style>(.*?)</style>', s, re.S).group(1)
body = s[s.index('<body>') + 6:s.rindex('</body>')]
body = body.replace('style="height:100vh; height:100dvh;"', 'style="height:100%;"', 1)
# the demo never contacts Supabase, so drop the real project address and key from the page
body = re.sub(r"^const supabaseUrl = .*$", "const supabaseUrl = 'https://demo.invalid'", body, flags=re.M)
body = re.sub(r"^const supabaseKey = .*$", "const supabaseKey = 'demo'", body, flags=re.M)
app_i = body.index('<script>\n/* ====')
body = body[:app_i] + '<script id="mockdata" type="application/json">' + mock + '</script>\n<script>\n' + stub + '</script>\n' + body[app_i:]
tag = '<div id="demo-tag"><span>เดโม ข้อมูลตัวอย่าง ไม่เชื่อมฐานข้อมูลจริง รหัส PIN 1234</span><button type="button" onclick="__resetDemo()">รีเซ็ต</button></div>'
head = '''<title>Pharmacy POS Demo</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Thai:wght@400;500;600;700&display=swap" rel="stylesheet">
<script src="https://cdn.tailwindcss.com/3.4.17"></script>
<script src="https://unpkg.com/vue@3.4.38/dist/vue.global.prod.js"></script>
<style>''' + style + '''
  #demo-tag { position:fixed; left:0; bottom:0; z-index:200; display:flex; align-items:center; gap:.5rem; padding:.35rem .6rem calc(.35rem + env(safe-area-inset-bottom, 0px)) calc(.6rem + env(safe-area-inset-left, 0px)); background:#0f3f3a; color:#b9dcd7; font-size:.78rem; border-top-right-radius:.6rem; }
  #demo-tag button { color:#fff; text-decoration:underline; background:none; border:0; font:inherit; cursor:pointer; padding:.2rem; }
</style>
'''
if standalone:
    page = ('<!doctype html>\n<html lang="th">\n<head>\n<meta charset="UTF-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">\n'
            + head + '</head>\n<body>\n' + body + '\n' + tag + '\n</body>\n</html>\n')
else:
    page = head + body + '\n' + tag + '\n'
open(out_path, 'w', encoding='utf-8').write(page)
print(out_path, round(len(page) / 1e6, 2), 'MB')
