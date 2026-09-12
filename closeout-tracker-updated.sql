-- CLOSEOUT TRACKER — UPDATED SUPABASE SQL
-- Run in Supabase SQL Editor.
-- Main changes:
-- 1. Hotel is the only required field.
-- 2. Status, Agent, Email Time, Completion Time and Notes are nullable.
-- 3. Duplicate hotel entries are intentionally allowed.
-- 4. Every closeout has a UUID record ID.
-- 5. Edit/Delete must target the UUID id, never the hotel name.
-- 6. Blank status = Pending; it must NOT be auto-converted to N/A.
-- 7. Historical records remain in the same table.

create extension if not exists pgcrypto;

-- ============================================================
-- CLOSEOUT ENTRIES
-- ============================================================

create table if not exists public.closeout_entries (
  id uuid primary key default gen_random_uuid(),
  closeout_date date not null default current_date,
  hotel text not null,
  platform text null,
  status text null,
  email_time time null,
  completion_time time null,
  agent text null,
  notes text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint closeout_entries_hotel_not_blank
    check (length(trim(hotel)) > 0),

  constraint closeout_entries_platform_check
    check (
      platform is null or platform in
      ('HPN','WEBB','ROIBOS','GRN','INGO','PAX2N','HIKARI','ODOS')
    ),

  constraint closeout_entries_status_check
    check (
      status is null or status in ('Done','No','N/A')
    )
);

-- If the table already exists, add the new field safely.
alter table public.closeout_entries
  add column if not exists updated_at timestamptz not null default now();

-- The following fields must be optional so LOG FIRST -> PROCESS LATER works.
alter table public.closeout_entries alter column platform drop not null;
alter table public.closeout_entries alter column status drop not null;
alter table public.closeout_entries alter column email_time drop not null;
alter table public.closeout_entries alter column completion_time drop not null;
alter table public.closeout_entries alter column agent drop not null;
alter table public.closeout_entries alter column notes drop not null;

-- Hotel remains required.
alter table public.closeout_entries alter column hotel set not null;

-- IMPORTANT:
-- There is deliberately NO unique constraint on hotel/date/time.
-- The same hotel can therefore be logged multiple times.
create index if not exists idx_closeout_entries_date_created
  on public.closeout_entries (closeout_date, created_at);

create index if not exists idx_closeout_entries_date_email_time
  on public.closeout_entries (closeout_date, email_time);

create index if not exists idx_closeout_entries_hotel
  on public.closeout_entries (lower(trim(hotel)));

-- ============================================================
-- UPDATED_AT TRIGGER
-- ============================================================

create or replace function public.set_closeout_entries_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_closeout_entries_updated_at
on public.closeout_entries;

create trigger trg_closeout_entries_updated_at
before update on public.closeout_entries
for each row
execute function public.set_closeout_entries_updated_at();

-- ============================================================
-- EXTRANET HOTELS — EXISTING FUNCTIONALITY
-- ============================================================

create table if not exists public.extranet_hotels (
  id uuid primary key default gen_random_uuid(),
  platform text not null,
  hotel_name text not null,
  hotel_type text not null,
  created_at timestamptz not null default now(),

  constraint extranet_hotels_platform_check
    check (platform in
      ('HPN','WEBB','ROIBOS','GRN','INGO','PAX2N','HIKARI','ODOS')
    ),

  constraint extranet_hotels_type_check
    check (hotel_type in
      ('Contract','Promo','Contract + Promo')
    )
);

create unique index if not exists idx_extranet_hotels_platform_hotel_unique
  on public.extranet_hotels (platform, lower(trim(hotel_name)));

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

alter table public.closeout_entries enable row level security;
alter table public.extranet_hotels enable row level security;

drop policy if exists "closeout_entries_select_public" on public.closeout_entries;
create policy "closeout_entries_select_public"
on public.closeout_entries for select
to anon, authenticated using (true);

drop policy if exists "closeout_entries_insert_public" on public.closeout_entries;
create policy "closeout_entries_insert_public"
on public.closeout_entries for insert
to anon, authenticated
with check (length(trim(hotel)) > 0);

drop policy if exists "closeout_entries_update_public" on public.closeout_entries;
create policy "closeout_entries_update_public"
on public.closeout_entries for update
to anon, authenticated
using (true)
with check (length(trim(hotel)) > 0);

drop policy if exists "closeout_entries_delete_public" on public.closeout_entries;
create policy "closeout_entries_delete_public"
on public.closeout_entries for delete
to anon, authenticated using (true);

drop policy if exists "extranet_hotels_select_public" on public.extranet_hotels;
create policy "extranet_hotels_select_public"
on public.extranet_hotels for select
to anon, authenticated using (true);

drop policy if exists "extranet_hotels_insert_public" on public.extranet_hotels;
create policy "extranet_hotels_insert_public"
on public.extranet_hotels for insert
to anon, authenticated with check (true);

drop policy if exists "extranet_hotels_update_public" on public.extranet_hotels;
create policy "extranet_hotels_update_public"
on public.extranet_hotels for update
to anon, authenticated using (true) with check (true);

drop policy if exists "extranet_hotels_delete_public" on public.extranet_hotels;
create policy "extranet_hotels_delete_public"
on public.extranet_hotels for delete
to anon, authenticated using (true);

-- ============================================================
-- REALTIME
-- ============================================================

do $$
begin
  alter publication supabase_realtime add table public.closeout_entries;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.extranet_hotels;
exception when duplicate_object then null;
end $$;

-- ============================================================
-- CLEAN UP EMPTY STRINGS
-- ============================================================
-- Keeps existing records; converts empty optional values to NULL.

update public.closeout_entries
set status = null
where trim(coalesce(status, '')) = '';

update public.closeout_entries
set platform = null
where trim(coalesce(platform, '')) = '';

update public.closeout_entries
set agent = null
where trim(coalesce(agent, '')) = '';

update public.closeout_entries
set notes = null
where trim(coalesce(notes, '')) = '';

-- ============================================================
-- FRONT-END IMPLEMENTATION REQUIREMENTS
-- ============================================================
-- ADD: always INSERT a new row.
-- EDIT: UPDATE WHERE id = the selected record's UUID.
-- DELETE: DELETE WHERE id = the selected record's UUID.
--
-- NEVER identify an entry by hotel name.
-- NEVER merge/overwrite a matching hotel automatically.
--
-- Workflow:
-- LOG FIRST -> PROCESS LATER -> UPDATE SAME ENTRY
--
-- Dashboard:
-- Total   = all saved records
-- Done    = status 'Done'
-- No      = status 'No'
-- N/A     = status 'N/A'
-- Pending = status IS NULL
--
-- History:
-- Current-day records remain visible.
-- Previous dates are historical views of the same table.
-- Do not copy records into a separate history table.
--
-- NOTE: Existing data is not deleted by this migration.
