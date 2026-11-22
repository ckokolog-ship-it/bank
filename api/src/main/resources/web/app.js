// app.js -- the pages of the bank: they speak to /api/ (bk-api) with the token of their login. No library;
// the rules are all in the database (BK_CORE): its errors (BK-1xx) are shown as they come.
'use strict';

const S = { token: null, me: null, day: null };
const OPS = { DEP: 'Κατάθεση', WDR: 'Ανάληψη', TRO: 'Μεταφορά προς άλλον', TRI: 'Μεταφορά από άλλον',
  OUT: 'Σε άλλη τράπεζα', INC: 'Από άλλη τράπεζα', FEE: 'Προμήθεια' };
const KINDS = { DEP: 'Κατάθεση', WDR: 'Ανάληψη', TRF: 'Μεταφορά', OUT: 'Σε άλλη τράπεζα', INC: 'Από άλλη τράπεζα',
  INT: 'Τόκοι', REV: 'Αντιλογισμός' };
const CHANNELS = { '*': 'Όλα', BR: 'Γκισέ', WEB: 'e-banking', ATM: 'ATM', SYS: 'Τράπεζα' };
const STATUS = { O: 'Ανοιχτός', B: 'Δεσμευμένος', C: 'Κλειστός' };
const ROLES = ['TELLER', 'MANAGER', 'ADMIN'];
const CAP = { M: 'μήνα', Q: 'τρίμηνο', Y: 'χρόνο' };
const RULE_FIELDS = [['min_amount', 'Ελάχιστο ποσό'], ['max_amount', 'Μέγιστο ποσό'], ['day_amount', 'Ποσό ημέρας'],
  ['day_count', 'Κινήσεις ημέρας'], ['month_amount', 'Ποσό μήνα'], ['month_count', 'Κινήσεις μήνα'],
  ['free_month', 'Δωρεάν τον μήνα'], ['fee', 'Προμήθεια'], ['min_balance', 'Ελάχιστο υπόλοιπο']];

// ---------------------------------------------------------------------------------------------
// the elements
function h(tag, attrs, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') e.className = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (k === 'value') e.value = v;
    else e.setAttribute(k, v === true ? '' : v);
  }
  for (const k of kids.flat()) {
    if (k == null || k === false) continue;
    e.append(k instanceof Node ? k : document.createTextNode(String(k)));
  }
  return e;
}
const $ = (id) => document.getElementById(id);
const money = (v) => v == null ? '' : Number(v).toLocaleString('el-GR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const eur = (v) => v == null ? '' : money(v) + ' €';
const num = (v, d = 4) => v == null ? '' : Number(v).toLocaleString('el-GR', { maximumFractionDigits: d });
const date = (v) => v ? v.slice(8, 10) + '/' + v.slice(5, 7) + '/' + v.slice(0, 4) : '';
const iban = (v) => v ? v.replace(/(.{4})/g, '$1 ').trim() : '';
const can = (role) => S.me && ROLES.indexOf(S.me.role) >= ROLES.indexOf(role);
const td = (v, cls) => h('td', { class: cls }, v);
const tdn = (v) => h('td', { class: 'num' }, v);

function toast(text, bad) {
  const t = $('toast');
  t.textContent = text;
  t.className = 'toast' + (bad ? ' bad' : '');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => t.classList.add('hidden'), bad ? 6000 : 3000);
}

