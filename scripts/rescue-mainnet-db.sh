#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/rescue-mainnet-db.sh
# Gets the mainnet database out of Supabase's read-only mode after its disk filled up (2026-11-02): a failed
# re-valuation job left `swaps` with ~550k dead rows and the disk at 0 bytes free. Even TRUNCATE needs a few pages for
# its new empty files, so space is first given back by dropping the indexes of the two event tables (that allocates
# nothing). Steps, each safe to rerun:
#   0. pause the jobs that write (indexer, overview, backfill, prune, size guard);
#   1. save every Aethra event and the index definitions to local files, drop the secondary indexes;
#   2. truncate both event tables, put the Aethra events back, recreate the indexes;
#   3. fold the external pools' running sums into ext_base and move their floor to the last replayed block (their
#      reserves do not depend on the stored rows), clear their hourly USD volume (valued through look-alike stables);
#   4. resume the jobs, turn read-only mode off once the database is under 450 MB.
# External pools lose their stored swaps (new ones are indexed again); Aethra's own pools lose nothing.
# Needs ~/.config/aethra-fi/supabase.env (SUPABASE_DB_PASSWORD_MAINNET). Prints no secret.
set -euo pipefail
set -a; . "$HOME/.config/aethra-fi/supabase.env"; set +a
export PGPASSWORD="${RESCUE_PASSWORD:-$SUPABASE_DB_PASSWORD_MAINNET}" PGCONNECT_TIMEOUT=20
DB="${RESCUE_DB:-host=aws-0-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.nczunmovephgtyrmsgvt dbname=postgres sslmode=require}" # RESCUE_DB: rehearsal on local Supabase
DIR="$HOME/.config/aethra-fi/rescue-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIR"; chmod 700 "$DIR"
cd "$DIR"
# every session: write despite read-only mode, no statement timeout, give up on a lock after a minute
run() { { echo "set default_transaction_read_only = off; set statement_timeout = 0; set lock_timeout = '60s';"; cat; } | psql "$DB" -At -q -v ON_ERROR_STOP=1; }

echo "== before"
run <<<"select 'database ' || pg_size_pretty(pg_database_size(current_database())) || ', swaps ' || pg_size_pretty(pg_total_relation_size('public.swaps'));"

echo "== 0. pause writing jobs"
run <<<"select jobname || ' paused' from cron.job where jobname in ('aethra-indexer','aethra-overview','aethra-ext-backfill','aethra-prune','aethra-size-guard') and cron.unschedule(jobname);"

echo "== 1. save Aethra events and index definitions, drop secondary indexes"
# live definitions (made rerunnable), then the ones from migrations/20261022000003 in case a run already dropped them
run <<<"select replace(indexdef, 'CREATE INDEX ', 'CREATE INDEX IF NOT EXISTS ') || ';' from pg_indexes where schemaname = 'public' and tablename in ('swaps','liquidity_events') and indexname not like '%pkey' order by indexname;" | grep '^CREATE' >indexes.sql || true
echo "$(wc -l <indexes.sql) live index definitions saved"
cat >>indexes.sql <<'SQL'
create index if not exists swaps_feed_idx    on public.swaps (chain_id, block_number desc, log_index desc);
create index if not exists swaps_pool_ts_idx on public.swaps (chain_id, pool_id, ts desc);
create index if not exists swaps_ts_idx      on public.swaps (chain_id, ts desc);
create index if not exists swaps_sender_idx  on public.swaps (chain_id, sender);
create index if not exists liq_feed_idx      on public.liquidity_events (chain_id, block_number desc, log_index desc);
create index if not exists liq_pool_idx      on public.liquidity_events (chain_id, pool_id, block_number desc);
create index if not exists liq_token_id_idx  on public.liquidity_events (chain_id, token_id) where token_id is not null;
create index if not exists liq_recipient_idx on public.liquidity_events (chain_id, recipient);
create index if not exists liq_sender_idx    on public.liquidity_events (chain_id, sender);
SQL
run <<'SQL'
begin;
lock table public.swaps, public.liquidity_events in exclusive mode;
\copy (select s.* from public.swaps s join public.pools p on p.chain_id = s.chain_id and p.pool_id = s.pool_id and not p.external) to 'own_swaps.csv' with csv header
\copy (select l.* from public.liquidity_events l where l.pool_id is null or not exists (select 1 from public.pools p where p.chain_id = l.chain_id and p.pool_id = l.pool_id and p.external)) to 'own_liq.csv' with csv header
do $$
declare r record;
begin
  for r in select indexname from pg_indexes where schemaname = 'public' and tablename in ('swaps','liquidity_events') and indexname not like '%pkey' loop
    execute format('drop index public.%I', r.indexname);
  end loop;
