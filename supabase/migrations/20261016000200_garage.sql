-- Garage: vehicles, modifications and photos. Private vehicles are invisible
-- to every query except the owner's, including through joins from posts.

create type public.vehicle_kind as enum ('car', 'motorcycle');

create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  kind public.vehicle_kind not null,
  body_style text not null default 'other'
    check (body_style in ('sedan','coupe','hatchback','wagon','convertible','suv','truck','van',
                          'sport','naked','cruiser','adventure','scooter','other')),
  make text not null check (char_length(make) between 1 and 60),
  model text not null check (char_length(model) between 1 and 60),
  year integer not null check (year between 1885 and 2100),
  trim text not null default '' check (char_length(trim) <= 60),
  nickname text not null default '' check (char_length(nickname) <= 40),
  mileage integer check (mileage >= 0),
  mileage_unit text not null default 'mph' check (mileage_unit in ('mph', 'kmh')),
  summary text not null default '' check (char_length(summary) <= 2000),
  visibility public.visibility not null default 'friends',
  cover_photo_path text,
  identity_color text not null default 'sodium'
    check (identity_color in ('sodium','redline','britishGreen','gulf','ultraviolet','titanium')),
  position integer not null default 0,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index vehicles_owner_idx on public.vehicles (owner_id, position);

create table public.vehicle_mods (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles (id) on delete cascade,
  category text not null default 'other'
    check (category in ('engine','intake','exhaust','forced_induction','tune','drivetrain','suspension',
                        'brakes','wheels','tires','aero','exterior','interior','lighting','electronics','other')),
  title text not null check (char_length(title) between 1 and 120),
  brand text not null default '',
  notes text not null default '' check (char_length(notes) <= 2000),
  installed_on timestamptz,
  created_at timestamptz not null default now()
);
create index vehicle_mods_vehicle_idx on public.vehicle_mods (vehicle_id);

create table public.vehicle_photos (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles (id) on delete cascade,
  storage_path text not null unique,
  position integer not null default 0,
  created_at timestamptz not null default now()
);
create index vehicle_photos_vehicle_idx on public.vehicle_photos (vehicle_id, position);

create trigger vehicles_touch before update on public.vehicles
  for each row execute function private.touch_updated_at();

-- Owner can never be reassigned, and photo paths must live in the owner's
-- storage folder so one user cannot point at another's files.
create or replace function private.guard_vehicle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.owner_id <> old.owner_id then
    raise exception 'vehicle owner is immutable' using errcode = '42501';
  end if;
  if new.cover_photo_path is not null and split_part(new.cover_photo_path, '/', 1) <> new.owner_id::text then
    raise exception 'cover photo must be in the owner''s folder' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger vehicles_guard before insert or update on public.vehicles
  for each row execute function private.guard_vehicle();

create or replace function public.owns_vehicle(p_vehicle uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.vehicles where id = p_vehicle and owner_id = auth.uid());
$$;

create or replace function public.can_view_vehicle(p_vehicle uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.vehicles v where v.id = p_vehicle and public.can_view(v.owner_id, v.visibility));
$$;

alter table public.vehicles enable row level security;
alter table public.vehicle_mods enable row level security;
alter table public.vehicle_photos enable row level security;

create policy "Vehicles: visible per visibility"
  on public.vehicles for select to authenticated
  using (public.can_view(owner_id, visibility));
create policy "Vehicles: owner inserts"
  on public.vehicles for insert to authenticated with check (owner_id = auth.uid());
create policy "Vehicles: owner updates"
  on public.vehicles for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "Vehicles: owner deletes"
  on public.vehicles for delete to authenticated using (owner_id = auth.uid());

create policy "Mods: follow the vehicle"
  on public.vehicle_mods for select to authenticated using (public.can_view_vehicle(vehicle_id));
create policy "Mods: owner writes"
  on public.vehicle_mods for all to authenticated
  using (public.owns_vehicle(vehicle_id)) with check (public.owns_vehicle(vehicle_id));

create policy "Photos: follow the vehicle"
  on public.vehicle_photos for select to authenticated using (public.can_view_vehicle(vehicle_id));
create policy "Photos: owner writes into own folder"
  on public.vehicle_photos for all to authenticated
  using (public.owns_vehicle(vehicle_id))
  with check (public.owns_vehicle(vehicle_id) and split_part(storage_path, '/', 1) = auth.uid()::text);

grant execute on function public.can_view_vehicle(uuid) to authenticated;
grant execute on function public.owns_vehicle(uuid) to authenticated;
