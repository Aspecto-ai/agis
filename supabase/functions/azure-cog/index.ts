// azure-cog – gir AGIS lesetilgang til GeoTIFF/COG i Aspectos Azure-lagring.
//
// Nettleseren leser rasteret direkte fra Azure Blob Storage med HTTP range-
// forespørsler (bare de delene som vises). Denne funksjonen:
//   1. sjekker at innlogget bruker kan se laget (via RLS på kart_layers),
//   2. signerer en kortlevd, skrivebeskyttet SAS for akkurat den ene filen.
// Lagringsnøkkelen forlater aldri serveren.
//
// Secrets (settes i Supabase → Edge Functions → Secrets):
//   AZURE_STORAGE_KEYS = {"aspectosystem":"<access key>"}   (JSON, én eller flere kontoer)
//
// POST { layer_id, action?: "url" | "info" }
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { fromUrl } from "npm:geotiff@2.1.3";

const ORIGINS = ["https://kart.aspecto.no", "https://aspecto-ai.github.io", "http://localhost:8080"];
const SAS_HOURS = 8;
const SV = "2022-11-02";

function cors(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.includes(o) ? o : ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
const json = (req: Request, body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

const iso = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, "Z");

async function hmac(keyB64: string, msg: string) {
  const raw = Uint8Array.from(atob(keyB64), (c) => c.charCodeAt(0));
  const k = await crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg)));
  return btoa(String.fromCharCode(...sig));
}

// Service SAS for én blob, kun lesing, kun HTTPS.
export async function blobSas(account: string, key: string, container: string, blob: string, hours = SAS_HOURS) {
  const st = iso(new Date(Date.now() - 5 * 60_000));
  const se = iso(new Date(Date.now() + hours * 3600_000));
  const resource = `/blob/${account}/${container}/${blob}`;
  const toSign = ["r", st, se, resource, "", "", "https", SV, "b", "", "", "", "", "", "", ""].join("\n");
  const sig = await hmac(key, toSign);
  const q = new URLSearchParams({ sv: SV, sr: "b", sp: "r", st, se, spr: "https", sig });
  const path = blob.split("/").map(encodeURIComponent).join("/");
  return { url: `https://${account}.blob.core.windows.net/${container}/${path}?${q}`, expires: se };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  try {
    const auth = req.headers.get("Authorization") ?? "";
    if (!auth.startsWith("Bearer ")) return json(req, { error: "Ikke innlogget" }, 401);
    const { layer_id, action = "url" } = await req.json();
    if (!layer_id) return json(req, { error: "layer_id mangler" }, 400);

    // Spørringen kjøres som brukeren, så RLS avgjør om laget er synlig.
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: auth } },
    });
    const { data: layer, error } = await sb.from("kart_layers").select("id,map_id,kind,source").eq("id", layer_id).maybeSingle();
    if (error) return json(req, { error: error.message }, 400);
    if (!layer || layer.kind !== "cog") return json(req, { error: "Ingen tilgang" }, 403);

    const { account, container, blob } = layer.source ?? {};
    const keys = JSON.parse(Deno.env.get("AZURE_STORAGE_KEYS") ?? "{}");
    const key = keys[account];
    if (!key || !container || !blob) return json(req, { error: `Azure-konto ${account} er ikke satt opp` }, 500);

    const sas = await blobSas(account, key, container, blob);
    if (action === "url") return json(req, sas);

    if (action === "info") {
      const { data: canEdit } = await sb.rpc("kart_can_edit", { p_map: layer.map_id });
      if (!canEdit) return json(req, { error: "Kun redaktører" }, 403);
      const tiff = await fromUrl(sas.url);
      const n = await tiff.getImageCount();
      const img = await tiff.getImage(0);
      const gk = img.getGeoKeys() ?? {};
      return json(req, {
        width: img.getWidth(), height: img.getHeight(), bands: img.getSamplesPerPixel(),
        bitsPerSample: img.getBitsPerSample(), tiled: img.isTiled, tileSize: [img.getTileWidth(), img.getTileHeight()],
        images: n, bbox: img.getBoundingBox(), resolution: img.getResolution(), origin: img.getOrigin(),
        epsg: gk.ProjectedCSTypeGeoKey ?? gk.GeographicTypeGeoKey ?? null, nodata: img.getGDALNoData(),
        compression: img.fileDirectory.Compression, photometric: img.fileDirectory.PhotometricInterpretation,
      });
    }
    return json(req, { error: "Ukjent action" }, 400);
  } catch (e) {
    return json(req, { error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