function table(heads, rows, foot) {
  return h('div', { class: 'table-wrap' }, h('table', null,
    h('thead', null, h('tr', null, heads.map((x) => h('th', { class: x.startsWith('#') ? 'num' : null }, x.replace(/^#/, ''))))),
    h('tbody', null, rows.length ? rows : h('tr', null, h('td', { colspan: heads.length, class: 'muted' }, 'Τίποτα'))),
    foot ? h('tfoot', null, foot) : null));
}

function field(label, input) {
  return h('label', null, label, input);
}

function form(fields, onsubmit, button) {
  const f = h('form', { class: 'row' }, fields, h('button', { type: 'submit', class: 'primary' }, button || 'Αποθήκευση'));
  f.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const b = f.querySelector('button[type=submit]');
    b.disabled = true;
    try { await onsubmit(f); } catch (e) { toast(e.message, true); } finally { b.disabled = false; }
  });
  return f;
}

function values(f) {
  const o = {};
  for (const e of f.querySelectorAll('[name]')) {
    const v = e.value.trim();
    o[e.name] = v === '' ? null : (e.dataset.num ? Number(v.replace(',', '.')) : v);
  }
  return o;
}

function sel(name, options, value) {
  return h('select', { name }, Object.entries(options).map(([k, v]) => h('option', { value: k, selected: k === value }, v)));
}

// ---------------------------------------------------------------------------------------------
// the service
async function api(path, body) {
  const opt = { method: body === undefined ? 'GET' : 'POST', headers: {} };
  if (S.token) opt.headers.Authorization = 'Bearer ' + S.token;
  if (body !== undefined) {
    opt.headers['Content-Type'] = 'application/json';
    opt.body = JSON.stringify(body);
  }
  const r = await fetch('/api/' + path, opt);
  const j = await r.json().catch(() => ({ message: 'Λάθος απάντηση (' + r.status + ')' }));
  if (r.status === 401 && S.token) {
    logout(true);
  }
  if (!r.ok) throw new Error(j.message || ('Λάθος ' + r.status));
  return j;
}

async function refreshDay() {
  S.day = await api('day');
  $('day-chip').textContent = 'Εργάσιμη ' + date(S.day.open_day);
}

// ---------------------------------------------------------------------------------------------
// the login
function showLogin() {
  $('app').classList.add('hidden');
  $('login').classList.remove('hidden');
  $('login-user').focus();
}

async function start() {
  try { S.token = sessionStorage.getItem('bk-token'); } catch (e) { S.token = null; }
  if (S.token) {
    try {
      S.me = await api('auth/me');
      return enter();
    } catch (e) { S.token = null; }
  }
  showLogin();
}

async function enter() {
  $('login').classList.add('hidden');
  $('app').classList.remove('hidden');
  $('who').textContent = S.me.full_name + ' · ' + S.me.role;
  await refreshDay();
  nav();
  route();
}

function logout(expired) {
  if (S.token && !expired) api('auth/logout', {}).catch(() => {});
  S.token = null;
  S.me = null;
  try { sessionStorage.removeItem('bk-token'); } catch (e) { /* none */ }
  showLogin();
  if (expired) $('login-msg').textContent = 'Η σύνδεση έληξε: ξανά είσοδος';
}

$('login-form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  $('login-msg').textContent = '';
  try {
    const r = await api('auth/login', { username: $('login-user').value, password: $('login-pw').value });
    S.token = r.token;
    try { sessionStorage.setItem('bk-token', r.token); } catch (e) { /* none */ }
    $('login-pw').value = '';
    S.me = await api('auth/me');
    enter();
  } catch (e) { $('login-msg').textContent = e.message; }
});
$('logout').addEventListener('click', () => logout(false));

// ---------------------------------------------------------------------------------------------
// the pages
// the menu: an accordion of groups, one open at a time (the group of the page open by itself)
const MENU = [
  { key: 'customers', title: '👥 Πελάτες', items: [['customers', 'Αναζήτηση'], ['customers/new', 'Νέος πελάτης']] },
  { key: 'accounts', title: '💳 Λογαριασμοί', items: [['accounts', 'Αναζήτηση'], ['move', 'Νέα κίνηση']] },
  { key: 'bank', title: '🏦 Τράπεζα', items: [['rules', 'Κανόνες κινήσεων'], ['products', 'Προϊόντα και επιτόκια'], ['atms', 'ATM'],
    ['day', 'Ημέρα και κλείσιμο']] },
  { key: 'admin', title: '🔐 Διαχείριση', role: 'ADMIN', items: [['users', 'Χρήστες']] }];
// the item of the menu of a page (a customer: of the customers, an account or an entry: of the accounts)
const MENU_OF = { customer: 'customers', account: 'accounts', entry: 'accounts' };

function nav() {
  const n = $('nav');
  n.replaceChildren(...MENU.filter((g) => !g.role || can(g.role)).map((g) => {
    const d = h('details', { class: 'grp', 'data-key': g.key }, h('summary', null, g.title),
      h('div', { class: 'grp-items' }, g.items.map(([href, text]) => h('a', { href: '#/' + href, 'data-page': href }, text))));
    d.addEventListener('toggle', () => {
      if (!d.open) return;
      for (const o of n.querySelectorAll('details.grp')) if (o !== d) o.open = false;
    });
    return d;
  }));
}

function menu(open) {
  $('side').classList.toggle('open', open);
  $('scrim').classList.toggle('open', open);
  $('menu-btn').setAttribute('aria-expanded', open ? 'true' : 'false');
}

function markMenu(page, id) {
  const here = page === 'customers' && id === 'new' ? 'customers/new' : (MENU_OF[page] || page);
  for (const g of document.querySelectorAll('#nav details.grp')) {
    let on = false;
    for (const a of g.querySelectorAll('a')) {
      a.classList.toggle('on', a.dataset.page === here);
      on = on || a.dataset.page === here;
    }
    g.classList.toggle('has-on', on);
    if (on) g.open = true;
  }
}

document.body.append(h('div', { id: 'scrim', class: 'scrim', onclick: () => menu(false) }));
$('menu-btn').addEventListener('click', () => menu(!$('side').classList.contains('open')));
$('nav').addEventListener('click', (ev) => { if (ev.target.closest('a')) menu(false); });
document.addEventListener('keydown', (ev) => { if (ev.key === 'Escape') menu(false); });

window.addEventListener('hashchange', route);

async function route() {
  if (!S.me) return;
  const [page, id, extra] = (location.hash.replace(/^#\/?/, '') || 'customers').split('/');
  markMenu(page, id);
  const m = $('main');
  m.replaceChildren(h('p', { class: 'muted' }, 'Φόρτωση…'));
  try {
    const f = { customers, customer, accounts, account, move, entry, rules, products, atms, day, users }[page] || customers;
    const el = await f(id, extra);
    m.replaceChildren(el);
  } catch (e) {
    m.replaceChildren(h('div', { class: 'card' }, h('p', { class: 'error' }, e.message)));
  }
}

// ---- the customers
async function customers(id) {
  const box = h('div');
  const q = h('input', { placeholder: 'Όνομα, ΑΦΜ, κωδικός, τηλέφωνο', type: 'search' });
  const list = h('div');
  let offset = 0;
  async function load() {
    const r = await api('customers?limit=50&offset=' + offset + '&q=' + encodeURIComponent(q.value.trim()));
    list.replaceChildren(table(['Κωδικός', 'Ονοματεπώνυμο', 'ΑΦΜ', 'Τηλέφωνο', 'Email', '#Λογαριασμοί'],
      r.rows.map((c) => h('tr', { class: 'click', onclick: () => { location.hash = '#/customer/' + c.id; } },
        td(c.code, 'mono'), td(c.name, c.active === 'N' ? 'muted' : null), td(c.afm, 'mono'), td(c.phone), td(c.email),
        tdn(c.accounts)))),
    pager(r.total, offset, (o) => { offset = o; load(); }));
  }
  let timer;
  q.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => { offset = 0; load(); }, 250); });
  box.append(h('div', { class: 'card' }, h('div', { class: 'row' }, h('h2', null, 'Πελάτες'), q,
    h('button', { class: 'primary', onclick: () => newCustomer(box) }, 'Νέος πελάτης')), list));
  await load();
  if (id === 'new') newCustomer(box);
  else setTimeout(() => q.focus(), 0);
  return box;
}

function pager(total, offset, go) {
  return h('div', { class: 'pager muted' }, (total ? (offset + 1) + '–' + Math.min(offset + 50, total) : 0) + ' από ' + total,
    h('button', { disabled: offset === 0, onclick: () => go(Math.max(0, offset - 50)) }, '‹'),
    h('button', { disabled: offset + 50 >= total, onclick: () => go(offset + 50) }, '›'));
}

function customerFields(c) {
  c = c || {};
  return [
    field('Ονοματεπώνυμο', h('input', { name: 'name', value: c.name, required: true })),
    field('ΑΦΜ', h('input', { name: 'afm', value: c.afm, inputmode: 'numeric', maxlength: 9 })),
    field('Ταυτότητα', h('input', { name: 'id_card', value: c.id_card })),
    field('Γέννηση', h('input', { name: 'birth_date', type: 'date', value: c.birth_date })),
    field('Τηλέφωνο', h('input', { name: 'phone', value: c.phone })),
    field('Email', h('input', { name: 'email', type: 'email', value: c.email })),
    field('Διεύθυνση', h('input', { name: 'address', value: c.address }))];
}

function newCustomer(box) {
  if (box.querySelector('.new-customer')) return;
  box.prepend(h('div', { class: 'card new-customer' }, h('h2', null, 'Νέος πελάτης'),
    form(customerFields(), async (f) => {
      const c = await api('customers', values(f));
      toast('Ο πελάτης ' + c.code + ' καταχωρίστηκε');
      location.hash = '#/customer/' + c.id;
    }, 'Καταχώριση')));
}

async function customer(id) {
  const [c, prods] = await Promise.all([api('customers/' + id), api('products')]);
  const box = h('div');
  const edit = h('div', { class: 'hidden' }, form([...customerFields(c),
    field('Ενεργός', sel('active', { Y: 'Ναι', N: 'Όχι' }, c.active))], async (f) => {
    await api('customers/' + id, values(f));
    toast('Αποθηκεύτηκε');
    route();
  }));
  box.append(h('div', { class: 'card' },
    h('div', { class: 'row' }, h('h2', null, c.name + ' ', h('span', { class: 'muted mono' }, c.code)),
      h('button', { onclick: () => edit.classList.toggle('hidden') }, 'Διόρθωση')),
    h('div', { class: 'kv' }, kv('ΑΦΜ', c.afm), kv('Ταυτότητα', c.id_card), kv('Γέννηση', date(c.birth_date)),
      kv('Τηλέφωνο', c.phone), kv('Email', c.email), kv('Διεύθυνση', c.address),
      kv('Κατάσταση', c.active === 'Y' ? 'Ενεργός' : 'Ανενεργός')),
    edit));
  box.append(h('div', { class: 'card' }, h('h2', null, 'Λογαριασμοί'),
    table(['IBAN', 'Προϊόν', 'Όνομα', 'Δικαιούχος', 'Κατάσταση', '#Υπόλοιπο'],
      c.accounts.map((a) => h('tr', { class: 'click', onclick: () => { location.hash = '#/account/' + a.id; } },
        td(iban(a.iban), 'mono'), td(a.product_name), td(a.name), td(a.role === 'P' ? 'Κύριος' : 'Συνδικαιούχος'),
        td(h('span', { class: 'badge ' + a.status }, STATUS[a.status])), tdn(eur(a.balance))))),
    c.active === 'Y' ? h('div', null, h('h3', null, 'Νέος λογαριασμός'), form([
      field('Προϊόν', sel('product', Object.fromEntries(prods.filter((p) => p.active === 'Y').map((p) => [p.code, p.name + ' (' + p.code + ')'])))),
      field('Όνομα (προαιρετικά)', h('input', { name: 'name' })),
      field('Όριο υπερανάληψης', h('input', { name: 'od_limit', 'data-num': 1, inputmode: 'decimal', value: '0' }))],
    async (f) => {
      const a = await api('accounts', Object.assign(values(f), { customer_id: Number(id) }));
      toast('Άνοιξε ο ' + iban(a.iban));
      location.hash = '#/account/' + a.id;
    }, 'Άνοιγμα')) : null));
  return box;
}

function kv(k, v) {
  return h('div', null, h('b', null, k), h('span', null, v == null || v === '' ? '—' : v));
}

// ---- the accounts
async function accounts() {
  const box = h('div');
  const q = h('input', { placeholder: 'IBAN, όνομα ή ΑΦΜ δικαιούχου, κωδικός πελάτη', type: 'search' });
  const st = h('select', null, h('option', { value: '' }, 'Όλοι'), Object.entries(STATUS).map(([k, v]) => h('option', { value: k }, v)));
  const list = h('div');
  let offset = 0;
  async function load() {
    const r = await api('accounts?limit=50&offset=' + offset + '&status=' + st.value + '&q=' + encodeURIComponent(q.value.trim()));
    list.replaceChildren(table(['IBAN', 'Προϊόν', 'Δικαιούχος', 'Κατάσταση', '#Υπόλοιπο', '#Όριο', '#Δεδουλευμένοι'],
      r.rows.map((a) => h('tr', { class: 'click', onclick: () => { location.hash = '#/account/' + a.id; } },
        td(iban(a.iban), 'mono'), td(a.product), td(a.holder + (a.holders > 1 ? ' +' + (a.holders - 1) : '')),
        td(h('span', { class: 'badge ' + a.status }, STATUS[a.status])),
        h('td', { class: 'num' + (a.balance < 0 ? ' bad' : '') }, eur(a.balance)), tdn(a.od_limit ? eur(a.od_limit) : ''),
        tdn(num(a.accrued, 2))))),
    pager(r.total, offset, (o) => { offset = o; load(); }));
  }
  let timer;
  q.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => { offset = 0; load(); }, 250); });
  st.addEventListener('change', () => { offset = 0; load(); });
  box.append(h('div', { class: 'card' }, h('div', { class: 'row' }, h('h2', null, 'Λογαριασμοί'), q, st), list,
    h('p', { class: 'muted' }, 'Νέος λογαριασμός: από τη σελίδα του πελάτη.')));
  await load();
  setTimeout(() => q.focus(), 0);
  return box;
}

