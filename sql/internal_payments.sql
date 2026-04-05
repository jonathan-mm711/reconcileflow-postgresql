-- Internal Payments reconciliation flow
-- Logic:
-- 1. Clean and standardize SCTEF and RDAP 1178 raw data
-- 2. Derive reconciliation identifiers using source-specific business rules
-- 3. Align duplicated records using row_number()
-- 4. Reconcile SCTEF transactions against RDAP 1178
-- 5. Generate matched and unmatched outputs for reporting
-- Business assumptions:
-- 1. SCTEF contains internal payment transaction records.
-- 2. RDAP 1178 is the counterpart source used for reconciliation.
-- 3. Matching key = (id, amount, rn).
-- 4. Transaction id requires source-specific normalization before reconciliation.
-- 5. row_number() is used to preserve one-to-one matching when duplicates exist.
with 
-- SCTEF normalization layer:
-- Keep only internal payment transactions based on process codes.
-- Standardize identifiers, amounts and transaction timestamps.
-- Derive reconciliation id from RRN using the business-specific substring rule.
sctefclean1 as (
select 
ltrim(substring(rrn from 5 for 8),'0') as id,
cast(txn_amt as bigint) as amount,
ltrim(from_acc,'0') as origin_account,
'SCTEF' as status,
SUBSTRING(purge_date from 7 for 4)||SUBSTRING(purge_date from 4 for 2)||SUBSTRING(purge_date from 0 for 3) as transaction_date,
SUBSTRING(purge_date from 12 for 2)||SUBSTRING(purge_date from 15 for 2)||SUBSTRING(purge_date from 18 for 2) as transaction_time,
reconciliation_date,
'INTERNAL PAYMENTS' as reconciliation
from sctef_raw
where reconciliation_date = :reconciliation_date and
proc_code in ('333123','333234','333345')
),
-- SCTEF duplicate handling:
-- Assign row number by (id, amount) to support deterministic one-to-one matching
-- when repeated transactions exist with the same reconciliation keys.
sctefclean2 as (
select *,
ROW_NUMBER() OVER(partition by id,amount order by id,amount) as rn
from sctefclean1
),
-- RDAP 1178 normalization layer:
-- Standardize identifiers, amounts and transaction date/time fields
-- and align the output structure with SCTEF reconciliation detail.
-- Non-applicable fields are filled with NULL to preserve a unified schema.
rdap1178clean1 as (
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
'RDAP 1178' as status,
'INTERNAL PAYMENTS' as reconciliation
from rdap_1178_raw
where reconciliation_date = :reconciliation_date
),
-- RDAP 1178 duplicate handling:
-- Assign row number by (id, amount) to align duplicated records consistently
-- during reconciliation against SCTEF.
rdap1178clean2 as (
select *,
ROW_NUMBER() OVER(partition by id,amount order by id,amount) as rn
from rdap1178clean1
),
-- Final case 1:
-- SCTEF internal payment transactions that do not exist in RDAP 1178.
-- These represent records present in SCTEF but missing in RDAP 1178.
sctef_not_matched_rdap_1178 as (
select 
a.id,
a.amount,
a.origin_account,
null::text as destination_account,
null::text as origin_rut,
null::text as destination_rut,
a.transaction_date,
a.transaction_time,
a.reconciliation_date,
'SCTEF NOT MATCHED RDAP 1178' as status,
'INTERNAL PAYMENTS' as reconciliation
from sctefclean2 a
left join rdap1178clean2 b
on a.id = b.id and a.amount = b.amount and a.rn = b.rn
where b.id is null 
),
-- Final case 2:
-- RDAP 1178 transactions that do not have a corresponding SCTEF record.
-- These represent records present in RDAP 1178 but missing in SCTEF.
rdap_1178_not_matched_sctef as (
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
'RDAP 1178 NOT MATCHED SCTEF' as status,
'INTERNAL PAYMENTS' as reconciliation
from sctefclean2 a
right join rdap1178clean2 b
on a.id = b.id and a.amount = b.amount and a.rn = b.rn
where a.id is null
),
-- Final case 3:
-- Transactions successfully matched between SCTEF and RDAP 1178
-- using (id, amount, rn) as reconciliation keys.
rdap_1178_matched_with_sctef as (
select 
a.id,
a.amount,
a.origin_account,
null::text as destination_account,
b.origin_rut,
null::text as destination_rut,
a.transaction_date,
a.transaction_time,
a.reconciliation_date,
'RDAP 1178 MATCHED SCTEF' as status,
'INTERNAL PAYMENTS' as reconciliation
from sctefclean2 a
inner join rdap1178clean2 b
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
    ord,
    reconciliation,
	reconciliation_date,
    status,
    count(*) as total,
    sum(amount) as amount
from (
    select reconciliation_date,status,reconciliation,amount,3 as ord from rdap_1178_matched_with_sctef
    union all
    select reconciliation_date,status,reconciliation,amount,4 as ord from rdap_1178_not_matched_sctef
    union all
    select reconciliation_date,status,reconciliation,amount,5 as ord from sctef_not_matched_rdap_1178
    union all
    select reconciliation_date,status,reconciliation,amount,1 as ord from sctefclean2
    union all
    select reconciliation_date,status,reconciliation,amount,2 as ord from rdap1178clean2
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
    select * from rdap_1178_matched_with_sctef
    union all
    select * from rdap_1178_not_matched_sctef
    union all
    select * from sctef_not_matched_rdap_1178
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


