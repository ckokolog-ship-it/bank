-- BK_BASE.sql -- what the bank has from the start: its own accounts (GL), its codes, its products of deposits and
-- their rates. Only what is missing is added (a second run changes nothing).

insert into bk_gl (code, name, kind)
select v.code, v.name, v.kind from (values
  ('CASH',    'Ταμείο',                                  'A'),
  ('CLEAR',   'Μεταφορές σε άλλες τράπεζες',             'A'),
  ('INT_EXP', 'Τόκοι καταθέσεων (έξοδο)',                'E'),
  ('INT_INC', 'Τόκοι υπερανάληψης (έσοδο)',              'I'),
  ('TAX',     'Φόρος τόκων προς απόδοση',                'L'),
  ('FEE',     'Προμήθειες (έσοδο)',                      'I'),
  ('CC_MERCH', 'Αγορές με πιστωτικές κάρτες (προς εκκαθάριση)', 'L'),
  ('CC_INT',  'Τόκοι πιστωτικών καρτών (έσοδο)',         'I'),
  ('FX_POS',  'Θέση συναλλάγματος',                      'A'),
  ('FX_INC',  'Έσοδα από συνάλλαγμα',                    'I'),
  ('LN_INT',  'Τόκοι δανείων (έσοδο)',                   'I')
) v (code, name, kind)
where not exists (select 1 from bk_gl g where g.code = v.code);

insert into bk_setting (name, value)
select v.name, v.value from (values
  ('BANK_CODE', '999'),           -- (no real bank: 999)
  ('BRANCH_CODE', '0001'),
  ('ATM_NOTES', '20,50'),         -- the notes the ATMs give (€)
  ('ATM_MAX_NOTES', '40'),        -- the most notes of one withdrawal
  ('CC_HOLD_DAYS', '7'),          -- an authorization of a credit card not posted in so many days: released
  ('BASE_CURRENCY', 'EUR')        -- the currency of the bank: every line in it too (not changed after the first entry)
) v (name, value)
where not exists (select 1 from bk_setting s where s.name = v.name);

insert into bk_product (code, name, kind, day_basis, cap_every, tax_rate, od_rate)
select v.code, v.name, v.kind, v.day_basis, v.cap_every, v.tax_rate, v.od_rate from (values
  ('CUR', 'Λογαριασμός όψεως',              'CUR', 'ACT365', 'Q', 15, 14.5),
  ('BUS', 'Επαγγελματικός όψεως',           'CUR', '30360',  'M', 15, 12),
  ('SAV', 'Ταμιευτήριο',                    'SAV', 'ACT365', 'Q', 15, 0),
  ('SAVP', 'Ταμιευτήριο Plus',              'SAV', 'ACT360', 'M', 15, 0)
) v (code, name, kind, day_basis, cap_every, tax_rate, od_rate)
where not exists (select 1 from bk_product p where p.code = v.code);

-- the currencies (the margin of the bank on a conversion, % each side) and their rates from the start (1 EUR = ...)
insert into bk_currency (code, name, decimals, spread_pct)
select v.code, v.name, v.decimals, v.spread from (values
  ('USD', 'Δολάριο ΗΠΑ', 2, 0.5), ('GBP', 'Λίρα Αγγλίας', 2, 0.5), ('CHF', 'Φράγκο Ελβετίας', 2, 0.5),
  ('JPY', 'Γιεν Ιαπωνίας', 0, 0.75), ('SEK', 'Κορόνα Σουηδίας', 2, 0.75), ('NOK', 'Κορόνα Νορβηγίας', 2, 0.75),
  ('DKK', 'Κορόνα Δανίας', 2, 0.5), ('CAD', 'Δολάριο Καναδά', 2, 0.75), ('AUD', 'Δολάριο Αυστραλίας', 2, 0.75)
) v (code, name, decimals, spread)
where not exists (select 1 from bk_currency c where c.code = v.code);
insert into bk_fx_rate (currency, day, mid)
select v.code, date '2020-01-01', v.mid from (values
  ('USD', 1.08), ('GBP', 0.85), ('CHF', 0.95), ('JPY', 160), ('SEK', 11.40), ('NOK', 11.60), ('DKK', 7.46),
  ('CAD', 1.47), ('AUD', 1.63)
) v (code, mid)
where not exists (select 1 from bk_fx_rate r where r.currency = v.code);

-- the credit cards: their products and terms (BK_CC_PRODUCT)
insert into bk_product (code, name, kind, day_basis, cap_every, tax_rate, od_rate)
select v.code, v.name, 'CC', 'ACT365', 'M', 0, 0 from (values
  ('VISA', 'Πιστωτική κάρτα Classic'),
  ('GOLD', 'Πιστωτική κάρτα Gold')
) v (code, name)
where not exists (select 1 from bk_product p where p.code = v.code);
insert into bk_cc_product (product_id, rate, min_pct, min_amount, due_days, late_fee)
select p.id, v.rate, v.min_pct, v.min_amount, v.due_days, v.late_fee from (values
  ('VISA', 16.50, 3, 20, 25, 10),
  ('GOLD', 13.90, 2.5, 30, 25, 15)
) v (code, rate, min_pct, min_amount, due_days, late_fee)
join bk_product p on p.code = v.code
where not exists (select 1 from bk_cc_product c where c.product_id = p.id);

