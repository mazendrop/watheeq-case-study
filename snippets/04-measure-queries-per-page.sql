-- How many queries, and how much database time, does one page cost?
-- (illustrative, written for this case study; needs the pg_stat_statements extension)
--
-- Recipe, on a test environment, one page at a time:
--   1. reset the statistics
--   2. load the page N times as one signed-in user (curl or a small script)
--   3. read the totals and divide by N

-- 1. Start clean.
select pg_stat_statements_reset();

-- 2. ... load the page N times ...

-- 3. Totals for everything the app ran meanwhile (filter out your own monitoring queries).
select sum(calls)                         as queries,
       round(sum(total_exec_time)::numeric, 1) as db_ms
from pg_stat_statements
where query not ilike '%pg_stat_statements%';

-- Which statements dominate? Repeated identical calls are the first thing to look for:
-- the same read three times in one request shows up as calls = 3 × N.
select calls,
       round(total_exec_time::numeric, 1)            as total_ms,
       round((total_exec_time / calls)::numeric, 2)  as ms_per_call,
       left(regexp_replace(query, '\s+', ' ', 'g'), 120) as statement
from pg_stat_statements
where query not ilike '%pg_stat_statements%'
order by total_exec_time desc
limit 15;

-- A common row-level security pattern to check while you are at it:
--   using (firm_id in (select my_firm_ids()))   -- evaluated once per statement
--   using (firm_id in (my_firm_ids()))          -- may be evaluated per row
-- Look at EXPLAIN (ANALYZE) as the app role: an "InitPlan" means the helper runs once.
