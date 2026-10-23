# AGIS – AspectoGIS

Egen kartportal som erstatter Felt for det Aspecto faktisk bruker: publisere surveydata og
lokalitetsinformasjon til kunder, med lag, tegning, måling, kommentarer, deling og innbygging på aspecto.no.
Innlogging med Microsoft Entra ID (MFA håndheves i Entra). Frittstående fra Miljøstatus.

## Innhold

| Mappe/fil | Hva |
|---|---|
| `web/index.html` | Hele appen (én fil). OpenLayers 10 + proj4 + supabase-js fra CDN. Demo-modus når konfigurasjonen er tom. |
| `supabase/migrations/20261020_aspecto_kart.sql` + `20261023_agis_crs_raster.sql` | Databaseskjema: PostGIS, tabeller `kart_*`, RLS, RPC-funksjoner, storage-bucket. |
| `supabase/functions/kart/index.ts` | Valgfri: server `index.html` som Supabase Edge Function (rask demo-hosting). |

## Funksjoner i v1

- Kartliste → kart med lag (vektor/GeoJSON, WMS, XYZ-raster)
- **Fast grunnlag for alle kart: Kartverket topografisk norgeskart** via WMS `https://wms.geonorge.no/skwms1/wms.topo` (lag `topo`, WMS 1.3.0)
- **Kartet rendres i EUREF89 UTM**: EPSG:25832 (sone 32N) sør for 65°N, EPSG:25833 (sone 33N) nord for – grensen tilsvarer omtrent fylkesgrensa Trøndelag/Nordland, like nord for Rørvik. Velges automatisk ut fra kartets senter og kan overstyres per kart under «Deling → Koordinatsystem». Gjeldende CRS vises alltid nederst til høyre, koordinater (N/E i meter) nederst til venstre. WMS-kallene går i samme CRS, så det er ingen reprojisering av grunnlaget.
- Katalog med overlegg (Kartverket sjøkart raster, dybdedata, Norge i bilder, Fiskeridirektoratet akvakultur, NGU bunnsedimenter) – alle som WMS i kartets CRS
- Last opp GeoJSON, tegn punkt/linje/polygon, rediger attributter, slett
- Fargelegging etter attributt – ferdig oppsett for MOM-B tilstand 1–4 med tegnforklaring
- Måleverktøy (avstand), lengde/areal i objekt-popup, koordinatvisning (UTM N/E), målestokk
- Kommentarer festet til posisjon (alle innloggede som kan se kartet), marker som løst
- Deling: offentlig kart (uten innlogging), tilgang per e-post (leser/redigerer), kopier lenke, iframe-kode
- Innbyggingsmodus `?embed=1` (ingen panel, «Åpne i AGIS»-knapp)
- Last ned lag som GeoJSON
- Mobiltilpasset (panel som skuff nederst)

Ikke i v1 (kan bygges ved behov): GeoTIFF/COG-visning i nettleser, shapefile-import (gjøres i QGIS → GeoJSON), sanntids samredigering, offline.

## Oppsett – steg for steg

### 1. Supabase (database)

Velg prosjekt: nytt prosjekt «aspecto-kart» (helt uavhengig) eller eksisterende «Miljostatus» (tabellene har prefiks `kart_` og kolliderer ikke). Kjør migrasjonen:

```
supabase db push            # eller lim inn SQL-filen i SQL Editor
```

Migrasjonen aktiverer PostGIS, lager tabeller, RLS-regler og RPC-funksjoner. Regler:
- Ansatte = e-post som slutter på `@aspecto.no` → ser og redigerer alt
- Kunder → ser kart de er lagt til på (`kart_access`) eller som er offentlige; kommenterer, redigerer ikke (med mindre rolle `editor`)
- Anonyme → kun offentlige kart

### 2. Entra ID (innlogging + MFA)

1. Entra admin center → App registrations → **New registration**
   - Navn: `AGIS`
   - Supported account types: *Accounts in this organizational directory only* (gjester i tenanten dekkes)
   - Redirect URI (Web): `https://<prosjekt-ref>.supabase.co/auth/v1/callback`
2. Certificates & secrets → **New client secret** (noter verdien)
3. API permissions: `openid`, `email`, `profile` (User.Read er nok) → Grant admin consent
4. Supabase → Authentication → Providers → **Azure**
   - Enabled, Client ID = Application (client) ID, Secret = secret-verdien
   - Azure Tenant URL: `https://login.microsoftonline.com/<tenant-id>`
5. Supabase → Authentication → URL Configuration
   - Site URL: `https://kart.aspecto.no` (eller der appen hostes)
   - Redirect URLs: samme + `https://kart.aspecto.no/**`
6. **MFA**: Entra → Protection → Conditional Access → ny policy «AGIS – krev MFA»: Users = All users (inkl. guests), Target resources = app «AGIS», Grant = Require multifactor authentication. (Har dere Security Defaults på, er MFA allerede påkrevd.)
7. **Kunder**: Entra → Users → **New guest user** → inviter kundens e-post. Legg samme e-post til under «Deling → Tilgang per e-post» på kartet. Gjester får MFA gjennom policyen over.