async function account(id, tab) {
  const a = await api('accounts/' + id);
  const box = h('div');
  const actions = h('div', { class: 'actions' },
    a.status !== 'C' ? h('a', { href: '#/move/' + id }, h('button', { class: 'primary' }, 'Νέα κίνηση')) : null);
  if (can('MANAGER') && a.status !== 'C') {
    actions.append(
      h('button', { onclick: () => act('status', { status: a.status === 'O' ? 'B' : 'O' }) }, a.status === 'O' ? 'Δέσμευση' : 'Αποδέσμευση'),
      h('button', { onclick: () => {
        const v = prompt('Νέο όριο υπερανάληψης (€)', a.od_limit);
        if (v != null) act('od-limit', { od_limit: Number(v.replace(',', '.')) });
      } }, 'Όριο υπερανάληψης'),
      h('button', { class: 'danger', onclick: () => {
        if (confirm('Κλείσιμο του ' + iban(a.iban) + '; Πρώτα κεφαλαιοποιούνται οι τόκοι και το υπόλοιπο πρέπει να είναι 0.')) act('close', {});
      } }, 'Κλείσιμο'));
  }
  async function act(what, body) {
    try { await api('accounts/' + id + '/' + what, body); toast('Έγινε'); route(); } catch (e) { toast(e.message, true); }
  }
  box.append(h('div', { class: 'card' },
    h('h2', null, iban(a.iban), ' ', h('span', { class: 'badge ' + a.status }, STATUS[a.status])),
    h('p', { class: 'muted' }, a.product_name + ' (' + a.product + ')' + (a.name ? ' · ' + a.name : '') + ' · άνοιξε ' + date(a.opened_on)
      + (a.closed_on ? ' · έκλεισε ' + date(a.closed_on) : '')),
    h('div', { class: 'kv' }, kv('Υπόλοιπο', eur(a.balance)), kv('Διαθέσιμο', eur(a.available)),
      kv('Όριο υπερανάληψης', eur(a.od_limit)), kv('Δεδουλευμένοι τόκοι', eur(a.accrued)),
      kv('Επιτόκιο τώρα', num(a.rate_now) + ' %'),
      kv('Τόκοι', a.day_basis + ', κεφαλαιοποίηση ανά ' + CAP[a.cap_every] + ', φόρος ' + num(a.tax_rate) + ' %')),
    actions));
  const tabs = [['statement', 'Καρτέλα'], ['interest', 'Τόκοι'], ['limits', 'Όρια και κανόνες'], ['holders', 'Δικαιούχοι'], ['cards', 'Κάρτες']];
  const cur = tab || 'statement';
  box.append(h('div', { class: 'tabs' }, tabs.map(([k, v]) => h('button', { class: k === cur ? 'on' : null,
    onclick: () => { location.hash = '#/account/' + id + '/' + k; } }, v))));
  const body = h('div', { class: 'card' });
  box.append(body);
  const f = { statement: statementTab, interest: interestTab, limits: limitsTab, holders: holdersTab, cards: cardsTab }[cur] || statementTab;
  body.append(await f(a));
  return box;
}

