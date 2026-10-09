-- SchulUmfrage: Supabase schema
-- Apply this SQL in the Supabase SQL editor for project mqtcwiiawmuxrpkjfrfc.
-- The HTML clients use the publishable key only; never put a service_role key into GitHub.

create extension if not exists pgcrypto;

create table if not exists public.surveys (id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id) on delete cascade, name text not null, slides jsonb not null default '[]'::jsonb, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.sessions (id uuid primary key default gen_random_uuid(), survey_id uuid not null references public.surveys(id) on delete cascade, owner_id uuid not null references auth.users(id) on delete cascade, title text not null, survey_snapshot jsonb not null default '[]'::jsonb, status text not null default 'lobby' check (status in ('lobby','running','ended')), current_slide integer not null default 0, join_code text not null unique, created_at timestamptz not null default now(), started_at timestamptz, updated_at timestamptz not null default now());
create table if not exists public.participants (id uuid primary key default gen_random_uuid(), session_id uuid not null references public.sessions(id) on delete cascade, name text not null, joined_at timestamptz not null default now(), last_seen_at timestamptz not null default now());
create table if not exists public.responses (id uuid primary key default gen_random_uuid(), session_id uuid not null references public.sessions(id) on delete cascade, participant_id uuid not null references public.participants(id) on delete cascade, slide_index integer not null, answer jsonb not null, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(session_id, participant_id, slide_index));
create index if not exists surveys_owner_id_idx on public.surveys(owner_id); create index if not exists sessions_owner_id_idx on public.sessions(owner_id); create index if not exists sessions_survey_id_idx on public.sessions(survey_id); create index if not exists participants_session_id_idx on public.participants(session_id); create index if not exists responses_session_id_idx on public.responses(session_id);
create unique index if not exists participants_session_normalized_name_uidx on public.participants(session_id, lower(btrim(name)));
alter table public.surveys enable row level security; alter table public.sessions enable row level security; alter table public.participants enable row level security; alter table public.responses enable row level security;

-- Secure student access via narrow RPCs; never expose sessions directly to anon.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.join_code_rate_limits (ip_hash text primary key, window_start timestamptz not null default now(), attempts integer not null default 0);
revoke all on table private.join_code_rate_limits from public, anon, authenticated;
drop function if exists public.join_session_by_code(text,text);
create or replace function public.join_session_by_code(p_join_code text,p_name text,p_participant_id uuid)
returns table (id uuid,title text,survey_snapshot jsonb,status text,current_slide integer,join_code text,participant_id uuid)
language plpgsql security definer set search_path = ''
as $function$
declare
 v_headers jsonb; v_ip text; v_ip_hash text; v_attempts integer;
 v_code text; v_name text; v_session_id uuid; v_participant_id uuid;
 v_existing_participant_id uuid; v_existing_name text;
