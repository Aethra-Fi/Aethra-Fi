#!/usr/bin/env bash
# Jalankan di: ROOT  ->  bash scripts/rescue-mainnet-db.sh
# Gets the mainnet database out of Supabase's read-only mode after its disk filled up (2026-11-02): a failed
# re-valuation job left `swaps` at 696 MB with ~550k dead rows and 1 GB of WAL, so even VACUUM FULL has no room.
# TRUNCATE gives the space back without needing any:
#   1. one transaction: lock the event tables, save every Aethra event to local CSV files, truncate both tables;
#   2. put the Aethra events back, fold the external pools' running sums into ext_base and move their floor to the
#      last replayed block (their reserves do not depend on the stored rows), clear the external pools' hourly USD
#      volume (it was valued through look-alike stables), vacuum;
#   3. turn read-only mode off once the database is under 450 MB.
# External pools lose their stored swaps (new ones are indexed from now on); Aethra's own pools lose nothing.
# Needs ~/.config/aethra-fi/supabase.env (SUPABASE_DB_PASSWORD_MAINNET). Prints no secret.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$HOME/.config/aethra-fi/supabase.env"; set +a
export PGPASSWORD="$SUPABASE_DB_PASSWORD_MAINNET" PGCONNECT_TIMEOUT=20
DB="host=aws-0-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.nczunmovephgtyrmsgvt dbname=postgres sslmode=require"
DIR="$HOME/.config/aethra-fi/rescue-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIR"; chmod 700 "$DIR"
cd "$DIR"

echo "== before"
psql "$DB" -At -c "select 'database ' || pg_size_pretty(pg_database_size(current_database())) || ', swaps ' || pg_size_pretty(pg_total_relation_size('public.swaps'))"

echo "== 1. save Aethra events, truncate"
psql "$DB" -At -v ON_ERROR_STOP=1 <<'SQL'
set default_transaction_read_only = off;
set statement_timeout = 0;
set lock_timeout = '60s';
begin;
lock table public.swaps, public.liquidity_events in exclusive mode;
\copy (select s.* from public.swaps s join public.pools p on p.chain_id = s.chain_id and p.pool_id = s.pool_id and not p.external) to 'own_swaps.csv' with csv header
\copy (select l.* from public.liquidity_events l where l.pool_id is null or not exists (select 1 from public.pools p where p.chain_id = l.chain_id and p.pool_id = l.pool_id and p.external)) to 'own_liq.csv' with csv header
truncate public.swaps, public.liquidity_events;
commit;
SQL
echo "saved: $(($(wc -l <own_swaps.csv) - 1)) swaps, $(($(wc -l <own_liq.csv) - 1)) liquidity events (in $DIR)"

echo "== 2. restore Aethra events, fold external sums"
psql "$DB" -At -v ON_ERROR_STOP=1 <<'SQL'
set default_transaction_read_only = off;
set statement_timeout = 0;
begin;
-- through temp tables: the indexer may have stored some of these rows again since step 1
create temp table r_swaps (like public.swaps) on commit drop;
create temp table r_liq (like public.liquidity_events) on commit drop;
\copy r_swaps from 'own_swaps.csv' with csv header
\copy r_liq from 'own_liq.csv' with csv header
insert into public.swaps select * from r_swaps on conflict do nothing;
insert into public.liquidity_events select * from r_liq on conflict do nothing;
update public.pools
   set ext_base0 = ext_base0 + ext_live0, ext_base1 = ext_base1 + ext_live1, ext_live0 = 0, ext_live1 = 0,
       ext_floor_block = greatest(ext_floor_block, coalesce(ext_synced_block, -1)), ext_sums_ready = true
 where external;
update public.pool_stats_hourly h
   set volume_usd = 0, fees_usd = 0
  from public.pools p
 where p.chain_id = h.chain_id and p.pool_id = h.pool_id and p.external and (h.volume_usd <> 0 or h.fees_usd <> 0);
select 'restored ' || (select count(*) from public.swaps) || ' swaps, ' || (select count(*) from public.liquidity_events) || ' liquidity events';
commit;
vacuum (analyze) public.swaps, public.liquidity_events, public.pools, public.pool_stats_hourly;
SQL

echo "== 3. read-only mode"
psql "$DB" -At -v ON_ERROR_STOP=1 <<'SQL'
set default_transaction_read_only = off;
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
echo "Done. Local copies of the saved Aethra events stay in $DIR (delete when no longer needed)."
