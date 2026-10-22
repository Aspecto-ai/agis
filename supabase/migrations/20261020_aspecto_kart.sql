-- AGIS — databaseskjema (v1)
-- Tabellene har prefiks kart_ og ligger i public slik at PostgREST eksponerer dem uten ekstra oppsett.
-- Alt er beskyttet med RLS. Ansatte = e-post som slutter på @aspecto.no (via Entra-innlogging).
-- Kunder gis tilgang per kart via kart_access (e-post) eller via is_public.

create extension if not exists postgis with schema extensions;

-- ---------------------------------------------------------------
-- Hjelpefunksjoner (brukes i RLS)
-- ---------------------------------------------------------------
create or replace function public.kart_my_email() returns text
language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

create or replace function public.kart_is_staff() returns boolean
language sql stable as $$
  select public.kart_my_email() like '%@aspecto.no';
$$;

-- ---------------------------------------------------------------
-- Tabeller
-- ---------------------------------------------------------------
create table if not exists public.kart_maps (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  description  text,
  owner_id     uuid references auth.users(id) on delete set null,
  owner_email  text,
  is_public    boolean not null default false,
  crs          text not null default 'EPSG:25833' check (crs in ('EPSG:25832','EPSG:25833')),  -- visningsprojeksjon; grunnlag er alltid Kartverket topo-WMS
  center_lng   double precision,
  center_lat   double precision,
  zoom         double precision,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists public.kart_layers (
  id          uuid primary key default gen_random_uuid(),
  map_id      uuid not null references public.kart_maps(id) on delete cascade,
  name        text not null,
  kind        text not null check (kind in ('vector','wms','xyz')),
  source      jsonb not null default '{}'::jsonb,   -- wms: {url, layers, format} / xyz: {tiles:[...]}
  style       jsonb not null default '{}'::jsonb,   -- vector: {color, fillOpacity, width, radius}
  sort_order  integer not null default 0,
  visible     boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists kart_layers_map_idx on public.kart_layers(map_id);

create table if not exists public.kart_features (
  id          uuid primary key default gen_random_uuid(),
  layer_id    uuid not null references public.kart_layers(id) on delete cascade,
  geom        extensions.geometry(Geometry, 4326) not null,
  props       jsonb not null default '{}'::jsonb,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists kart_features_layer_idx on public.kart_features(layer_id);
create index if not exists kart_features_geom_idx on public.kart_features using gist(geom);

create table if not exists public.kart_comments (
  id            uuid primary key default gen_random_uuid(),
  map_id        uuid not null references public.kart_maps(id) on delete cascade,
  geom          extensions.geometry(Point, 4326) not null,
  body          text not null,
  author_id     uuid references auth.users(id) on delete set null,
  author_email  text,
  resolved      boolean not null default false,
  created_at    timestamptz not null default now()
);
create index if not exists kart_comments_map_idx on public.kart_comments(map_id);

create table if not exists public.kart_access (
  map_id   uuid not null references public.kart_maps(id) on delete cascade,
  email    text not null,
  role     text not null default 'viewer' check (role in ('viewer','editor')),
  added_at timestamptz not null default now(),
  primary key (map_id, email)
);

-- ---------------------------------------------------------------
-- Tilgangsfunksjoner
-- ---------------------------------------------------------------
create or replace function public.kart_can_view(p_map uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.kart_maps m
    where m.id = p_map
      and (m.is_public
        or public.kart_is_staff()
        or m.owner_id = auth.uid()
        or exists (select 1 from public.kart_access a
                   where a.map_id = m.id and a.email = public.kart_my_email()))
  );
$$;

create or replace function public.kart_can_edit(p_map uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.kart_maps m
    where m.id = p_map
      and (public.kart_is_staff()
        or m.owner_id = auth.uid()
        or exists (select 1 from public.kart_access a
                   where a.map_id = m.id and a.email = public.kart_my_email() and a.role = 'editor'))
  );
$$;

-- ---------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------
alter table public.kart_maps     enable row level security;
alter table public.kart_layers   enable row level security;
alter table public.kart_features enable row level security;
alter table public.kart_comments enable row level security;
alter table public.kart_access   enable row level security;

-- Kart
create policy kart_maps_select on public.kart_maps for select
  using (public.kart_can_view(id));
create policy kart_maps_insert on public.kart_maps for insert
  with check (public.kart_is_staff());
create policy kart_maps_update on public.kart_maps for update
  using (public.kart_can_edit(id)) with check (public.kart_can_edit(id));
create policy kart_maps_delete on public.kart_maps for delete
  using (public.kart_is_staff() or owner_id = auth.uid());

-- Lag
create policy kart_layers_select on public.kart_layers for select
  using (public.kart_can_view(map_id));
create policy kart_layers_write on public.kart_layers for all
  using (public.kart_can_edit(map_id)) with check (public.kart_can_edit(map_id));

-- Features
create policy kart_features_select on public.kart_features for select
  using (exists (select 1 from public.kart_layers l where l.id = layer_id and public.kart_can_view(l.map_id)));
create policy kart_features_write on public.kart_features for all
  using (exists (select 1 from public.kart_layers l where l.id = layer_id and public.kart_can_edit(l.map_id)))
  with check (exists (select 1 from public.kart_layers l where l.id = layer_id and public.kart_can_edit(l.map_id)));

-- Kommentarer: alle som kan se kartet (og er innlogget) kan kommentere
create policy kart_comments_select on public.kart_comments for select
  using (public.kart_can_view(map_id));
create policy kart_comments_insert on public.kart_comments for insert
  with check (auth.uid() is not null and public.kart_can_view(map_id));
create policy kart_comments_update on public.kart_comments for update
  using (author_id = auth.uid() or public.kart_can_edit(map_id));
create policy kart_comments_delete on public.kart_comments for delete
  using (author_id = auth.uid() or public.kart_can_edit(map_id));

-- Tilgang: kun de som kan redigere kartet
create policy kart_access_select on public.kart_access for select
  using (public.kart_can_edit(map_id) or email = public.kart_my_email());
create policy kart_access_write on public.kart_access for all
  using (public.kart_can_edit(map_id)) with check (public.kart_can_edit(map_id));

-- ---------------------------------------------------------------
-- RPC: GeoJSON ut og inn
-- ---------------------------------------------------------------
create or replace function public.kart_layer_geojson(p_layer uuid) returns jsonb
language sql stable security invoker set search_path = public, extensions as $$
  select jsonb_build_object(
    'type', 'FeatureCollection',
    'features', coalesce(jsonb_agg(jsonb_build_object(
        'type', 'Feature',
        'id', f.id,
        'geometry', extensions.ST_AsGeoJSON(f.geom, 6)::jsonb,
        'properties', f.props || jsonb_build_object('_id', f.id)
    ) order by f.created_at), '[]'::jsonb)
  )
  from public.kart_features f
  where f.layer_id = p_layer;
$$;

create or replace function public.kart_import_geojson(p_layer uuid, p_fc jsonb) returns integer
language plpgsql security invoker set search_path = public, extensions as $$
declare
  n integer := 0;
  f jsonb;
  feats jsonb;
begin
  if p_fc ->> 'type' = 'FeatureCollection' then
    feats := p_fc -> 'features';
  elsif p_fc ->> 'type' = 'Feature' then
    feats := jsonb_build_array(p_fc);
  else
    feats := jsonb_build_array(jsonb_build_object('type','Feature','geometry',p_fc,'properties','{}'::jsonb));
  end if;

  for f in select * from jsonb_array_elements(feats) loop
    if f -> 'geometry' is null or f -> 'geometry' = 'null'::jsonb then continue; end if;
    insert into public.kart_features(layer_id, geom, props, created_by)
    values (
      p_layer,
      extensions.ST_SetSRID(extensions.ST_GeomFromGeoJSON((f -> 'geometry')::text), 4326),
      coalesce(f -> 'properties', '{}'::jsonb),
      auth.uid()
    );
    n := n + 1;
  end loop;
  return n;
end;
$$;

create or replace function public.kart_update_feature(p_id uuid, p_geometry jsonb, p_props jsonb) returns void
language sql security invoker set search_path = public, extensions as $$
  update public.kart_features
  set geom  = coalesce(extensions.ST_SetSRID(extensions.ST_GeomFromGeoJSON(p_geometry::text), 4326), geom),
      props = coalesce(p_props, props)
  where id = p_id;
$$;

create or replace function public.kart_map_bbox(p_map uuid) returns double precision[]
language sql stable security invoker set search_path = public, extensions as $$
  select array[
    extensions.ST_XMin(e), extensions.ST_YMin(e), extensions.ST_XMax(e), extensions.ST_YMax(e)
  ]
  from (
    select extensions.ST_Extent(f.geom) as e
    from public.kart_features f
    join public.kart_layers l on l.id = f.layer_id
    where l.map_id = p_map
  ) s
  where e is not null;
$$;

create or replace function public.kart_add_comment(p_map uuid, p_lng double precision, p_lat double precision, p_body text) returns uuid
language sql security invoker set search_path = public, extensions as $$
  insert into public.kart_comments(map_id, geom, body, author_id, author_email)
  values (p_map, extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326), p_body, auth.uid(), public.kart_my_email())
  returning id;
$$;

create or replace function public.kart_list_comments(p_map uuid) returns jsonb
language sql stable security invoker set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'body', c.body, 'author', c.author_email, 'resolved', c.resolved,
    'created_at', c.created_at,
    'lng', extensions.ST_X(c.geom), 'lat', extensions.ST_Y(c.geom)
  ) order by c.created_at desc), '[]'::jsonb)
  from public.kart_comments c where c.map_id = p_map;
