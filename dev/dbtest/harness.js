// Test harness: lets the app (database mode) talk to a local PostgreSQL through a stand-in for supabase-js.
// Every request runs as the "authenticated" role with the logged-in user's id, exactly like PostgREST does,
// so permissions (views, row security, checked functions) are really exercised.
const { Pool, types } = require('pg')
const fs = require('fs'), path = require('path')
types.setTypeParser(20, v => Number(v)); types.setTypeParser(1700, v => parseFloat(v)); types.setTypeParser(1082, v => v)
types.setTypeParser(1083, v => v); types.setTypeParser(1184, v => new Date(v).toISOString())

const SOCK = process.env.PGSOCK || '/tmp/pgtest', PORT = Number(process.env.PGPORT || 55432)
const admin = db => new Pool({ host: SOCK, port: PORT, user: 'postgres', database: db, max: 4 })

const STUB = `(function () {
  var SK = 'stub_session'
  function call(kind, a) { return window.__pg(kind, a) }
  function session() { try { var s = JSON.parse(localStorage.getItem(SK)); return s || null } catch (e) { return null } }
  function mkAuth(persist) {
    return {
      getSession: async function () { var s = session(); return { data: { session: s ? { user: s.user } : null } } },
      onAuthStateChange: function () {},
      signInWithPassword: async function (c) {
        var r = await call('login', { email: c.email, password: c.password })
        if (r.error) return { data: {}, error: { message: r.error, status: 400 } }
        var u = { id: r.id, email: c.email, user_metadata: {} }
        if (persist) localStorage.setItem(SK, JSON.stringify({ user: u }))
        return { data: { session: { user: u }, user: u }, error: null }
      },
      signUp: async function (c) {
        var r = await call('signup', { email: c.email, password: c.password })
        return { data: { user: { id: r.id, identities: r.exists ? [] : [{}] } }, error: null }
      },
      signOut: async function () { localStorage.removeItem(SK); return {} },
      updateUser: async function () { return { data: {}, error: null } }
    }
  }
  function uid() { var s = session(); return s ? s.user.id : null }
  function email() { var s = session(); return s ? s.user.email : null }
  function Q(view, cols) {
    var q = { view: view, cols: cols || '*', f: [], o: [], r: null }
    var api = {
      eq: function (c, v) { q.f.push(['=', c, v]); return api }, gt: function (c, v) { q.f.push(['>', c, v]); return api },
      gte: function (c, v) { q.f.push(['>=', c, v]); return api }, lt: function (c, v) { q.f.push(['<', c, v]); return api },
      lte: function (c, v) { q.f.push(['<=', c, v]); return api }, in: function (c, v) { q.f.push(['in', c, v]); return api },
      order: function (c, o) { q.o.push([c, !(o && o.ascending === false)]); return api },
      range: function (a, b) { q.r = [a, b]; return api }, limit: function (n) { q.r = [0, n - 1]; return api },
      maybeSingle: function () { q.single = true; return api },
      then: function (res, rej) { return call('select', { uid: uid(), email: email(), q: q }).then(function (r) { res(r) }, rej) }
    }
    return api
  }
  window.supabase = { createClient: function (url, key, opts) {
    var persist = !(opts && opts.auth && opts.auth.persistSession === false)
    return { auth: mkAuth(persist), from: function (v) { return { select: function (cols) { return Q(v, cols) } } },
      rpc: function (fn, args) { return call('rpc', { uid: uid(), email: email(), fn: fn, args: args || {} }) } }
  } }
})()`

const ident = s => { if (!/^[a-z_][a-z0-9_]*$/i.test(s)) throw new Error('bad identifier ' + s); return '"' + s + '"' }

async function inRole(pool, uid, email, fn) {
  const c = await pool.connect()
  try {
    await c.query('begin')
    if (uid) { await c.query('set local role authenticated'); await c.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: uid, email, role: 'authenticated' })]) }
    const out = await fn(c)
    await c.query('commit')
    return out
  } catch (e) { await c.query('rollback').catch(() => {}); throw e } finally { c.release() }
}

async function attach(page, pool, authUsers) {
  await page.addInitScript(STUB)
  await page.exposeFunction('__pg', async (kind, a) => {
    try {
      if (kind === 'login') {
        const u = authUsers[String(a.email).toLowerCase()]
        if (!u || u.pw !== a.password) return { error: 'Invalid login credentials' }
        return { id: u.id }
      }
      if (kind === 'signup') {
        const e = String(a.email).toLowerCase()
        if (authUsers[e]) return { exists: true }
        const id = (await pool.query('select gen_random_uuid() id')).rows[0].id
        authUsers[e] = { id, pw: a.password }
        return { id }
      }
      if (kind === 'select') {
        const q = a.q, params = []
        const cols = q.cols === '*' ? '*' : q.cols.split(',').map(c => ident(c.trim())).join(',')
        let sql = 'select ' + cols + ' from public.' + ident(q.view)
        const w = q.f.map(([op, c, v]) => { params.push(v); return op === 'in' ? ident(c) + ' = any($' + params.length + ')' : ident(c) + ' ' + op + ' $' + params.length })
        if (w.length) sql += ' where ' + w.join(' and ')
        if (q.o.length) sql += ' order by ' + q.o.map(([c, asc]) => ident(c) + (asc ? '' : ' desc')).join(',')
        if (q.r) sql += ' limit ' + (q.r[1] - q.r[0] + 1) + ' offset ' + q.r[0]
        const r = await inRole(pool, a.uid, a.email, c => c.query(sql, params))
        return { data: q.single ? (r.rows[0] || null) : r.rows, error: null }
      }
      if (kind === 'rpc') {
        const keys = Object.keys(a.args), params = keys.map(k => a.args[k])
        const sql = 'select * from public.' + ident(a.fn) + '(' + keys.map((k, i) => ident(k) + ' => $' + (i + 1)).join(', ') + ')'
        const r = await inRole(pool, a.uid, a.email, c => c.query(sql, params))
        if (r.fields.length === 1 && r.fields[0].name === a.fn) { const v = r.rows[0] ? r.rows[0][a.fn] : null; return { data: v === '' ? null : v, error: null } }
        return { data: r.rows, error: null }
      }
      return { error: 'unknown ' + kind }
    } catch (e) { return { data: null, error: { message: e.message, code: e.code } } }
  })
}

// builds a fresh test database from db/01..05 and returns a pool on it
async function freshDb(name) {
  const root = admin('postgres')
  await root.query('drop database if exists ' + name); await root.query('create database ' + name); await root.end()
  const pool = admin(name)
  const dir = path.join(__dirname, '..', '..', 'db')
  for (const f of ['01_schema', '02_functions', '03_security', '04_reports', '05_api']) await pool.query(fs.readFileSync(path.join(dir, f + '.sql'), 'utf8'))
  return pool
}

module.exports = { attach, freshDb, admin }
