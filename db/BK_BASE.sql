-- BK_BASE.sql -- what the bank has from the start: its own accounts (GL), its codes, its products of deposits and
-- their rates. Only what is missing is added (a second run changes nothing).

insert into bk_gl (code, name, kind)
select v.code, v.name, v.kind from (values
  ('CASH',    'Ταμείο',                                  'A'),
  ('CLEAR',   'Μεταφορές σε άλλες τράπεζες',             'A'),
  ('INT_EXP', 'Τόκοι καταθέσεων (έξοδο)',                'E'),
  ('INT_INC', 'Τόκοι υπερανάληψης (έσοδο)',              'I'),
  ('TAX',     'Φόρος τόκων προς απόδοση',                'L'),
  ('FEE',     'Προμήθειες (έσοδο)',                      'I')
) v (code, name, kind)
where not exists (select 1 from bk_gl g where g.code = v.code);

insert into bk_setting (name, value)
select v.name, v.value from (values
  ('BANK_CODE', '999'),           -- (no real bank: 999)
  ('BRANCH_CODE', '0001')
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
commit;