-- the rates (% a year) from the start; a product with rates of its own already: as it is
insert into bk_rate (product_id, valid_from, min_balance, rate)
select p.id, date '2020-01-01', v.min_balance, v.rate from (values
  ('CUR', 0, 0.01),
  ('BUS', 0, 0),
  ('SAV', 0, 0.05), ('SAV', 5000, 0.10), ('SAV', 20000, 0.25),
  ('SAVP', 0, 0.50), ('SAVP', 10000, 1.00)
) v (code, min_balance, rate)
join bk_product p on p.code = v.code
where not exists (select 1 from bk_rate r where r.product_id = p.id);

-- the ATMs, with their first cash
insert into bk_atm (code, name, address, cash)
select v.code, v.name, v.address, v.cash from (values
  ('ATM01', 'Πάτρα κέντρο',        'Αγίου Νικολάου 12, Πάτρα',       30000),
  ('ATM02', 'Αθήνα Σύνταγμα',      'Πανεπιστημίου 5, Αθήνα',         50000),
  ('ATM03', 'Θεσσαλονίκη λιμάνι',  'Λεωφόρος Νίκης 30, Θεσσαλονίκη', 40000)
) v (code, name, address, cash)
where not exists (select 1 from bk_atm a where a.code = v.code);

-- their cassettes (as their cash): of 50 € and of 20 €
insert into bk_atm_note (atm_id, note, pieces)
select a.id, v.note, v.pieces from (values
  ('ATM01', 50, 300), ('ATM01', 20, 750),
  ('ATM02', 50, 600), ('ATM02', 20, 1000),
  ('ATM03', 50, 400), ('ATM03', 20, 1000)
) v (code, note, pieces)
join bk_atm a on a.code = v.code
where not exists (select 1 from bk_atm_note n where n.atm_id = a.id);
commit;

-- the loans: an index (Euribor 3 months) from the start, the products and their terms (BK_LN_PRODUCT)
insert into bk_ln_index (code, day, rate)
select 'EURIBOR3M', date '2020-01-01', 2.5 from dual
where not exists (select 1 from bk_ln_index where code = 'EURIBOR3M');
insert into bk_product (code, name, kind, day_basis, cap_every, tax_rate, od_rate)
select v.code, v.name, 'LN', '30360', 'M', 0, 0 from (values
  ('HOME', 'Στεγαστικό δάνειο (κυμαινόμενο)'),
  ('CONS', 'Καταναλωτικό δάνειο (σταθερό)')
) v (code, name)
where not exists (select 1 from bk_product p where p.code = v.code);
insert into bk_ln_product (product_id, rate_type, rate, index_code, reset_months, late_add, late_fee, grace_days, prepay_pct, max_months)
select p.id, v.rt, v.rate, v.idx, v.reset, v.late_add, v.fee, v.grace, v.prepay, v.mx from (values
  ('HOME', 'V', 2.20, 'EURIBOR3M', 3, 2.5, 20, 5, 0, 360),
  ('CONS', 'F', 9.50, null, 3, 2.5, 15, 5, 1, 84)
) v (code, rt, rate, idx, reset, late_add, fee, grace, prepay, mx)
join bk_product p on p.code = v.code
where not exists (select 1 from bk_ln_product x where x.product_id = p.id);
commit;

-- the currencies each product opens in (the first: by default), and its rates in the others; a product with
-- currencies of its own already: as it is
update bk_product p set currencies = (select v.cur from (values
  ('CUR', 'EUR,USD,GBP,CHF'), ('BUS', 'EUR,USD'), ('SAV', 'EUR,USD,GBP')) v (code, cur) where v.code = p.code)
where p.currencies = 'EUR' and p.code in ('CUR', 'BUS', 'SAV');
insert into bk_rate (product_id, currency, valid_from, min_balance, rate)
select p.id, v.cur, date '2020-01-01', v.min_balance, v.rate from (values
  ('CUR', 'USD', 0, 0.05), ('CUR', 'GBP', 0, 0.05), ('CUR', 'CHF', 0, 0),
  ('BUS', 'USD', 0, 0),
  ('SAV', 'USD', 0, 0.50), ('SAV', 'USD', 10000, 1.00), ('SAV', 'GBP', 0, 0.40)
) v (code, cur, min_balance, rate)
join bk_product p on p.code = v.code
where not exists (select 1 from bk_rate r where r.product_id = p.id and r.currency = v.cur);
commit;