### 3. Konfigurer appen

I toppen av `web/index.html`:

```js
window.ASPECTO_KART_CONFIG = {
  supabaseUrl: "https://<prosjekt-ref>.supabase.co",
  supabaseAnonKey: "<anon/publishable key>",
  staffDomain: "aspecto.no",
  appName: "AGIS"
};
```

Anon-nøkkelen er ment å være offentlig; all sikkerhet ligger i RLS.

### 4. Hosting

Appen er én statisk fil. Alternativer, fra enklest til mest «Microsoft-nært»:

| Alternativ | Pris | Kommentar |
|---|---|---|
| GitHub Pages | 0 | Repo `Aspecto-ai/agis`, Pages fra `web/`, CNAME `kart.aspecto.no`. Deploy = git push. |
| Azure Static Web Apps | 0 (Free) | Passer tenant/Entra-verdenen, egendefinert domene inkludert. |
| Supabase Edge Function | 0 | `supabase functions deploy kart --no-verify-jwt`. Greit for demo, ikke anbefalt for prod. |

DNS: `kart.aspecto.no` → CNAME til hostingen.

### 5. Innbygging på aspecto.no

Sett kartet til «Offentlig» under Deling, og lim inn iframe-koden fra samme fane:

```html
<iframe src="https://kart.aspecto.no/?map=<id>&embed=1" width="100%" height="560"
        style="border:0;border-radius:8px" loading="lazy" allowfullscreen></iframe>
```

Private kart kan også bygges inn, men innlogging skjer ikke inne i rammen (Microsoft tillater ikke innlogging i iframe) – besøkende får en «Åpne i AGIS»-knapp.

## Koordinatsystem – regler

| Region (kartets senter) | CRS | Kartgrunnlag |
|---|---|---|
| Sør-Norge, sør for 65°N | EPSG:25832 – EUREF89 UTM 32N | Kartverket topo (WMS) |
| Nord-Norge, 65°N og nordover | EPSG:25833 – EUREF89 UTM 33N | Kartverket topo |
| Finnmark, 68°N og nordover, øst for 22°Ø | EPSG:25835 – EUREF89 UTM 35N | Kartverket topo |
| Færøyane | EPSG:5316 – ETRS89 / Faroe TM | OpenStreetMap |
| Skottland / Storbritannia | EPSG:27700 – British National Grid | OpenStreetMap |

Overstyres per kart under «Deling → Koordinatsystem» (lagres i `kart_maps.crs`). Grensene er konstantene `CRS_SPLIT_LAT` og `FINNMARK_LON` i `web/index.html`. Kartverket topo dekker kun Norge; for Færøyane og Skottland finnes ingen åpen topo-WMS uten nøkkel, derfor OpenStreetMap. Ordnance Survey kan legges inn senere med API-nøkkel fra OS Data Hub. EPSG:27700 bruker 7-parameter Helmert-transformasjon (±2–5 m), siden OSTN15-gridet ikke kan brukes i nettleseren. Alle data lagres som WGS84 (EPSG:4326) og regnes om ved visning.

## Legg til lag – dra og slipp

Redigerere kan dra filer rett inn i kartet eller i «Legg til lag». AGIS gjenkjenner formatet og koordinatsystemet selv og spør i popup bare når noe er uklart:

| Format | Koordinatsystem |
|---|---|
| GeoJSON (.geojson/.json) | Fra `crs`-feltet; ellers grader, eller spør ved projiserte koordinater |
| KML / KMZ / GPX | Alltid WGS84 |
| Shapefil (.zip, eller .shp+.dbf+.prj sluppet sammen) | Fra .prj; spør hvis .prj mangler |
| CSV / TXT / Excel (.xlsx) | Finner kolonner som Breddegrad/Lengdegrad, Lat/Lon, Nord/Øst, N/E. Forstår desimalgrader, grader-minutter (`66°06,600'N`), komma som desimaltegn og `;`-separert. Kolonne «sone» gir UTM-sone per rad. Spør om kolonner og koordinatsystem når det er uklart |
| GeoTIFF (.tif) | Fra GeoKeys; spør hvis ukjent. Én-bånds rastere (batymetri) fargelegges med dybdeskala, RGB vises som bilde. Originalen lagres i Storage og kan lastes ned |

Lag med attributtet `tilstand` får automatisk MOM-B-farger (tilstand 1–4).

## Dataflyt fra survey

QGIS → eksporter som GeoJSON (EPSG:4326) → «Legg til lag → Last opp GeoJSON-fil». For MOM-B: ha en attributt `tilstand` (1–4) og velg «Fargelegg etter attributt: tilstand» i laginnstillingene. Rå filer (GeoTIFF, rapporter) kan legges i storage-bucket `kart-filer/<kart-id>/` for nedlasting; visning av batymetri-raster i nettleser er neste steg (COG + titiler eller forhåndsrendrede fliser).

## Økonomi

Supabase Pro ca. 25 USD/mnd (eller 0 på Free), hosting 0, Kartverket-WMS 0 (åpne data, vis «© Kartverket»). Mot Felt Business 599 USD/mnd.
