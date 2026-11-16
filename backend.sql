-- Run in the Supabase SQL Editor after creating a new project.
-- Collects only each completed voter's final 5 songs (no personal identifying data).
create table if not exists public.svt_song_vote_final_ballots (
  ballot_id uuid primary key,
  title_song text not null,
  hiphop_song text not null,
  vocal_song text not null,
  performance_song text not null,
  japan_song text not null,
  created_at timestamptz not null default now(),
  constraint svt_vote_nonempty check (
    length(trim(title_song)) > 0 and length(trim(hiphop_song)) > 0 and
    length(trim(vocal_song)) > 0 and length(trim(performance_song)) > 0 and
    length(trim(japan_song)) > 0
  )
);

-- Anonymous website users cannot read/write the raw ballot table.
revoke all on public.svt_song_vote_final_ballots from public, anon, authenticated;
alter table public.svt_song_vote_final_ballots enable row level security;

-- Atomic, idempotent submission, accepts final picks only.
create or replace function public.submit_song_vote(ballot_id uuid, picks jsonb)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare v_count integer;
begin
  if ballot_id is null or jsonb_typeof(picks) <> 'object' then
    raise exception 'Invalid ballot';
  end if;
  if (select count(*) from jsonb_object_keys(picks)) <> 5 or
     not (picks ?& array['titles','hiphop','vocal','performance','japan']) or
     exists (select 1 from jsonb_each(picks) e where jsonb_typeof(e.value) <> 'string') then
    raise exception 'Exactly five song strings are required';
  end if;
  insert into public.svt_song_vote_final_ballots
    (ballot_id,title_song,hiphop_song,vocal_song,performance_song,japan_song)
  values (ballot_id,picks->>'titles',picks->>'hiphop',picks->>'vocal',picks->>'performance',picks->>'japan')
  on conflict (ballot_id) do nothing;
  get diagnostics v_count = row_count;
  return v_count > 0;
end;
$$;

-- Only the top song per category is exposed, not individual ballots or vote counts.
-- If two songs tie, alphabetical order is used to choose one deterministically.
create or replace function public.song_vote_leaders()
returns table(category text, song text)
language sql stable security definer set search_path = public, pg_temp as $$
  with votes as (
    select unnest(array['titles','hiphop','vocal','performance','japan']) category,
           unnest(array[title_song,hiphop_song,vocal_song,performance_song,japan_song]) song
    from public.svt_song_vote_final_ballots
  ), ranked as (
    select v.category,v.song,
           row_number() over(partition by v.category order by count(*) desc,v.song asc) rank
    from votes v group by v.category,v.song
  )
  select r.category,r.song from ranked r where r.rank=1;
$$;
revoke all on function public.submit_song_vote(uuid,jsonb) from public;
revoke all on function public.song_vote_leaders() from public;
grant execute on function public.submit_song_vote(uuid,jsonb) to anon,authenticated;
grant execute on function public.song_vote_leaders() to anon,authenticated;
