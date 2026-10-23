-- AGIS v1.1: flere koordinatsystemer (Finnmark, Færøyane, Skottland) og rasterlag (GeoTIFF)
alter table public.kart_maps drop constraint if exists kart_maps_crs_check;
alter table public.kart_maps add constraint kart_maps_crs_check
  check (crs in ('EPSG:25832','EPSG:25833','EPSG:25835','EPSG:5316','EPSG:27700'));

alter table public.kart_layers drop constraint if exists kart_layers_kind_check;
alter table public.kart_layers add constraint kart_layers_kind_check
  check (kind in ('vector','wms','xyz','raster'));

-- Oppdatering av rasterfiler (upsert) krever update-policy på storage
drop policy if exists kart_filer_update on storage.objects;
create policy kart_filer_update on storage.objects for update
  using (bucket_id = 'kart-filer' and public.kart_can_edit(((storage.foldername(name))[1])::uuid));