$$;

-- updated_at-trigger
create or replace function public.kart_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;
drop trigger if exists kart_maps_touch on public.kart_maps;
create trigger kart_maps_touch before update on public.kart_maps
  for each row execute function public.kart_touch();

-- ---------------------------------------------------------------
-- Lagring av råfiler (GeoTIFF, shapefile-zip, PDF-rapporter) per kart
-- ---------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('kart-filer', 'kart-filer', false)
on conflict (id) do nothing;

create policy kart_filer_read on storage.objects for select
  using (bucket_id = 'kart-filer' and public.kart_can_view(((storage.foldername(name))[1])::uuid));
create policy kart_filer_write on storage.objects for insert
  with check (bucket_id = 'kart-filer' and public.kart_can_edit(((storage.foldername(name))[1])::uuid));
create policy kart_filer_delete on storage.objects for delete
  using (bucket_id = 'kart-filer' and public.kart_can_edit(((storage.foldername(name))[1])::uuid));

grant execute on function public.kart_layer_geojson(uuid) to anon, authenticated;
grant execute on function public.kart_import_geojson(uuid, jsonb) to authenticated;
grant execute on function public.kart_update_feature(uuid, jsonb, jsonb) to authenticated;
grant execute on function public.kart_map_bbox(uuid) to anon, authenticated;
grant execute on function public.kart_add_comment(uuid, double precision, double precision, text) to authenticated;
grant execute on function public.kart_list_comments(uuid) to anon, authenticated;