function period(load, days) {
  const to = h('input', { type: 'date', value: S.day.open_day });
  const d = new Date(S.day.open_day);
  d.setDate(d.getDate() - days);
  const from = h('input', { type: 'date', value: d.toISOString().slice(0, 10) });
  const run = () => load(from.value, to.value);
  from.addEventListener('change', run);
  to.addEventListener('change', run);
  return { el: h('div', { class: 'row' }, field('Από', from), field('Έως', to)), run };
}

async function statementTab(a) {
  const out = h('div');
  const list = h('div');
  const p = period(async (from, to) => {
    const r = await api('accounts/' + a.id + '/statement?from=' + from + '&to=' + to);
    list.replaceChildren(table(['Λογισμός', 'Αξία', 'Κίνηση', 'Κανάλι', 'Περιγραφή', '#Χρέωση', '#Πίστωση', '#Υπόλοιπο', 'Εγγραφή'],
      [h('tr', null, h('td', { colspan: 7, class: 'muted' }, 'Από μεταφορά'), tdn(eur(r.carry_in)), td('')),
        ...r.rows.map((x) => h('tr', { class: x.reversed_by ? 'rev' : null },
          td(date(x.book_date)), td(x.value_date !== x.book_date ? date(x.value_date) : ''),
          td(x.op === 'FEE' ? OPS.FEE : (KINDS[x.kind] || x.kind)), td(CHANNELS[x.channel] || x.channel), td(x.descr),
          tdn(x.debit ? money(x.debit) : ''), tdn(x.credit ? money(x.credit) : ''), tdn(money(x.balance)),
          td(h('a', { href: '#/entry/' + x.entry_id }, '#' + x.entry_id))))],
      h('tr', null, h('td', { colspan: 5 }, 'Σύνολα · σε μεταφορά'), tdn(money(r.debit)), tdn(money(r.credit)),
        tdn(eur(r.carry_out)), td(''))));
  }, 30);
  out.append(p.el, list);
  await p.run();
  return out;
}

async function interestTab(a) {
  const out = h('div');
  const list = h('div');
  const p = period(async (from, to) => {
    const r = await api('accounts/' + a.id + '/interest?from=' + from + '&to=' + to);
    list.replaceChildren(
      h('p', { class: 'muted' }, 'Τόκος μιας μέρας = υπόλοιπο (ανά ημερομηνία αξίας) × επιτόκιο / 100 × ημέρες / ημέρες του έτους. '
        + 'Σύνολο της περιόδου: ', h('b', null, num(r.total, 6) + ' €')),
      h('h3', null, 'Κεφαλαιοποιήσεις'),
      table(['Ημέρα', '#Μικτός τόκος', '#Φόρος', '#Καθαρός', 'Εγγραφή'], r.capitalized.map((x) => h('tr', null,
        td(date(x.day)), tdn(eur(x.gross)), tdn(eur(x.tax)), tdn(eur(x.net)),
        td(x.entry_id ? h('a', { href: '#/entry/' + x.entry_id }, '#' + x.entry_id) : '—')))));
    list.append(h('h3', null, 'Κάθε μέρα'), table(['Ημέρα', '#Υπόλοιπο', '#Επιτόκιο %', '#Ημέρες', '#Έτος', '#Τόκος'],
      r.days.slice().reverse().map((x) => h('tr', null, td(date(x.day)), tdn(eur(x.balance)), tdn(num(x.rate)),
        tdn(x.days), tdn(x.year_days), h('td', { class: 'num' + (x.interest < 0 ? ' bad' : '') }, num(x.interest, 6))))));
  }, 90);
  out.append(p.el, list);
  await p.run();
  return out;
}

function usage(used, limit, isMoney) {
  if (limit == null) return '—';
  const pct = limit > 0 ? Math.min(100, used / limit * 100) : 100;
  const bar = h('div', { class: 'bar' + (used >= limit ? ' full' : '') }, h('i'));
  bar.firstChild.style.width = pct + '%';
  return h('div', null, (isMoney ? money(used) + ' / ' + money(limit) : used + ' / ' + limit), bar);
}

async function limitsTab(a) {
  const r = await api('accounts/' + a.id + '/limits');
  const out = h('div', null, h('p', { class: 'muted' }, 'Τι ισχύει τελικά για κάθε κίνηση και κανάλι, σήμερα (' + date(S.day.open_day)
    + '): κάθε τιμή από τον πιο ειδικό κανόνα (λογαριασμός, προϊόν, τράπεζα· κανάλι πριν από «όλα»).'));
  out.append(table(['Κίνηση', 'Κανάλι', 'Επιτρέπεται', '#Ποσό', 'Ημέρα (ποσό)', 'Ημέρα (κινήσεις)', 'Μήνας (ποσό)',
    'Μήνας (κινήσεις)', '#Προμήθεια', '#Ελάχ. υπόλοιπο'],
  r.limits.map((x) => h('tr', null, td(OPS[x.op]), td(CHANNELS[x.channel]),
    td(x.allowed ? 'Ναι' : h('span', { class: 'badge no' }, 'Όχι')),
    tdn(x.min_amount != null || x.max_amount != null ? (x.min_amount != null ? money(x.min_amount) : '0') + ' – ' + (x.max_amount != null ? money(x.max_amount) : '∞') : ''),
    td(usage(x.day_amount_used, x.day_amount, true)), td(usage(x.day_count_used, x.day_count)),
    td(usage(x.month_amount_used, x.month_amount, true)), td(usage(x.month_count_used, x.month_count)),
    tdn(x.fee ? eur(x.fee) + (x.free_month != null ? ' (μετά από ' + x.free_month + ', έγιναν ' + x.free_month_used + ')' : '') : ''),
    tdn(x.min_balance != null ? eur(x.min_balance) : '')))));
  out.append(h('h3', null, 'Οι κανόνες που τον αφορούν'), rulesTable(r.rules, () => route()));
  if (can('MANAGER')) out.append(h('h3', null, 'Νέος κανόνας για αυτόν τον λογαριασμό'), ruleForm({ account_id: a.id }, () => route()));
  return out;
}

