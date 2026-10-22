-- Aethra Fi indexer: schedule. Every minute pg_cron calls the `indexer` Edge Function through pg_net.
-- The project URL and service key are read from Supabase Vault, so no secret is stored in SQL:
--   select vault.create_secret('https://<ref>.supabase.co', 'project_url');
--   select vault.create_secret('<service role key>', 'service_role_key');
-- When either secret is missing the job logs a notice and does nothing.

create or replace function public.aethra_invoke_indexer(p_chain integer default null)
returns bigint
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url text;
  v_key text;
  v_request_id bigint;
begin
  begin
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_key from vault.decrypted_secrets where name = 'service_role_key' limit 1;
  exception when others then
    raise notice 'aethra indexer: vault not readable (%), skipping', sqlerrm;
    return null;
  end;

  if v_url is null or v_key is null then
    raise notice 'aethra indexer: vault secrets project_url / service_role_key missing, skipping';
    return null;
  end if;

  select net.http_post(
    url := rtrim(v_url, '/') || '/functions/v1/indexer' || case when p_chain is null then '' else '?chain=' || p_chain end,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body := jsonb_build_object('source', 'pg_cron'),
    timeout_milliseconds := 55000
  ) into v_request_id;

  return v_request_id;
end;
$$;

revoke all on function public.aethra_invoke_indexer(integer) from public, anon, authenticated;
grant execute on function public.aethra_invoke_indexer(integer) to service_role;

-- (re)create the job idempotently
do $$
begin
  if exists (select 1 from cron.job where jobname = 'aethra-indexer') then
    perform cron.unschedule('aethra-indexer');
  end if;
  perform cron.schedule('aethra-indexer', '* * * * *', 'select public.aethra_invoke_indexer()');
end
$$;

-- keep pg_net's response log and cron's run history small
do $$
begin
  if exists (select 1 from cron.job where jobname = 'aethra-housekeeping') then
    perform cron.unschedule('aethra-housekeeping');
  end if;
  perform cron.schedule(
    'aethra-housekeeping',
    '17 * * * *',
    $job$
      delete from cron.job_run_details where end_time < now() - interval '2 days';
    $job$
  );
end
$$;
