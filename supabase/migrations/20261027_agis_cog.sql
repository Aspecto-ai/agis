-- Lagtype «cog»: stor GeoTIFF/COG som leses direkte fra Azure Blob Storage
-- via edge-funksjonen azure-cog (kortlevd, skrivebeskyttet SAS per fil).
alter table public.kart_layers drop constraint kart_layers_kind_check;
alter table public.kart_layers add constraint kart_layers_kind_check check (kind = any (array['vector','wms','xyz','raster','cog']));
comment on column public.kart_layers.source is 'vector: {} · wms/xyz: url · raster: png/tif i kart-filer · cog: {account, container, blob, projection, extent} – leses direkte fra Azure via edge-funksjonen azure-cog';
