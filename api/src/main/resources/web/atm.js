// atm.js -- the ATM of the bank: a card and its PIN, then its account (/api/atm/, bk-api). The screen with its
// keys at the sides (their options), the keypad (digits, Ακύρωση, Διόρθωση, Εντάξει), the slots: the card, the
// cash, the receipt. The rules are all in the database (the channel ATM): its errors are shown as they come.
'use strict';

const $ = (id) => document.getElementById(id);
const S = { atm: null, token: null, holder: null, iban: null, idle: null, screen: null };
const IDLE_MS = 90000;

function h(tag, attrs, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') e.className = v;
    else e.setAttribute(k, v);
  }
  for (const k of kids.flat()) {
    if (k == null || k === false) continue;
    e.append(k instanceof Node ? k : document.createTextNode(String(k)));
  }
  return e;
}
const money = (v) => Number(v).toLocaleString('el-GR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' €';
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------------------------------
// the service
async function call(what, body) {
  const opt = { method: body === undefined ? 'GET' : 'POST', headers: {} };
  if (S.token) opt.headers.Authorization = 'Bearer ' + S.token;
  if (body !== undefined) {
    opt.headers['Content-Type'] = 'application/json';
    opt.body = JSON.stringify(body);
  }
  const r = await fetch('/api/atm/' + what, opt);
  const j = await r.json().catch(() => ({ message: 'Το ATM δεν μπορεί να εξυπηρετήσει αυτή τη στιγμή' }));
  if (!r.ok) {
    const e = new Error(j.message || 'Λάθος ' + r.status);
    e.status = r.status;
    e.code = j.error;
    throw e;
  }
  return j;
}
const op = (what, body) => call(S.atm.code + '/' + what, body || {});

// ---------------------------------------------------------------------------------------------
// the screen: a title, a line under it, its body, the options of the side keys (4 left, 4 right: [text,
// action]), and what the keypad does on it (digits, OK, correction, cancel)
function show(spec) {
  S.screen = spec;
  const sc = $('screen');
  const opts = h('div', { class: 'opts' });
  for (let i = 0; i < 4; i++) {
    const l = (spec.left || [])[i];
    const r = (spec.right || [])[i];
    opts.append(h('div', { class: 'opt l' }, l ? l[0] : ''), h('div', { class: 'opt r' }, r ? r[0] : ''));
  }
  sc.replaceChildren(h('h1', null, spec.title || ''), h('div', { class: 'sub' }, spec.sub || ''),
    ...(spec.body || []).filter(Boolean), opts);
  touch();
}

function side(which, i) {
  const o = S.screen && (S.screen[which] || [])[i];
  if (o && o[1]) o[1]();
}

function key(k) {
  const s = S.screen;
  if (!s) return;
  touch();
  if (k === 'cancel') return s.cancel ? s.cancel() : (S.token ? menu() : null);
  if (k === 'ok') return s.ok && s.ok();
  if (k === 'fix') return s.fix && s.fix();
  if (/^\d$/.test(k) && s.digit) s.digit(k);
}

// an entry of digits on the screen: masked (the PIN) or a sum, or an IBAN
function entry(spec) {
  let v = '';
  const out = h('div', { class: 'big' });
  const draw = () => { out.textContent = spec.draw(v); };
  draw();
  show(Object.assign({}, spec, {
    body: [...(spec.body || []), out, spec.note ? h('div', { class: 'msg' }, spec.note) : null],
    digit: (d) => { if (v.length < spec.max) { v += d; draw(); } },
    fix: () => { v = v.slice(0, -1); draw(); },
    ok: () => spec.done(v),
    cancel: spec.cancel,
  }));
}

function busy(text) {
  show({ title: text || 'Παρακαλώ περιμένετε…', body: [h('div', { class: 'big' }, '⏳')] });
}

function error(e, back) {
  if (e.status === 401 && e.code === 'no_session') return finish('Ο χρόνος τελείωσε');
  show({ title: 'Η συναλλαγή δεν έγινε', body: [h('div', { class: 'err' }, e.message)],
    right: [null, null, null, ['Πίσω', back || menu]], ok: back || menu });
}

// ---------------------------------------------------------------------------------------------
// the idle time: 90 seconds without a key, the card back
function touch() {
  clearTimeout(S.idle);
  if (S.token) S.idle = setTimeout(() => finish('Ο χρόνος τελείωσε'), IDLE_MS);
}

async function finish(title) {
  clearTimeout(S.idle);
  if (S.token) {
    try { await op('end'); } catch (e) { /* the session gone already */ }
  }
  S.token = null;
  $('card-slot').classList.remove('on');
  show({ title: title || 'Ευχαριστούμε', sub: 'Πάρτε την κάρτα σας', body: [h('div', { class: 'big' }, '💳')] });
  await wait(2500);
  if (!S.token) welcome();
}

function welcome() {
  show({ title: 'Καλώς ήρθατε', sub: S.atm ? S.atm.name + ' · ' + (S.atm.address || '') : '',
    body: [h('div', { class: 'big' }, '💳'), h('div', { class: 'msg' }, 'Εισάγετε την κάρτα σας'),
      S.atm && S.atm.cash_ok !== 'Y' ? h('div', { class: 'err' }, 'Μόνο συναλλαγές χωρίς μετρητά') : null] });
  $('pan').focus();
}

// ---------------------------------------------------------------------------------------------
// the card and its PIN
async function insert(pan) {
  if (S.token) return;
  const p = pan.replace(/\D/g, '');
  if (p.length < 12) { $('pan').focus(); return; }
  $('card-slot').classList.add('on');
  entry({ title: 'Πληκτρολογήστε το PIN σας', sub: 'Κάρτα •••• ' + p.slice(-4), max: 4,
    draw: (v) => '●'.repeat(v.length) + '○'.repeat(4 - v.length),
    note: 'και πατήστε Εντάξει',
    cancel: () => { $('card-slot').classList.remove('on'); welcome(); },
    done: async (pin) => {
      if (pin.length !== 4) return;
      busy();
      try {
        const r = await call(S.atm.code + '/login', { pan: p, pin });
        S.token = r.token;
        S.holder = r.holder;
        S.iban = r.iban;
        $('pan').value = '';
        menu();
      } catch (e) {
        if (e.code === 'bad_pin') {
          show({ title: 'Λάθος PIN', body: [h('div', { class: 'err' }, e.message)], right: [null, null, null, ['Ξανά', () => insert(p)]],
            ok: () => insert(p), cancel: () => { $('card-slot').classList.remove('on'); welcome(); } });
        } else {
          $('card-slot').classList.remove('on');
          show({ title: 'Η κάρτα δεν γίνεται δεκτή', body: [h('div', { class: 'err' }, e.message)],
            sub: 'Πάρτε την κάρτα σας', right: [null, null, null, ['Εντάξει', welcome]], ok: welcome });
        }
      }
    } });
}

// ---------------------------------------------------------------------------------------------
// the menu
function menu() {
  show({ title: 'Επιλέξτε συναλλαγή', sub: S.holder + ' · ' + S.iban,
    left: [['Ανάληψη', withdraw], ['Κατάθεση', deposit], ['Μεταφορά', transfer], ['Αλλαγή PIN', pin]],
    right: [['Υπόλοιπο', balance], ['Κινήσεις', statement], null, ['Τέλος', () => finish()]],
    cancel: () => finish() });
}

function another(title, body) {
  show({ title, body, sub: 'Θέλετε άλλη συναλλαγή;', left: [null, null, null, ['Ναι', menu]],
    right: [null, null, null, ['Όχι', () => finish()]], ok: menu, cancel: () => finish() });
}

async function balance() {
  busy();
  try {
    const r = await op('balance');
    printReceipt('ΥΠΟΛΟΙΠΟ', r, [['Υπόλοιπο', money(r.balance)], ['Διαθέσιμο', money(r.available)]]);
    another('Υπόλοιπο', [h('div', { class: 'big' }, money(r.balance)),
      h('div', { class: 'msg' }, 'Διαθέσιμο ' + money(r.available)),
      h('div', { class: 'msg' }, 'Ανάληψη σήμερα από ATM ως ' + money(r.withdraw_today))]);
  } catch (e) { error(e); }
}

async function withdraw() {
  busy();
  let today = null;
  try { today = (await op('balance')).withdraw_today; } catch (e) { return error(e); }
  const go = (a) => () => doWithdraw(a);
  show({ title: 'Ανάληψη', sub: 'Μπορείτε σήμερα ως ' + money(today),
    left: [['20 €', go(20)], ['50 €', go(50)], ['100 €', go(100)], ['200 €', go(200)]],
    right: [['300 €', go(300)], ['400 €', go(400)], ['Άλλο ποσό', () => amount('Ανάληψη: άλλο ποσό', 'σε δεκάδες: χαρτονομίσματα 10, 20, 50 €', doWithdraw)],
      ['Πίσω', menu]] });
}

function amount(title, note, done) {
  entry({ title, note, max: 5, draw: (v) => (v ? Number(v).toLocaleString('el-GR') : '0') + ' €',
    cancel: menu, done: (v) => { if (Number(v) > 0) done(Number(v)); } });
}

async function doWithdraw(a) {
  busy('Η ανάληψη γίνεται…');
  try {
    const r = await op('withdraw', { amount: a });
    notes(r.notes);
    printReceipt('ΑΝΑΛΗΨΗ', r, [['Ποσό', money(a)], r.fee > 0 ? ['Προμήθεια', money(r.fee)] : null,
      ['Υπόλοιπο', money(r.balance)], ['Διαθέσιμο', money(r.available)]]);
    another('Πάρτε τα χρήματά σας', [h('div', { class: 'big' }, money(a)),
      r.fee > 0 ? h('div', { class: 'msg' }, 'Προμήθεια ' + money(r.fee)) : null,
      h('div', { class: 'msg' }, 'Υπόλοιπο ' + money(r.balance))]);
  } catch (e) { error(e, withdraw); }
}

function deposit() {
  amount('Κατάθεση μετρητών', 'το ποσό των χαρτονομισμάτων', (a) => {
    show({ title: 'Τοποθετήστε ' + money(a), sub: 'στη θήκη των μετρητών, και πατήστε Εντάξει',
      body: [h('div', { class: 'big' }, '💶')], left: [null, null, null, ['Ακύρωση', menu]],
      right: [null, null, null, ['Εντάξει', go]], ok: go, cancel: menu });
    async function go() {
      busy('Η καταμέτρηση γίνεται…');
      try {
        const r = await op('deposit', { amount: a });
        printReceipt('ΚΑΤΑΘΕΣΗ', r, [['Ποσό', money(a)], ['Υπόλοιπο', money(r.balance)]]);
        another('Η κατάθεση έγινε', [h('div', { class: 'big' }, money(a)), h('div', { class: 'msg' }, 'Υπόλοιπο ' + money(r.balance))]);
      } catch (e) { error(e, deposit); }
    }
  });
}

function transfer() {
  entry({ title: 'Μεταφορά σε λογαριασμό της τράπεζας', note: 'IBAN: τα 25 ψηφία μετά το GR', max: 25,
    draw: (v) => ('GR' + v).replace(/(.{4})/g, '$1 ').trim(), cancel: menu,
    done: (v) => {
      if (v.length !== 25) return;
      const to = 'GR' + v;
      amount('Ποσό μεταφοράς', 'προς ' + to.replace(/(.{4})/g, '$1 ').trim(), (a) => {
        const go = async () => {
          busy('Η μεταφορά γίνεται…');
          try {
            const r = await op('transfer', { iban: to, amount: a });
            printReceipt('ΜΕΤΑΦΟΡΑ', r, [['Προς', to.slice(0, 4) + ' •••• ' + to.slice(-4)], ['Ποσό', money(a)],
              r.fee > 0 ? ['Προμήθεια', money(r.fee)] : null, ['Υπόλοιπο', money(r.balance)]]);
            another('Η μεταφορά έγινε', [h('div', { class: 'big' }, money(a)), h('div', { class: 'msg' }, 'Υπόλοιπο ' + money(r.balance))]);
          } catch (e) { error(e, transfer); }
        };
        show({ title: 'Επιβεβαίωση', body: [h('div', { class: 'msg' }, 'Μεταφορά ' + money(a)),
          h('div', { class: 'msg' }, 'προς ' + to.replace(/(.{4})/g, '$1 ').trim())],
        left: [null, null, null, ['Ακύρωση', menu]], right: [null, null, null, ['Εντάξει', go]], ok: go, cancel: menu });
      });
    } });
}

async function statement() {
  busy();
  try {
    const r = await op('statement');
    const t = h('table', { class: 'rows' }, r.rows.map((x) => h('tr', null,
      h('td', null, x.book_date.slice(8, 10) + '/' + x.book_date.slice(5, 7)), h('td', { class: 'd' }, x.descr || ''),
      h('td', { class: 'n' }, (x.amount > 0 ? '+' : '') + Number(x.amount).toLocaleString('el-GR', { minimumFractionDigits: 2 })))));
    printReceipt('ΚΙΝΗΣΕΙΣ', { iban: r.iban }, r.rows.map((x) => [x.book_date.slice(8, 10) + '/' + x.book_date.slice(5, 7) + ' '
      + (x.descr || '').slice(0, 18), Number(x.amount).toLocaleString('el-GR', { minimumFractionDigits: 2 })]).concat([['Υπόλοιπο', money(r.balance)]]));
    show({ title: 'Οι τελευταίες κινήσεις', body: [t], right: [null, null, null, ['Πίσω', menu]], ok: menu });
  } catch (e) { error(e); }
}

function pin() {
  entry({ title: 'Νέο PIN', note: '4 ψηφία', max: 4, draw: (v) => '●'.repeat(v.length) + '○'.repeat(4 - v.length), cancel: menu,
    done: (p1) => {
      if (p1.length !== 4) return;
      entry({ title: 'Ξανά το νέο PIN', max: 4, draw: (v) => '●'.repeat(v.length) + '○'.repeat(4 - v.length), cancel: menu,
        done: async (p2) => {
          if (p2.length !== 4) return;
          if (p1 !== p2) return error(new Error('Τα δύο PIN δεν είναι ίδια'), pin);
          busy();
          try {
            await op('pin', { pin: p1 });
            another('Το PIN άλλαξε', [h('div', { class: 'big' }, '✔')]);
          } catch (e) { error(e, pin); }
        } });
    } });
}

// ---------------------------------------------------------------------------------------------
// the slots: the notes, the receipt
function notes(n) {
  const box = $('notes');
  box.replaceChildren();
  let i = 0;
  for (const [v, c] of Object.entries(n || {}).sort((a, b) => b[0] - a[0])) {
    for (let k = 0; k < c; k++) {
      const e = h('div', { class: 'note n' + v }, v + ' €');
      e.style.animationDelay = (i++ * 0.08) + 's';
      box.append(e);
    }
  }
  setTimeout(() => box.replaceChildren(), 8000);
}

function printReceipt(what, r, lines) {
  const w = 34;
  const row = (a, b) => a + ' '.repeat(Math.max(1, w - a.length - b.length)) + b;
  const now = new Date();
  const out = ['BANK · ' + (S.atm.name || ''), S.atm.code + ' · ' + now.toLocaleString('el-GR'), '-'.repeat(w), what,
    row('Λογαριασμός', r.iban || S.iban), r.entry_id ? row('Συναλλαγή', '#' + r.entry_id) : null,
    ...lines.filter(Boolean).map(([a, b]) => row(a, b)), '-'.repeat(w), 'Ευχαριστούμε'].filter(Boolean);
  const el = $('receipt');
  el.classList.remove('empty');
  el.textContent = out.join('\n');
  el.style.animation = 'none';
  void el.offsetWidth;
  el.style.animation = '';
}

// ---------------------------------------------------------------------------------------------
// the keys
function buildKeys() {
  for (const side_ of ['left', 'right']) {
    const box = $('keys-' + side_);
    for (let i = 0; i < 4; i++) {
      const b = h('button', { type: 'button', 'aria-label': (side_ === 'left' ? 'Αριστερό' : 'Δεξί') + ' πλήκτρο ' + (i + 1) });
      b.addEventListener('click', () => side(side_, i));
      box.append(b);
    }
  }
  const pad = $('pad');
  const keys = [['1'], ['2'], ['3'], ['Ακύρωση', 'cancel'], ['4'], ['5'], ['6'], ['Διόρθωση', 'fix'], ['7'], ['8'], ['9'], ['Εντάξει', 'ok'],
    [''], ['0'], [''], ['']];
  for (const [label, k] of keys) {
    if (!label) { pad.append(h('span')); continue; }
    const b = h('button', { type: 'button', class: k || null }, label);
    b.addEventListener('click', () => key(k || label));
    pad.append(b);
  }
  document.addEventListener('keydown', (ev) => {
    if (ev.target === $('pan') || ev.target.tagName === 'SELECT') return;
    if (/^\d$/.test(ev.key)) key(ev.key);
    else if (ev.key === 'Enter') key('ok');
    else if (ev.key === 'Backspace') key('fix');
    else if (ev.key === 'Escape') key('cancel');
    else return;
    ev.preventDefault();
  });
  $('card-form').addEventListener('submit', (ev) => { ev.preventDefault(); insert($('pan').value); });
}

async function start() {
  buildKeys();
  try {
    const list = await call('');
    const want = (new URLSearchParams(location.search).get('atm') || '').toUpperCase();
    const code = (list.find((a) => a.code === want) || list[0] || {}).code;
    const pick = $('atm-pick');
    pick.replaceChildren(...list.map((a) => h('option', { value: a.code }, a.code + ' · ' + a.name)));
    pick.value = code;
    pick.addEventListener('change', () => { location.search = '?atm=' + pick.value; });
    if (!code) throw new Error('Κανένα ATM δεν λειτουργεί');
    S.atm = await call(code);
    $('atm-name').textContent = S.atm.code + ' · ' + S.atm.name;
    document.title = 'ATM ' + S.atm.code + ' · Bank';
    welcome();
  } catch (e) {
    show({ title: 'Εκτός λειτουργίας', body: [h('div', { class: 'err' }, e.message)] });
  }
}

start();
