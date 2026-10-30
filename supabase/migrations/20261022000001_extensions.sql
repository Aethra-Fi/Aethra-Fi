-- Aethra Fi indexer: extensions.
-- pg_cron schedules the indexer, pg_net lets Postgres call the Edge Function over HTTP.
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

grant usage on schema cron to postgres;
