-- Report syncing that scales to large sends (a Kilele send is ~70 batches).
-- Incremental reads continue until the provider says a batch is complete.
-- Full re-reads (to catch reports that land behind the cursor) back off as
-- the batch ages: every 10 min in the first hour, hourly for a day, then
-- every 6 hours until 3 days after dispatch.

create or replace function public.svc_chunks_to_sync(p_limit int default 50)
returns table (send_id uuid, chunk_no int, provider_batch_id text, events_cursor text, full_resync boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.assert_service_role();
  return query
  with candidates as (
    select c.*,
      (c.full_resync_at is null or c.full_resync_at < now() - case
         when c.dispatched_at > now() - interval '1 hour' then interval '10 minutes'
         when c.dispatched_at > now() - interval '1 day' then interval '1 hour'
         else interval '6 hours' end) as full_due
    from public.send_chunks c
    where c.provider_batch_id is not null
      and c.dispatched_at > now() - interval '3 days'
  )
  select c.send_id, c.chunk_no, c.provider_batch_id, c.events_cursor, c.full_due
  from candidates c
  where not c.events_complete or c.full_due
  order by c.events_synced_at nulls first
  limit least(greatest(coalesce(p_limit, 50), 1), 500);
end
$$;
