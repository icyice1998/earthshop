(function () {
  var KEY = 'pharmacy_demo_cloud'
  var MOCK = JSON.parse(document.getElementById('mockdata').textContent)
  var st = null
  try { st = JSON.parse(localStorage.getItem(KEY)) } catch (e) { st = null }
  if (!st || !st.data) st = { data: MOCK, rev: 1 }
  function persist() { try { localStorage.setItem(KEY, JSON.stringify(st)) } catch (e) { /* ignore */ } }
  var user = { email: 'demo@demo.local', user_metadata: { display_name: 'demo' } }
  var auth = {
    getSession: async function () { return { data: { session: { user: user } } } },
    onAuthStateChange: function () {},
    signInWithPassword: async function () { return { data: { session: { user: user } }, error: null } },
    signOut: async function () { return {} },
    updateUser: async function () { return { data: { user: user }, error: null } }
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
    try { ['pharmacy_demo_cloud', 'knockdown_pos_v6', 'knockdown_pos_unsynced', 'knockdown_inv_view'].forEach(function (k) { localStorage.removeItem(k) }) } catch (e) { /* ignore */ }
    location.reload()
  }
})()