async function holdersTab(a) {
  const out = h('div');
  out.append(table(['Κωδικός', 'Ονοματεπώνυμο', 'ΑΦΜ', 'Ρόλος', ''], a.holders.map((c) => h('tr', null,
    td(h('a', { href: '#/customer/' + c.id }, c.code), 'mono'), td(c.name), td(c.afm, 'mono'),
    td(c.role === 'P' ? 'Κύριος' : 'Συνδικαιούχος'),
    td(c.role === 'J' && a.status !== 'C' ? h('button', { class: 'link', onclick: async () => {
      if (!confirm('Αφαίρεση του ' + c.name + ';')) return;
      try { await api('accounts/' + a.id + '/holders/' + c.id + '/remove', {}); toast('Αφαιρέθηκε'); route(); } catch (e) { toast(e.message, true); }
    } }, 'Αφαίρεση') : '')))));
  if (a.status !== 'C') {
    const q = h('input', { type: 'search', placeholder: 'Αναζήτηση πελάτη: όνομα, ΑΦΜ, κωδικός' });
    const found = h('div');
    let timer;
    q.addEventListener('input', () => {
      clearTimeout(timer);
      timer = setTimeout(async () => {
        if (!q.value.trim()) { found.replaceChildren(); return; }
        const r = await api('customers?limit=8&q=' + encodeURIComponent(q.value.trim()));
        found.replaceChildren(table(['Κωδικός', 'Ονοματεπώνυμο', 'ΑΦΜ', ''], r.rows.map((c) => h('tr', null, td(c.code, 'mono'), td(c.name),
          td(c.afm, 'mono'), td(h('button', { onclick: async () => {
            try { await api('accounts/' + a.id + '/holders', { customer_id: c.id }); toast('Προστέθηκε'); route(); } catch (e) { toast(e.message, true); }
          } }, 'Προσθήκη'))))));
      }, 250);
    });
    out.append(h('h3', null, 'Νέος συνδικαιούχος'), q, found);
  }
  return out;
}

// ---- the cards of an account
const CARD_STATUS = { A: 'Ενεργή', B: 'Δεσμευμένη', C: 'Ακυρωμένη' };
const pan = (v) => v ? v.replace(/(.{4})/g, '$1 ').trim() : '';

function pinNotice(c) {
  return h('div', { class: 'card pin-notice' }, h('h3', null, 'Το PIN της κάρτας ' + pan(c.pan)),
    h('div', { class: 'pin' }, c.pin),
    h('p', { class: 'muted' }, 'Δώστε το στον πελάτη τώρα: δεν φαίνεται ξανά (η βάση κρατά μόνο ένα hash του). Ο πελάτης το αλλάζει στο ATM.'));
}

async function cardsTab(a) {
  const rows = await api('accounts/' + a.id + '/cards');
  const out = h('div');
  const notice = h('div');
  async function act(path, body, msg) {
    try {
      const r = await api(path, body);
      if (r.pin) { notice.replaceChildren(pinNotice(r)); await reload(); } else { toast(msg); route(); }
    } catch (e) { toast(e.message, true); }
  }
  async function reload() {
    const fresh = await api('accounts/' + a.id + '/cards');
    list.replaceChildren(cardTable(fresh));
  }
  function cardTable(rs) {
    return table(['Αριθμός', 'Κάτοχος', 'Λήξη', 'Κατάσταση', 'PIN', ''], rs.map((c) => h('tr', { class: c.status === 'C' ? 'rev' : null },
      td(pan(c.pan), 'mono'), td(c.holder), td(c.expires.slice(5, 7) + '/' + c.expires.slice(2, 4) + (c.expired === 'Y' ? ' (έληξε)' : '')),
      td(h('span', { class: 'badge ' + (c.status === 'A' ? 'O' : c.status === 'B' ? 'B' : 'C') }, CARD_STATUS[c.status])),
      td(c.has_pin === 'N' ? h('span', { class: 'warn' }, 'Χωρίς PIN') : c.pin_locked === 'Y' ? h('span', { class: 'badge no' }, 'Κλειδωμένο')
        : c.pin_failed > 0 ? c.pin_failed + ' λάθος' : '✔'),
      td(c.status === 'C' ? '' : h('div', { class: 'actions' },
        h('button', { onclick: () => { if (confirm('Νέο PIN για την κάρτα ' + pan(c.pan) + ';')) act('cards/' + c.id + '/pin', {}); } },
          c.has_pin === 'N' ? 'Έκδοση PIN' : 'Νέο PIN'),
        c.status === 'A' ? h('button', { onclick: () => act('cards/' + c.id + '/status', { status: 'B' }, 'Η κάρτα δεσμεύτηκε') }, 'Δέσμευση') : null,
        c.status === 'B' && can('MANAGER') ? h('button', { onclick: () => act('cards/' + c.id + '/status', { status: 'A' }, 'Η κάρτα ενεργοποιήθηκε') }, 'Ενεργοποίηση') : null,
        can('MANAGER') ? h('button', { class: 'danger', onclick: () => {
          if (confirm('Ακύρωση της κάρτας ' + pan(c.pan) + '; Δεν ξαναενεργοποιείται.')) act('cards/' + c.id + '/status', { status: 'C' }, 'Η κάρτα ακυρώθηκε');
        } }, 'Ακύρωση') : null)))));
  }
  const list = h('div', null, cardTable(rows));
  out.append(notice, list);
  if (a.status !== 'C') {
    out.append(h('h3', null, 'Νέα κάρτα'), form([field('Κάτοχος', sel('customer_id',
      Object.fromEntries(a.holders.map((c) => [String(c.id), c.name + (c.role === 'P' ? ' (κύριος)' : '')]))))], async (f) => {
      const r = await api('accounts/' + a.id + '/cards', { customer_id: Number(values(f).customer_id) });
      notice.replaceChildren(pinNotice(r));
      await reload();
    }, 'Έκδοση κάρτας'));
  }
  out.append(h('p', { class: 'muted' }, 'Το ATM: ', h('a', { href: '/atm/', target: '_blank', rel: 'noopener' }, '/atm/'),
    '. Οι αναλήψεις από ATM ακολουθούν τους κανόνες του καναλιού ATM (καρτέλα «Όρια και κανόνες»).'));
  return out;
}

