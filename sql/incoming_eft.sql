-- Incoming EFT reconciliation flow
-- Logic:
-- 1. Clean and standardize EBRA, EBRV and SCTEF raw data
-- 2. Exclude reversal/cancelled records through EBRA vs EBRV comparison
-- 3. Reconcile approved EBRA transactions against SCTEF
-- 4. Generate final matched / unmatched outputs

-- EBRA base filtering:
-- Keep only approved incoming EFT transactions for destination bank 0051
-- and derive BIN from destination account for exclusion rules.
with 
ebraclean1 as(
select *, SUBSTRING(destination_account FROM 10 FOR 9) as bin
from ebra_raw 
where reconciliation_date = :reconciliation_date and
message_type = '0210' and
destination_bank  = '0051' and 
response_code = '000' and 
reference = 'TEF ENT' 
),
-- EBRA normalization layer:
-- Standardize identifiers, accounts, amounts, RUT format and transaction date/time.
-- Exclude internal BINs not considered for reconciliation.
ebraclean2 as (
select 
ltrim(trace_id,'0') as id,
cast(amount as bigint) as amount,
ltrim(origin_account,'0') as origin_account,
ltrim(destination_account,'0') as destination_account,
format_chilean_rut(origin_rut) as origin_rut,
format_chilean_rut(destination_rut) as destination_rut,
'EBRA' as status,
SUBSTRING(timestamp  FROM 0 FOR 9) as transaction_date,
SUBSTRING(timestamp  FROM 9 FOR 4) as transaction_time,
reconciliation_date,
'INCOMING EFT' as reconciliation
from ebraclean1
where BIN not in ('000945732', '000913765', '000375654')
),
-- EBRA duplicate handling:
-- Assign row number by (id, amount) to allow one-to-one matching
-- when repeated transactions exist with the same key values.
ebraclean3 as (
select *,
ROW_NUMBER() OVER(partition by id,amount order by id,amount) as rn
from ebraclean2
),
-- EBRV base filtering:
-- Keep approved reversal/cancellation records corresponding to incoming EFT flow.
ebrvclean1 as(
select *, SUBSTRING(destination_account FROM 10 FOR 9) as bin
from ebrv_raw 
where reconciliation_date = :reconciliation_date and
message_type = '0430' and
destination_bank  = '0051' and 
response_code = '000' and 
reference = 'TEF ENT' 
),
-- EBRV normalization layer:
-- Apply the same standardization rules used for EBRA
-- to enable structural comparison between both sources.
ebrvclean2 as (
select 
ltrim(trace_id,'0') as id,
cast(amount as bigint) as amount,
ltrim(origin_account,'0') as origin_account,
ltrim(destination_account,'0') as destination_account,
format_chilean_rut(origin_rut) as origin_rut,
format_chilean_rut(destination_rut) as destination_rut,
'EBRV' as status,
SUBSTRING(timestamp  FROM 0 FOR 9) as transaction_date,
SUBSTRING(timestamp  FROM 9 FOR 4) as transaction_time,
reconciliation_date,
'INCOMING EFT' as reconciliation
from ebrvclean1
where BIN not in ('000945732', '000913765', '000375654')
),
-- EBRV duplicate handling:
-- Assign row number by (id, amount) to align duplicated records consistently.
ebrvclean3 as (
select *,
ROW_NUMBER() OVER(partition by id,amount order by id,amount) as rn
from ebrvclean2
),
-- SCTEF normalization layer:
-- Keep only relevant process codes for incoming EFT reconciliation
-- and standardize identifiers, amount and date/time fields.
sctefclean1 as (
select 
ltrim(rrn,'0') as id,
cast(txn_amt as bigint) as amount,
ltrim(from_acc,'0') as origin_account,
'SCTEF' as status,
SUBSTRING(purge_date from 7 for 4)||SUBSTRING(purge_date from 4 for 2)||SUBSTRING(purge_date from 0 for 3) as transaction_date,
SUBSTRING(purge_date from 12 for 2)||SUBSTRING(purge_date from 15 for 2)||SUBSTRING(purge_date from 18 for 2) as transaction_time,
reconciliation_date,
'INCOMING EFT' as reconciliation
from sctef_raw
where reconciliation_date = :reconciliation_date and
proc_code in ('222123','222234','222345')
),
-- SCTEF duplicate handling:
-- Assign row number by (id, amount) to support deterministic matching
-- against EBRA approved transactions.
sctefclean2 as (
select *,
ROW_NUMBER() OVER(partition by id,amount order by id,amount) as rn
from sctefclean1
),
-- Approved EBRA transactions:
-- Keep EBRA records that do not have a corresponding EBRV record.
-- Business meaning: these are considered valid / non-reversed transactions
-- to be reconciled against SCTEF.
approved_ebra_transactions as (
select 
a.id,
a.amount,
a.origin_account,
a.destination_account,
a.origin_rut,
a.destination_rut,
'APPROVED EBRA TOTAL' as status,
a.transaction_date,
a.transaction_time,
a.reconciliation_date,
a.rn,
'INCOMING EFT' as reconciliation
from ebraclean3 a 
full outer join ebrvclean3 b
on a.id = b.id and a.amount = b.amount and a.rn = b.rn
where a.status = 'EBRA' and b.status is null
),
-- Final case 1:
-- Approved EBRA transactions that do not exist in SCTEF.
-- These represent transactions present in EBRA but missing in SCTEF.
ebra_not_matched_sctef as (
select 
a.id,
a.amount,
a.origin_account,
a.destination_account,
a.origin_rut,
a.destination_rut,
a.transaction_date,
a.transaction_time,
a.reconciliation_date,
'EBRA NOT MATCHED SCTEF' as status,
'INCOMING EFT' as reconciliation
from approved_ebra_transactions a
left join sctefclean2 b
on a.id = b.id and a.amount = b.amount and a.rn = b.rn
where b.id is null 
),
-- Final case 2:
-- SCTEF transactions that do not have a corresponding approved EBRA record.
-- These represent transactions present in SCTEF but missing in EBRA.
sctef_not_matched_ebra as (
select 
b.id,
b.amount,
b.origin_account,
null::text as destination_account,
null::text as origin_rut,
null::text as destination_rut,
b.transaction_date,
b.transaction_time,
b.reconciliation_date,
'SCTEF NOT MATCHED EBRA' as status,
'INCOMING EFT' as reconciliation
from approved_ebra_transactions a
right join sctefclean2 b
on a.id = b.id and a.amount = b.amount and a.rn = b.rn
where a.id is null
),
-- Final case 2:
-- SCTEF transactions that do not have a corresponding approved EBRA record.
-- These represent transactions present in SCTEF but missing in EBRA.
sctef_matched_with_ebra as (
select 
a.id,
a.amount,
a.origin_account,
a.destination_account,
a.origin_rut,
a.destination_rut,
a.transaction_date,
a.transaction_time,
a.reconciliation_date,
'SCTEF MATCHED EBRA' as status,
'INCOMING EFT' as reconciliation
from approved_ebra_transactions a
inner join sctefclean2 b
-- Reconciliation key:
-- Match by transaction id + amount + row number.
-- Row number is required to disambiguate duplicated transactions
-- sharing the same id and amount.
on a.id = b.id and a.amount = b.amount and a.rn = b.rn
),
-- Summary output:
-- Aggregate record counts by reconciliation status
-- to provide a quick view of final reconciliation results.
-- Note:
-- This summary currently mixes final reconciliation statuses
-- with intermediate source-level statuses for validation purposes.
summary_output_base as (
select
    ord,
    reconciliation,
	reconciliation_date,
    status,
    count(*) as total,
    sum(amount) as amount
from (
    select reconciliation_date,status,reconciliation,amount,5 as ord from sctef_matched_with_ebra
    union all
    select reconciliation_date,status,reconciliation,amount,6 as ord from sctef_not_matched_ebra
    union all
    select reconciliation_date,status,reconciliation,amount,7 as ord from ebra_not_matched_sctef
    union all
    select reconciliation_date,status,reconciliation,amount,1 as ord from ebraclean3
    union all
    select reconciliation_date,status,reconciliation,amount,2 as ord from ebrvclean3
    union all
    select reconciliation_date,status,reconciliation,amount,3 as ord from approved_ebra_transactions
    union all
    select reconciliation_date,status,reconciliation,amount,4 as ord from sctefclean2
) t
group by status,reconciliation_date,reconciliation,ord
order by ord asc
),
summary_output as (
    select
        reconciliation,
        reconciliation_date,
        status,
        total,
        amount
    from summary_output_base
    order by ord asc
),
-- Detail output:
-- Consolidated detailed records for all final reconciliation cases
-- (matched and unmatched) with a unified structure.
detail_output as 
(
select
*
from (
    select * from sctef_matched_with_ebra
    union all
    select * from sctef_not_matched_ebra
    union all
    select * from ebra_not_matched_sctef
) t
),
insert_detail as (
INSERT INTO reconciliation_detail
SELECT *
FROM detail_output
RETURNING 1
),
insert_summary as (
INSERT INTO reconciliation_summary
SELECT *
FROM summary_output
RETURNING 1
)
SELECT
    (SELECT count(*) FROM insert_detail) as inserted_detail,
    (SELECT count(*) FROM insert_summary) as inserted_summary;
    

