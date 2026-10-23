(function () {
  var KEY = 'pharmacy_demo_cloud'
  var MOCK = JSON.parse(document.getElementById('mockdata').textContent)
  var st = null
  try { st = JSON.parse(localStorage.getItem(KEY)) } catch (e) { st = null }
  if (!st || !st.data) st = { data: MOCK, rev: 1 }
  function persist() { try { localStorage.setItem(KEY, JSON.stringify(st)) } catch (e) { /* ignore */ } }
  var USERKEY = 'pharmacy_demo_user'
  function mkUser(login) { return { email: login + '@demo.local', user_metadata: { display_name: login } } }
  function curUser() { try { var v = localStorage.getItem(USERKEY); if (v === '') return null; return mkUser(v || 'demo') } catch (e) { return mkUser('demo') } }
  var auth = {
    getSession: async function () { var u = curUser(); return { data: { session: u ? { user: u } : null } } },
    onAuthStateChange: function () {},
    signInWithPassword: async function (c) {
      var login = String((c && c.email) || 'demo').split('@')[0].toLowerCase() || 'demo'
      try { localStorage.setItem(USERKEY, login) } catch (e) { /* ignore */ }
      return { data: { session: { user: mkUser(login) }, user: mkUser(login) }, error: null }
    },
    signUp: async function (c) { window.__lastSignUp = c; return { data: { user: { identities: [{}] } }, error: null } },
    signOut: async function () { try { localStorage.setItem(USERKEY, '') } catch (e) { /* ignore */ } return {} },
    updateUser: async function () { return { data: { user: curUser() }, error: null } }
  }
  function row() { return { data: st.data, rev: st.rev, updated_by: 'demo', updated_at: new Date().toISOString() } }
  var query = { eq: function () { return { maybeSingle: async function () { return { data: row(), error: null } } } } }
  var client = {
    auth: auth,
    from: function () { return { select: function () { return query } } },
    rpc: async function (name, args) {
      if (args.expected_rev !== st.rev) return { data: -1, error: null }
      st = { data: args.new_data, rev: st.rev + 1 }
      persist()
      return { data: st.rev, error: null }
    }
  }
  window.supabase = { createClient: function () { return client } }
  window.__resetDemo = function () {
    try { ['pharmacy_demo_cloud', 'pharmacy_demo_user', 'knockdown_pos_v6', 'knockdown_pos_unsynced', 'knockdown_inv_view'].forEach(function (k) { localStorage.removeItem(k) }) } catch (e) { /* ignore */ }
    location.reload()
  }
})()