// ---- the ATMs
async function atms() {
  const r = await api('atms');
  const rows = r.atms;
  const box = h('div', { class: 'card' }, h('h2', null, 'ATM'),
    h('p', { class: 'muted' }, 'Τα ATM δίνουν χαρτονομίσματα των ' + r.notes.join(', ') + ' €, ως ' + r.max_notes + ' σε μία ανάληψη. '
      + 'Οι καταθέσεις πάνε σε δική τους θήκη και δεν ξαναδίνονται.'));
  box.append(table(['Κωδικός', 'Όνομα', 'Διεύθυνση', 'Κασέτες', '#Μετρητά', '#Καταθέσεις', 'Κατάσταση', ''], rows.map((m) => h('tr', null,
    td(m.code, 'mono'), td(m.name), td(m.address),
    td(m.cassettes.map((k) => h('div', { class: k.pieces === 0 ? 'warn' : null }, k.note + ' €: ' + k.pieces.toLocaleString('el-GR')))),
    tdn(eur(m.cash)), tdn(eur(m.deposits)), td(m.active === 'Y' ? 'Σε λειτουργία' : h('span', { class: 'muted' }, 'Εκτός')),
    td(h('a', { href: '/atm/?atm=' + m.code, target: '_blank', rel: 'noopener' }, 'Οθόνη ATM'))))));
  if (can('MANAGER')) {
    box.append(h('h3', null, 'Γέμισμα κασέτας'), form([
      field('ATM', sel('code', Object.fromEntries(rows.map((m) => [m.code, m.code + ' · ' + m.name])))),
      field('Χαρτονόμισμα', sel('note', Object.fromEntries(r.notes.map((n) => [String(n), n + ' €'])))),
      field('Χαρτονομίσματα (αρνητικό: αφαίρεση)', h('input', { name: 'pieces', 'data-num': 1, inputmode: 'numeric', required: true }))],
    async (f) => {
      const v = values(f);
      await api('atms/' + v.code + '/fill', { note: Number(v.note), pieces: v.pieces });
      toast('Έγινε');
      route();
    }, 'Γέμισμα'));
    box.append(h('h3', null, 'Τα χαρτονομίσματα των ATM'), h('p', { class: 'muted' },
      'Ποια χαρτονομίσματα δίνουν όλα τα ATM (από 5, 10, 20, 50, 100, 200, 500 €), και πόσα το πολύ σε μία ανάληψη. '
      + 'Ένα νέο: μια άδεια κασέτα σε κάθε ATM. Ένα που φεύγει: πρώτα αδειάζουν οι κασέτες του.'),
    form([field('Χαρτονομίσματα (€, με κόμμα)', h('input', { name: 'notes', value: r.notes.slice().reverse().join(','), required: true })),
      field('Το πολύ σε μία ανάληψη', h('input', { name: 'max_notes', 'data-num': 1, inputmode: 'numeric', value: String(r.max_notes) }))],
    async (f) => {
      await api('atms/notes', values(f));
      toast('Αποθηκεύτηκε');
      route();
    }));
  }
  box.append(h('p', { class: 'muted' }, 'Οι αναλήψεις από ATM γίνονται με κάρτα και PIN (λογαριασμός → καρτέλα «Κάρτες»), μέσα στους κανόνες του καναλιού ATM.'));
  if (can('MANAGER')) {
    const result = h('div');
    box.append(h('h3', null, 'PIN για πολλές κάρτες'),
      h('p', { class: 'muted' }, 'Οι κάρτες χωρίς PIN (του demo: όλες) παίρνουν PIN: το ίδιο σε όλες (για δοκιμή), ή ένα νέο η καθεμιά. '
        + 'Η λίστα φαίνεται μία φορά: η βάση κρατά μόνο ένα hash.'),
      form([field('Το ίδιο PIN σε όλες (κενό: ένα νέο η καθεμιά)', h('input', { name: 'pin', inputmode: 'numeric', maxlength: 4, autocomplete: 'off' })),
        field('Ποιες κάρτες', sel('all', { N: 'Όσες δεν έχουν PIN', Y: 'Όλες (και όσες έχουν: νέο PIN)' }))], async (f) => {
        const v = values(f);
        if (v.all === 'Y' && !confirm('Νέο PIN σε όλες τις ενεργές κάρτες; Τα παλιά δεν ισχύουν πια.')) return;
        const rows = await api('cards/pins', { pin: v.pin, all: v.all === 'Y' });
        toast(rows.length + ' κάρτες με PIN');
        result.replaceChildren(rows.length ? table(['Κάρτα', 'Κάτοχος', 'Λογαριασμός', 'PIN'], rows.map((r) => h('tr', null,
          td(pan(r.pan), 'mono'), td(r.holder), td(iban(r.iban), 'mono'), td(r.pin, 'mono')))) : h('p', { class: 'muted' }, 'Καμία κάρτα χωρίς PIN.'));
      }, 'Έκδοση PIN'), result);
  }
  return box;
}

// ---- a movement
async function move(id) {
  const box = h('div', { class: 'card' }, h('h2', null, 'Νέα κίνηση'));
  const accIn = h('input', { name: 'account', placeholder: 'IBAN ή αριθμός λογαριασμού', required: true, class: 'mono' });
  const info = h('p', { class: 'muted' });
  let acc = null;
  async function find() {
    acc = null;
    info.textContent = '';
    const v = accIn.value.replace(/\s/g, '').toUpperCase();
    if (!v) return;
    try {
      let a;
      if (/^\d+$/.test(v)) a = await api('accounts/' + v);
      else {
        const r = await api('accounts?limit=2&q=' + encodeURIComponent(v));
        if (r.rows.length !== 1) throw new Error(r.rows.length ? 'Περισσότεροι από ένας: όλο το IBAN' : 'Δεν βρέθηκε λογαριασμός');
        a = await api('accounts/' + r.rows[0].id);
      }
      acc = a;
      info.replaceChildren(h('b', null, iban(a.iban)), ' · ' + a.holders.map((x) => x.name).join(', ') + ' · '
        + STATUS[a.status] + ' · υπόλοιπο ' + eur(a.balance) + ' · διαθέσιμο ' + eur(a.available));
    } catch (e) { info.replaceChildren(h('span', { class: 'error' }, e.message)); }
  }
  accIn.addEventListener('change', find);
  const kind = sel('kind', { DEP: 'Κατάθεση', WDR: 'Ανάληψη', TRF: 'Μεταφορά σε λογαριασμό της τράπεζας', OUT: 'Μεταφορά σε άλλη τράπεζα',
    INC: 'Μεταφορά από άλλη τράπεζα' });
  const to = field('Προς λογαριασμό (IBAN ή αριθμός)', h('input', { name: 'to_account', class: 'mono' }));
  const ib = field('IBAN άλλης τράπεζας', h('input', { name: 'iban', class: 'mono' }));
  const show = () => {
    to.classList.toggle('hidden', kind.value !== 'TRF');
    ib.classList.toggle('hidden', kind.value !== 'OUT' && kind.value !== 'INC');
  };
  kind.addEventListener('change', show);
  const result = h('div');
  box.append(form([field('Λογαριασμός', accIn), field('Κίνηση', kind), to, ib,
    field('Ποσό (€)', h('input', { name: 'amount', 'data-num': 1, inputmode: 'decimal', required: true })),
    field('Περιγραφή', h('input', { name: 'descr' })),
    field('Ημερομηνία αξίας', h('input', { name: 'value_date', type: 'date', min: S.day.open_day })),
    field('Κανάλι', sel('channel', { BR: 'Γκισέ', WEB: 'e-banking', ATM: 'ATM' }, 'BR'))], async (f) => {
    if (!acc) await find();
    if (!acc) throw new Error('Ο λογαριασμός;');
    const v = values(f);
    delete v.account;
    v.account_id = acc.id;
    const e = await api('movements', v);
    toast((KINDS[e.kind] || e.kind) + ' #' + e.id + ': υπόλοιπο ' + eur(e.balance));
    result.replaceChildren(entryView(e));
    f.querySelector('[name=amount]').value = '';
    f.querySelector('[name=descr]').value = '';
    await find();
    refreshDay();
  }, 'Καταχώριση'), info, result);
  show();
  if (id) {
    const a = await api('accounts/' + id);
    accIn.value = iban(a.iban);
    await find();
  }
  return box;
}

