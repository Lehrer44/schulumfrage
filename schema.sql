-- SchulUmfrage: Supabase schema
-- Apply this SQL in the Supabase SQL editor for project mqtcwiiawmuxrpkjfrfc.
-- The HTML clients use the publishable key only; never put a service_role key into GitHub.

create extension if not exists pgcrypto;

create table if not exists public.surveys (id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id) on delete cascade, name text not null, slides jsonb not null default '[]'::jsonb, created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists public.sessions (id uuid primary key default gen_random_uuid(), survey_id uuid not null references public.surveys(id) on delete cascade, owner_id uuid not null references auth.users(id) on delete cascade, title text not null, survey_snapshot jsonb not null default '[]'::jsonb, status text not null default 'lobby' check (status in ('lobby','running','ended')), current_slide integer not null default 0, join_code text not null unique, created_at timestamptz not null default now(), started_at timestamptz, updated_at timestamptz not null default now());
create table if not exists public.participants (id uuid primary key default gen_random_uuid(), session_id uuid not null references public.sessions(id) on delete cascade, name text not null, joined_at timestamptz not null default now(), last_seen_at timestamptz not null default now());
create table if not exists public.responses (id uuid primary key default gen_random_uuid(), session_id uuid not null references public.sessions(id) on delete cascade, participant_id uuid not null references public.participants(id) on delete cascade, slide_index integer not null, answer jsonb not null, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(session_id, participant_id, slide_index));
create index if not exists surveys_owner_id_idx on public.surveys(owner_id); create index if not exists sessions_owner_id_idx on public.sessions(owner_id); create index if not exists sessions_survey_id_idx on public.sessions(survey_id); create index if not exists sessions_join_code_idx on public.sessions(join_code); create index if not exists participants_session_id_idx on public.participants(session_id); create index if not exists responses_session_id_idx on public.responses(session_id);
alter table public.surveys enable row level security; alter table public.sessions enable row level security; alter table public.participants enable row level security; alter table public.responses enable row level security;
drop policy if exists surveys_select on public.surveys; create policy surveys_select on public.surveys for select to authenticated using ((select auth.uid())=owner_id);
drop policy if exists surveys_insert on public.surveys; create policy surveys_insert on public.surveys for insert to authenticated with check ((select auth.uid())=owner_id);
drop policy if exists surveys_update on public.surveys; create policy surveys_update on public.surveys for update to authenticated using ((select auth.uid())=owner_id) with check ((select auth.uid())=owner_id);
drop policy if exists surveys_delete on public.surveys; create policy surveys_delete on public.surveys for delete to authenticated using ((select auth.uid())=owner_id);
drop policy if exists sessions_teacher_select on public.sessions; create policy sessions_teacher_select on public.sessions for select to authenticated using ((select auth.uid())=owner_id);
drop policy if exists sessions_teacher_insert on public.sessions; create policy sessions_teacher_insert on public.sessions for insert to authenticated with check ((select auth.uid())=owner_id);
drop policy if exists sessions_teacher_update on public.sessions; create policy sessions_teacher_update on public.sessions for update to authenticated using ((select auth.uid())=owner_id) with check ((select auth.uid())=owner_id);
drop policy if exists sessions_anon_select on public.sessions; create policy sessions_anon_select on public.sessions for select to anon using (status='lobby');
drop policy if exists participants_teacher_select on public.participants; create policy participants_teacher_select on public.participants for select to authenticated using (exists(select 1 from public.sessions s where s.id=session_id and s.owner_id=(select auth.uid())));
drop policy if exists participants_anon_insert on public.participants; create policy participants_anon_insert on public.participants for insert to anon with check (exists(select 1 from public.sessions s where s.id=session_id and s.status in ('lobby','running')));
drop policy if exists responses_teacher_select on public.responses; create policy responses_teacher_select on public.responses for select to authenticated using (exists(select 1 from public.sessions s where s.id=session_id and s.owner_id=(select auth.uid())));
drop policy if exists responses_anon_insert on public.responses; create policy responses_anon_insert on public.responses for insert to anon with check (exists(select 1 from public.sessions s where s.id=session_id and s.status='running') and exists(select 1 from public.participants p where p.id=participant_id and p.session_id=session_id));
drop policy if exists responses_teacher_delete on public.responses; create policy responses_teacher_delete on public.responses for delete to authenticated using (exists(select 1 from public.sessions s where s.id=session_id and s.owner_id=(select auth.uid())));

create or replace function public.set_updated_at() returns trigger language plpgsql as $$ begin new.updated_at=now(); return new; end; $$;
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