end
$$;
commit;
SQL
echo "saved $(($(wc -l <own_swaps.csv) - 1)) swaps and $(($(wc -l <own_liq.csv) - 1)) liquidity events in $DIR"

echo "== 2. truncate, restore Aethra events, recreate indexes"
run <<'SQL'
truncate public.swaps, public.liquidity_events;
begin;
create temp table r_swaps (like public.swaps) on commit drop;
create temp table r_liq (like public.liquidity_events) on commit drop;
\copy r_swaps from 'own_swaps.csv' with csv header
\copy r_liq from 'own_liq.csv' with csv header
insert into public.swaps select * from r_swaps on conflict do nothing;
insert into public.liquidity_events select * from r_liq on conflict do nothing;
commit;
SQL
run <indexes.sql
run <<<"select 'restored ' || (select count(*) from public.swaps) || ' swaps, ' || (select count(*) from public.liquidity_events) || ' liquidity events, ' || (select count(*) from pg_indexes where schemaname = 'public' and tablename in ('swaps','liquidity_events')) || ' indexes';"

echo "== 3. external pools: fold running sums, clear hourly USD volume"
run <<'SQL'
update public.pools
   set ext_base0 = ext_base0 + ext_live0, ext_base1 = ext_base1 + ext_live1, ext_live0 = 0, ext_live1 = 0,
       ext_floor_block = greatest(ext_floor_block, coalesce(ext_synced_block, -1)), ext_sums_ready = true
 where external;
update public.pool_stats_hourly h
   set volume_usd = 0, fees_usd = 0
  from public.pools p
 where p.chain_id = h.chain_id and p.pool_id = h.pool_id and p.external and (h.volume_usd <> 0 or h.fees_usd <> 0);
vacuum (analyze) public.swaps, public.liquidity_events, public.pools, public.pool_stats_hourly;
SQL

echo "== 4. resume jobs, read-only mode"
run <<'SQL'
select cron.schedule('aethra-indexer', '* * * * *', 'select public.aethra_invoke_indexer()');
select cron.schedule('aethra-overview', '* * * * *', $job$set statement_timeout = '10min'; select public.aethra_refresh_overview()$job$);
select cron.schedule('aethra-ext-backfill', '* * * * *', 'select public.aethra_backfill_ext_sums(chain_id) from public.chains where enabled');
select cron.schedule('aethra-prune', '*/10 * * * *', $job$select public.aethra_prune_external(chain_id) from public.chains where enabled$job$);
select cron.schedule('aethra-size-guard', '41 * * * *', 'set statement_timeout = 0; select public.aethra_size_guard()');
do $$
declare v bigint := pg_database_size(current_database());
begin
  raise notice 'database %', pg_size_pretty(v);
  if v < 450 * 1024 * 1024 then
    begin
      alter database postgres set default_transaction_read_only = off;
      raise notice 'read-only mode off for new connections';
    exception when others then
      raise notice 'could not turn read-only off here (%): Supabase lifts it once usage is under the limit, or use the dashboard', sqlerrm;
    end;
  else
    raise notice 'still over 450 MB: read-only mode left on';
  end if;
end
$$;
SQL
echo "Done. Saved Aethra events and index definitions stay in $DIR (delete when no longer needed)."