function entryView(e) {
  return h('div', { class: 'card' },
    h('h3', null, 'Εγγραφή #' + e.id + ' · ' + (KINDS[e.kind] || e.kind) + ' · ' + (CHANNELS[e.channel] || e.channel)),
    h('p', { class: 'muted' }, 'Λογισμός ' + date(e.book_date) + ' · αξία ' + date(e.value_date) + ' · ' + (e.descr || '')
      + ' · από ' + e.created_by + ' (' + e.created_at + ')'),
    e.reversal_of ? h('p', null, 'Αντιλογίζει την ', h('a', { href: '#/entry/' + e.reversal_of }, '#' + e.reversal_of)) : null,
    e.reversed_by ? h('p', { class: 'warn' }, 'Αντιλογίστηκε με την ', h('a', { href: '#/entry/' + e.reversed_by }, '#' + e.reversed_by)) : null,
    table(['Λογαριασμός', 'Κίνηση', '#Χρέωση', '#Πίστωση'], e.lines.map((l) => h('tr', null,
      td(l.account_id ? h('a', { href: '#/account/' + l.account_id, class: 'mono' }, iban(l.iban)) : l.gl_code + ' · ' + l.gl_name),
      td(OPS[l.op] || ''), tdn(l.debit ? money(l.debit) : ''), tdn(l.credit ? money(l.credit) : '')))));
}

async function entry(id) {
  const e = await api('entries/' + id);
  const box = h('div', null, entryView(e));
  if (can('MANAGER') && !e.reversal_of && !e.reversed_by && e.kind !== 'INT') {
    box.append(h('div', { class: 'card' }, h('h3', null, 'Αντιλογισμός'), form([
      field('Αιτία', h('input', { name: 'descr', placeholder: 'π.χ. διπλή χρέωση' }))], async (f) => {
      if (!confirm('Αντιλογισμός της εγγραφής #' + id + ';')) return;
      const r = await api('entries/' + id + '/reverse', values(f));
      toast('Αντιλογισμός #' + r.id);
      location.hash = '#/entry/' + r.id;
    }, 'Αντιλογισμός')));
  }
  return box;
}

// ---- the rules
function rulesTable(rows, reload) {
  const lvl = (r) => r.lvl === 'BANK' ? 'Τράπεζα' : r.lvl === 'PRODUCT' ? 'Προϊόν ' + r.product : iban(r.iban);
  return table(['Επίπεδο', 'Κίνηση', 'Κανάλι', 'Επιτρέπεται', ...RULE_FIELDS.map((f) => '#' + f[1]), ''],
    rows.map((r) => h('tr', null, td(r.account_id ? h('a', { href: '#/account/' + r.account_id + '/limits', class: 'mono' }, lvl(r)) : lvl(r)),
      td(OPS[r.op]), td(CHANNELS[r.channel]), td(r.allowed === 'N' ? h('span', { class: 'badge no' }, 'Όχι') : r.allowed === 'Y' ? 'Ναι' : ''),
      ...RULE_FIELDS.map((f) => tdn(r[f[0]] == null ? '' : ['day_count', 'month_count', 'free_month'].includes(f[0]) ? r[f[0]] : money(r[f[0]]))),
      td(can('MANAGER') ? h('button', { class: 'link', onclick: async () => {
        if (!confirm('Αφαίρεση του κανόνα;')) return;
        try { await api('rules/' + r.id + '/remove', {}); toast('Αφαιρέθηκε'); reload(); } catch (e) { toast(e.message, true); }
      } }, 'Αφαίρεση') : ''))));
}

function ruleForm(fixed, reload, products) {
  const fields = [];
  if (!fixed.account_id) {
    fields.push(field('Για', sel('product', Object.assign({ '': 'Όλη την τράπεζα' },
      Object.fromEntries((products || []).map((p) => [p.code, 'Προϊόν ' + p.code]))))));
  }
  fields.push(field('Κίνηση', sel('op', Object.fromEntries(Object.entries(OPS).filter(([k]) => k !== 'FEE')))),
    field('Κανάλι', sel('channel', { '*': 'Όλα', BR: 'Γκισέ', WEB: 'e-banking', ATM: 'ATM' })),
    field('Επιτρέπεται', sel('allowed', { '': '—', Y: 'Ναι', N: 'Όχι' })),
    ...RULE_FIELDS.map(([k, v]) => field(v, h('input', { name: k, 'data-num': 1, inputmode: 'decimal' }))));
  return h('div', null, h('p', { class: 'muted' }, 'Ξανά με την ίδια κίνηση και το ίδιο κανάλι: ο κανόνας αντικαθίσταται, με όλες του τις τιμές. Ένα κενό πεδίο: η τιμή έρχεται από το επόμενο επίπεδο.'),
    form(fields, async (f) => {
      const v = Object.assign(values(f), fixed);
      await api('rules', v);
      toast('Ο κανόνας αποθηκεύτηκε');
      reload();
    }));
}