begin
 v_code:=upper(trim(coalesce(p_join_code,'')));
 v_name:=trim(coalesce(p_name,''));
 if v_code !~ '^[A-Z0-9]{5}$' or length(v_name)<1 or length(v_name)>40 then
   raise exception using errcode='P0001', message='INVALID_JOIN_INPUT';
 end if;

 select s.id into v_session_id from public.sessions s
 where s.join_code=v_code and s.status in ('lobby','running') limit 1;

 if v_session_id is null then
   v_headers:=coalesce(nullif(current_setting('request.headers',true),'')::jsonb,'{}'::jsonb);
   v_ip:=coalesce(nullif(v_headers->>'cf-connecting-ip',''),nullif(v_headers->>'x-real-ip',''),'unknown');
   v_ip_hash:=md5(v_ip);
   insert into private.join_code_rate_limits as r(ip_hash,window_start,attempts) values(v_ip_hash,now(),1)
   on conflict(ip_hash) do update
     set window_start=case when r.window_start<now()-interval '10 minutes' then now() else r.window_start end,
         attempts=case when r.window_start<now()-interval '10 minutes' then 1 else r.attempts+1 end
   returning attempts into v_attempts;
   if v_attempts>12 then return; end if;
   raise exception using errcode='P0001', message='SESSION_NOT_FOUND';
 end if;

 -- A browser that already joined this session must keep the same name.
 if p_participant_id is not null then
   select p.name into v_existing_name from public.participants p
   where p.id=p_participant_id and p.session_id=v_session_id;

   if found then
     if lower(btrim(v_existing_name))<>lower(v_name) then
       raise exception using errcode='P0001', message='PARTICIPANT_NAME_MISMATCH';
     end if;
     update public.participants p set last_seen_at=now()
     where p.id=p_participant_id and p.session_id=v_session_id;

     return query select s.id,s.title,s.survey_snapshot,s.status,s.current_slide,s.join_code,p_participant_id
     from public.sessions s where s.id=v_session_id and s.status in ('lobby','running');
     return;
   end if;
 end if;

 -- Limit requests that try to create new identities.
 v_headers:=coalesce(nullif(current_setting('request.headers',true),'')::jsonb,'{}'::jsonb);
 v_ip:=coalesce(nullif(v_headers->>'cf-connecting-ip',''),nullif(v_headers->>'x-real-ip',''),'unknown');
 v_ip_hash:=md5(v_ip);
 insert into private.join_code_rate_limits as r(ip_hash,window_start,attempts) values(v_ip_hash,now(),1)
 on conflict(ip_hash) do update
   set window_start=case when r.window_start<now()-interval '10 minutes' then now() else r.window_start end,
       attempts=case when r.window_start<now()-interval '10 minutes' then 1 else r.attempts+1 end
 returning attempts into v_attempts;
 if v_attempts>12 then
   raise exception using errcode='P0001', message='JOIN_RATE_LIMITED';
 end if;

 select p.id into v_existing_participant_id from public.participants p
 where p.session_id=v_session_id and lower(btrim(p.name))=lower(v_name) limit 1;
 if v_existing_participant_id is not null then
   raise exception using errcode='P0001', message='PARTICIPANT_NAME_TAKEN';
 end if;

 begin
   insert into public.participants as inserted_participant(session_id,name,last_seen_at)
   values(v_session_id,v_name,now())
   returning inserted_participant.id into v_participant_id;
 exception when unique_violation then
   raise exception using errcode='P0001', message='PARTICIPANT_NAME_TAKEN';
 end;

 return query select s.id,s.title,s.survey_snapshot,s.status,s.current_slide,s.join_code,v_participant_id
 from public.sessions s where s.id=v_session_id and s.status in ('lobby','running');
end;
$function$;
drop function if exists public.get_participant_session(uuid,uuid);
create function public.get_participant_session(p_session_id uuid,p_participant_id uuid)
returns table(id uuid,title text,survey_snapshot jsonb,status text,current_slide integer,join_code text,updated_at timestamptz)
language sql security definer set search_path=''
as $function$
 select s.id,s.title,s.survey_snapshot,s.status,s.current_slide,s.join_code,s.updated_at from public.sessions s join public.participants p on p.session_id=s.id where s.id=p_session_id and p.id=p_participant_id;
$function$;

create or replace function public.get_participant_response(p_session_id uuid,p_participant_id uuid,p_slide_index integer)
returns table(answer jsonb,updated_at timestamptz)
language sql stable security definer set search_path=''
as $function$
 select r.answer,r.updated_at
 from public.responses r
 join public.participants p on p.id=r.participant_id and p.session_id=r.session_id
 join public.sessions s on s.id=r.session_id
 where s.id=p_session_id and p.id=p_participant_id
   and r.slide_index=p_slide_index and s.status in ('lobby','running')
 limit 1;
$function$;
create or replace function private.can_submit_response(p_session_id uuid,p_participant_id uuid)
returns boolean language sql stable security definer set search_path=''
as $function$
 select exists(select 1 from public.sessions s join public.participants p on p.session_id=s.id where s.id=p_session_id and p.id=p_participant_id and s.status='running');
