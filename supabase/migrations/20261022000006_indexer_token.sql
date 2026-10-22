-- The cron caller authenticates with a dedicated token (Vault secret `indexer_token`, function secret
-- INDEXER_TOKEN) instead of the service role key, whose format differs between projects (legacy JWT vs
-- sb_secret_). Falls back to `service_role_key` so existing setups keep working.
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
    select decrypted_secret into v_key from vault.decrypted_secrets where name = 'indexer_token' limit 1;
    if v_key is null then
      select decrypted_secret into v_key from vault.decrypted_secrets where name = 'service_role_key' limit 1;
    end if;
  exception when others then
    raise notice 'aethra indexer: vault not readable (%), skipping', sqlerrm;
    return null;
  end;

  if v_url is null or v_key is null then
    raise notice 'aethra indexer: vault secrets project_url / indexer_token missing, skipping';
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