async function rules() {
  const [rows, prods] = await Promise.all([api('rules'), api('products')]);
  const box = h('div');
  box.append(h('div', { class: 'card' }, h('h2', null, 'Κανόνες κινήσεων'),
    h('p', { class: 'muted' }, 'Κάθε τιμή έρχεται από τον πιο ειδικό κανόνα που την έχει: ο λογαριασμός πριν από το προϊόν του, πριν από την τράπεζα· '
      + 'σε καθένα, το κανάλι πριν από το «όλα». Ένα όριο του «όλα» μετράει όλα τα κανάλια μαζί· μια κίνηση που αντιλογίστηκε δεν μετράει.'),
    rulesTable(rows, () => route())));
  if (can('MANAGER')) box.append(h('div', { class: 'card' }, h('h2', null, 'Νέος κανόνας'), ruleForm({}, () => route(), prods)));
  return box;
}

// ---- the products
async function products() {
  const rows = await api('products');
  const box = h('div');
  for (const p of rows) {
    const card = h('div', { class: 'card' }, h('h2', null, p.name + ' ', h('span', { class: 'muted mono' }, p.code)),
      h('div', { class: 'kv' }, kv('Είδος', p.kind), kv('Βάση ημερών', p.day_basis), kv('Κεφαλαιοποίηση', 'ανά ' + CAP[p.cap_every]),
        kv('Φόρος τόκων', num(p.tax_rate) + ' %'), kv('Επιτόκιο υπερανάληψης', num(p.od_rate) + ' %'), kv('Λογαριασμοί', p.accounts)),
      h('h3', null, 'Επιτόκια τώρα'),
      table(['#Από υπόλοιπο', '#Επιτόκιο %'], p.rates_now.map((r) => h('tr', null, tdn(eur(r.min_balance)), tdn(num(r.rate))))),
      h('details', null, h('summary', null, 'Ιστορικό επιτοκίων'),
        table(['Από', '#Κλιμάκιο', '#Επιτόκιο %'], p.rates.map((r) => h('tr', null, td(date(r.valid_from)), tdn(eur(r.min_balance)), tdn(num(r.rate)))))));
    if (can('MANAGER')) {
      card.append(h('h3', null, 'Αλλαγή επιτοκίου'), form([
        field('Από', h('input', { name: 'valid_from', type: 'date', value: S.day.open_day, min: S.day.open_day })),
        field('Κλιμάκιο από (€)', h('input', { name: 'min_balance', 'data-num': 1, value: '0', inputmode: 'decimal' })),
        field('Επιτόκιο %', h('input', { name: 'rate', 'data-num': 1, inputmode: 'decimal', required: true }))], async (f) => {
        await api('products/' + p.code + '/rates', values(f));
        toast('Το επιτόκιο αποθηκεύτηκε');
        route();
      }));
    }
    box.append(card);
  }
  return box;
}

// ---- the day
async function day() {
  await refreshDay();
  const d = S.day;
  const box = h('div', { class: 'card' }, h('h2', null, 'Εργάσιμη ημέρα ' + date(d.open_day)),
    h('div', { class: 'kv' }, kv('Τελευταία κλεισμένη', date(d.last_closed)), kv('Εγγραφές της ημέρας', d.entries),
      kv('Ανοιχτοί λογαριασμοί', d.accounts), kv('Ενεργοί πελάτες', d.customers),
      kv('Έλεγχος (BK_CHECK)', d.check_rows === 0 ? '✔ όλα συμφωνούν' : d.check_rows + ' διαφορές')));
  if (d.check_rows) {
    const rows = await api('check');
    box.append(h('h3', { class: 'bad' }, 'Διαφορές'), table(['Τι', 'Αναφορά', 'Λεπτομέρεια'], rows.map((r) => h('tr', null, td(r.what), td(r.ref), td(r.detail)))));
  }
  if (can('MANAGER')) {
    box.append(h('h3', null, 'Κλείσιμο ημέρας'), h('p', { class: 'muted' },
      'Οι τόκοι της ημέρας για κάθε ανοιχτό λογαριασμό, και στο τέλος της περιόδου η κεφαλαιοποίηση με τον φόρο. Μετά η εργάσιμη πάει στην επόμενη.'),
    h('button', { class: 'primary', onclick: async (ev) => {
      if (!confirm('Κλείσιμο της ημέρας ' + date(d.open_day) + ';')) return;
      ev.target.disabled = true;
      try { const r = await api('day/close', {}); toast('Έκλεισε η ' + date(r.closed)); route(); } catch (e) { toast(e.message, true); ev.target.disabled = false; }
    } }, 'Κλείσιμο της ' + date(d.open_day)));
  }
  return box;
}

// ---- the users
async function users() {
  const rows = await api('users');
  const box = h('div');
  box.append(h('div', { class: 'card' }, h('h2', null, 'Χρήστες'),
    table(['Χρήστης', 'Ονοματεπώνυμο', 'Ρόλος', 'Κατάσταση', 'Τελευταία είσοδος', ''], rows.map((u) => {
      const role = sel('role', Object.fromEntries(ROLES.map((r) => [r, r])), u.role);
      role.addEventListener('change', () => change(u, { role: role.value }));
      return h('tr', null, td(u.username, 'mono'), td(u.full_name), td(role),
        td(u.locked === 'Y' ? h('span', { class: 'badge no' }, 'Κλειδωμένος') : u.active === 'Y' ? 'Ενεργός' : h('span', { class: 'muted' }, 'Ανενεργός')),
        td(u.last_login || '—'),
        td(h('div', { class: 'actions' },
          u.locked === 'Y' ? h('button', { onclick: () => change(u, { unlock: true }) }, 'Ξεκλείδωμα') : null,
          h('button', { onclick: () => change(u, { active: u.active === 'Y' ? 'N' : 'Y' }) }, u.active === 'Y' ? 'Απενεργοποίηση' : 'Ενεργοποίηση'),
          h('button', { onclick: () => {
            const pw = prompt('Νέος κωδικός για ' + u.username + ' (τουλάχιστον 8 χαρακτήρες)');
            if (pw) change(u, { password: pw });
          } }, 'Νέος κωδικός'))));
    }))));
  async function change(u, body) {
    try { await api('users/' + u.id, body); toast('Έγινε'); route(); } catch (e) { toast(e.message, true); route(); }
  }
  box.append(h('div', { class: 'card' }, h('h2', null, 'Νέος χρήστης'), form([
    field('Χρήστης', h('input', { name: 'username', required: true, autocomplete: 'off' })),
    field('Ονοματεπώνυμο', h('input', { name: 'full_name', required: true })),
    field('Ρόλος', sel('role', { TELLER: 'TELLER (γκισέ)', MANAGER: 'MANAGER', ADMIN: 'ADMIN' })),
    field('Κωδικός', h('input', { name: 'password', type: 'password', required: true, minlength: 8, autocomplete: 'new-password' }))],
  async (f) => {
    await api('users', values(f));
    toast('Ο χρήστης καταχωρίστηκε');
    route();
  }, 'Καταχώριση')));
  return box;
}

start();