$function$;
revoke all on function public.join_session_by_code(text,text,uuid) from public,anon,authenticated;
revoke all on function public.get_participant_session(uuid,uuid) from public,anon,authenticated;
revoke all on function public.get_participant_response(uuid,uuid,integer) from public,anon,authenticated;
revoke all on function private.can_submit_response(uuid,uuid) from public,anon,authenticated;
grant execute on function public.join_session_by_code(text,text,uuid) to anon;
grant execute on function public.get_participant_session(uuid,uuid) to anon;
grant execute on function public.get_participant_response(uuid,uuid,integer) to anon;
grant usage on schema private to anon,authenticated;
grant execute on function private.can_submit_response(uuid,uuid) to anon;
drop policy if exists surveys_select on public.surveys; create policy surveys_select on public.surveys for select to authenticated using ((select auth.uid())=owner_id);
drop policy if exists surveys_insert on public.surveys; create policy surveys_insert on public.surveys for insert to authenticated with check ((select auth.uid())=owner_id);
drop policy if exists surveys_update on public.surveys; create policy surveys_update on public.surveys for update to authenticated using ((select auth.uid())=owner_id) with check ((select auth.uid())=owner_id);
drop policy if exists surveys_delete on public.surveys; create policy surveys_delete on public.surveys for delete to authenticated using ((select auth.uid())=owner_id);
drop policy if exists sessions_teacher_select on public.sessions; create policy sessions_teacher_select on public.sessions for select to authenticated using ((select auth.uid())=owner_id);
drop policy if exists sessions_teacher_insert on public.sessions; create policy sessions_teacher_insert on public.sessions for insert to authenticated with check ((select auth.uid())=owner_id);
drop policy if exists sessions_teacher_update on public.sessions; create policy sessions_teacher_update on public.sessions for update to authenticated using ((select auth.uid())=owner_id) with check ((select auth.uid())=owner_id);
drop policy if exists sessions_anon_select on public.sessions;
drop policy if exists participants_teacher_select on public.participants; create policy participants_teacher_select on public.participants for select to authenticated using (exists(select 1 from public.sessions s where s.id=session_id and s.owner_id=(select auth.uid())));
drop policy if exists participants_anon_insert on public.participants;
drop policy if exists responses_teacher_select on public.responses; create policy responses_teacher_select on public.responses for select to authenticated using (exists(select 1 from public.sessions s where s.id=session_id and s.owner_id=(select auth.uid())));
drop policy if exists responses_teacher_insert on public.responses; create policy responses_teacher_insert on public.responses for insert to authenticated with check (exists(select 1 from public.sessions s where s.id=session_id and s.owner_id=(select auth.uid())));
drop policy if exists responses_anon_insert on public.responses; create policy responses_anon_insert on public.responses for insert to anon with check (private.can_submit_response(session_id, participant_id));
drop policy if exists responses_teacher_delete on public.responses; create policy responses_teacher_delete on public.responses for delete to authenticated using (exists(select 1 from public.sessions s where s.id=session_id and s.owner_id=(select auth.uid())));

create or replace function public.set_updated_at() returns trigger language plpgsql set search_path = '' as $$ begin new.updated_at=pg_catalog.now(); return new; end; $$;
drop trigger if exists surveys_updated_at on public.surveys; create trigger surveys_updated_at before update on public.surveys for each row execute function public.set_updated_at();
drop trigger if exists sessions_updated_at on public.sessions; create trigger sessions_updated_at before update on public.sessions for each row execute function public.set_updated_at();
drop trigger if exists responses_updated_at on public.responses; create trigger responses_updated_at before update on public.responses for each row execute function public.set_updated_at();

-- Media storage used by the survey editor.
-- Public download is intentional so students can display media using the publishable key.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('survey-media','survey-media',true,26214400,array['image/*','video/*','audio/*'])
on conflict (id) do update
set public=true,file_size_limit=26214400,allowed_mime_types=array['image/*','video/*','audio/*'];

drop policy if exists "survey_media_authenticated_insert" on storage.objects;
create policy "survey_media_authenticated_insert"
on storage.objects for insert
to authenticated
with check (
  bucket_id='survey-media'
  and (storage.foldername(name))[1]=(select auth.uid()::text)
);

drop policy if exists "survey_media_authenticated_delete" on storage.objects;
create policy "survey_media_authenticated_delete"
on storage.objects for delete
to authenticated
using (
  bucket_id='survey-media'
  and (storage.foldername(name))[1]=(select auth.uid()::text)
);

-- Teacher dashboard session management.
-- These RPCs operate only on sessions owned by the authenticated teacher.
-- Deleting a session cascades to its participants and responses; surveys remain.
create or replace function public.end_all_owned_sessions()
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_count bigint;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  update public.sessions
  set status = 'ended'
  where owner_id = auth.uid()
    and status in ('lobby', 'running');

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

create or replace function public.delete_all_owned_sessions()
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_count bigint;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  delete from public.sessions
  where owner_id = auth.uid();

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

revoke all on function public.end_all_owned_sessions() from public, anon, authenticated;
revoke all on function public.delete_all_owned_sessions() from public, anon, authenticated;
grant execute on function public.end_all_owned_sessions() to authenticated;
grant execute on function public.delete_all_owned_sessions() to authenticated;

