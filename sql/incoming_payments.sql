-- Business assumptions:
-- 1. EBRA contains original incoming payment transactions.
-- 2. EBRV contains reversal/cancellation counterparts.
-- 3. EBRA transactions without EBRV are treated as approved transactions.
-- 4. RDAP 1172 is the external source used for reconciliation.
-- 5. Matching key = (id, amount, rn).
-- 6. TRACE_ID requires a business-specific transformation to derive reconciliation id.
-- Incoming Payments reconciliation flow
-- Logic:
-- 1. Clean and standardize EBRA, EBRV and RDAP 1172 raw data
-- 2. Keep only approved incoming payment transactions for destination bank 0051
-- 3. Restrict EBRA / EBRV scope to payment-related BINs
-- 4. Remove reversed/cancelled transactions through EBRA vs EBRV comparison
-- 5. Reconcile approved EBRA transactions against RDAP 1172
-- 6. Generate matched and unmatched outputs for reporting
with 
-- EBRA base filtering:
-- Keep only approved incoming payment transactions
-- for destination bank 0051 and derive BIN from destination account
-- to isolate the payment-related scope.
ebraclean1 as(
select *, SUBSTRING(destination_account FROM 10 FOR 9) as bin
from ebra_raw 
where reconciliation_date = :reconciliation_date and
message_type = '0210' and
destination_bank  = '0051' and 
response_code = '000' and
reference = 'PAGO'
),
-- EBRA normalization layer:
-- Standardize identifiers, accounts, amounts and RUT format.
-- For incoming payments, derive the reconciliation id from TRACE_ID
-- using the business-specific substring rule.
-- Keep only records belonging to the approved payment BIN list.
ebraclean2 as (
select 
ltrim(substring(trace_id from 5 for 8),'0') as id,
cast(amount as bigint) as amount,
ltrim(origin_account,'0') as origin_account,
ltrim(destination_account,'0') as destination_account,
format_chilean_rut(origin_rut) as origin_rut,
format_chilean_rut(destination_rut) as destination_rut,
'EBRA' as status,
SUBSTRING(timestamp  FROM 0 FOR 9) as transaction_date,
SUBSTRING(timestamp  FROM 9 FOR 4) as transaction_time,
reconciliation_date,
'INCOMING PAYMENTS' as reconciliation
from ebraclean1
where BIN in ('000945732', '000913765', '000375654')
),
-- EBRA duplicate handling:
-- Assign row number by (id, amount) to support deterministic one-to-one matching
-- when duplicated transactions exist with the same reconciliation keys.
ebraclean3 as (
select *,
ROW_NUMBER() OVER(partition by id,amount order by id,amount) as rn
from ebraclean2
),
-- EBRV base filtering:
-- Extract reversal/cancellation records corresponding to the incoming payments flow
-- for destination bank 0051 and payment-related reference = 'PAGO'.
ebrvclean1 as(
select *, SUBSTRING(destination_account FROM 10 FOR 9) as bin
from ebrv_raw 
where reconciliation_date = :reconciliation_date and
message_type = '0430' and
destination_bank  = '0051' and 
response_code = '000' and
reference = 'PAGO'
),
-- EBRV normalization layer:
-- Apply the same structural standardization used for EBRA
-- so reversal records can be compared consistently against original transactions.
ebrvclean2 as (
select 
ltrim(substring(trace_id from 5 for 8),'0') as id,
cast(amount as bigint) as amount,
ltrim(origin_account,'0') as origin_account,
ltrim(destination_account,'0') as destination_account,
format_chilean_rut(origin_rut) as origin_rut,
format_chilean_rut(destination_rut) as destination_rut,
'EBRV' as status,
SUBSTRING(timestamp  FROM 0 FOR 9) as transaction_date,
SUBSTRING(timestamp  FROM 9 FOR 4) as transaction_time,
reconciliation_date,
'INCOMING PAYMENTS' as reconciliation
from ebrvclean1
where BIN in ('000945732', '000913765', '000375654')
),
-- EBRV duplicate handling:
-- Assign row number by (id, amount) to align duplicated reversal records consistently.
ebrvclean3 as (
select *,
ROW_NUMBER() OVER(partition by id,amount order by id,amount) as rn
from ebrvclean2
),
-- RDAP 1172 normalization layer:
-- Standardize identifiers and amounts from RDAP 1172 source
-- and align its structure with EBRA detail output for reconciliation purposes.
-- Non-applicable fields are filled with NULL to preserve a unified schema.
rdap1172clean1 as (
select
ltrim(sequence,'0') as id,
cast(amount as bigint) as amount,
null::text as origin_account,
null::text as destination_account,
format_chilean_rut(rut) as origin_rut,
null::text as destination_account,
transaction_date,
transaction_time,
reconciliation_date,
'RDAP 1172' as status,
'INCOMING PAYMENTS' as reconciliation
from rdap_1172_raw
where reconciliation_date = :reconciliation_date 
),
-- RDAP 1172 duplicate handling:
-- Assign row number by (id, amount) to support deterministic matching
-- against approved EBRA transactions.
rdap1172clean2 as (
select *,
ROW_NUMBER() OVER(partition by id,amount order by id,amount) as rn
from rdap1172clean1
),
-- Approved EBRA transactions:
-- Keep EBRA records that do not have a corresponding EBRV record.
-- Business meaning: these are considered valid, non-reversed incoming payment transactions
-- to be reconciled against RDAP 1172.
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
'INCOMING PAYMENTS' as reconciliation
from ebraclean3 a 
full outer join ebrvclean3 b
on a.id = b.id and a.amount = b.amount and a.rn = b.rn
where a.status = 'EBRA' and b.status is null
),
-- Final case 1:
-- Approved EBRA incoming payment transactions that do not exist in RDAP 1172.
-- These represent records present in EBRA but missing in RDAP 1172.
ebra_not_matched_rdap_1172 as (
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
'EBRA NOT MATCHED RDAP 1172' as status,
'INCOMING PAYMENTS' as reconciliation
from approved_ebra_transactions a
left join rdap1172clean2 b
on a.id = b.id and a.amount = b.amount and a.rn = b.rn
where b.id is null 
),
-- Final case 3:
-- Transactions successfully matched between approved EBRA and RDAP 1172
-- using (id, amount, rn) as reconciliation keys.
rdap_1172_not_matched_ebra as (
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
'RDAP 1172 NOT MATCHED EBRA' as status,
'INCOMING PAYMENTS' as reconciliation
from approved_ebra_transactions a
right join rdap1172clean2 b
on a.id = b.id and a.amount = b.amount and a.rn = b.rn
where a.id is null
),
-- Reconciliation key:
-- Match by transaction id + amount + row number.
-- Row number is required to disambiguate duplicated transactions
-- sharing the same id and amount.
rdap_1172_matched_with_ebra as (
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
'RDAP 1172 MATCHED EBRA' as status,
'INCOMING PAYMENTS' as reconciliation
from approved_ebra_transactions a
inner join rdap1172clean2 b
-- Reconciliation key:
-- Match by transaction id + amount + row number.
-- Row number is required to disambiguate duplicated transactions
-- sharing the same id and amount.
on a.id = b.id and a.amount = b.amount and a.rn = b.rn
),
-- Summary output:
-- Aggregate transaction counts by reconciliation status.
-- Includes both final reconciliation results and source-level control totals
-- to support validation and monitoring.
summary_output_base as (
select
    reconciliation,
	reconciliation_date,
    status,
    count(*) as total,
    sum(amount) as amount,
    ord
from (
    select reconciliation_date,status,reconciliation,amount,7 as ord from ebra_not_matched_rdap_1172
    union all
    select reconciliation_date,status,reconciliation,amount,6 as ord from rdap_1172_not_matched_ebra
    union all
    select reconciliation_date,status,reconciliation,amount,5 as ord from rdap_1172_matched_with_ebra
    union all
    select reconciliation_date,status,reconciliation,amount,3 as ord from approved_ebra_transactions
    union all
    select reconciliation_date,status,reconciliation,amount,4 as ord from rdap1172clean2
    union all
    select reconciliation_date,status,reconciliation,amount,1 as ord from ebraclean3
    union all
    select reconciliation_date,status,reconciliation,amount,2 as ord from ebrvclean3
) t
group by status,reconciliation_date,reconciliation,ord
order by total desc
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
-- Consolidated dataset of all final reconciliation cases
-- including matched and unmatched transactions with standardized structure
detail_output as 
(
select
*
from (
    select * from rdap_1172_matched_with_ebra
    union all
    select * from rdap_1172_not_matched_ebra
    union all
    select * from ebra_not_matched_rdap_1172
) t
),
-- Insert detail results into reporting table
insert_detail as (
INSERT INTO reconciliation_detail
SELECT *
FROM detail_output
RETURNING 1
),
-- Insert summary results into reporting table
insert_summary as (
INSERT INTO reconciliation_summary
SELECT *
FROM summary_output
RETURNING 1
)
SELECT
    (SELECT count(*) FROM insert_detail) as inserted_detail,
    (SELECT count(*) FROM insert_summary) as inserted_summary;


