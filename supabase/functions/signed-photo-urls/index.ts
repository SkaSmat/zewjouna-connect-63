// Edge Function: signed-photo-urls
//
// Returns short-lived signed URLs for ANOTHER user's profile photos.
// Photos live in a PRIVATE bucket, so this is the only sanctioned way for a
// client to display someone else's pictures. We authorize the caller, refuse
// if either side has blocked the other, then mint signed URLs with the service
// role key (which the browser never sees).
//
// Request body: { target_id: string }
// Response:     { urls: string[] }

import { createClient } from "jsr:@supabase/supabase-js@2";

const SIGN_TTL_SECONDS = 600; // 10 minutes
const BUCKET = "profile-photos";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader) return json({ error: "Missing authorization" }, 401);

  // Identify the caller from their JWT.
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const {
    data: { user },
    error: userErr,
  } = await userClient.auth.getUser();
  if (userErr || !user) return json({ error: "Unauthorized" }, 401);

  let targetId: string | undefined;
  try {
    targetId = (await req.json())?.target_id;
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  if (!targetId || typeof targetId !== "string") {
    return json({ error: "target_id is required" }, 400);
  }

  // Service-role client: bypasses RLS for the block check + photo lookup.
  const admin = createClient(SUPABASE_URL, SERVICE_KEY);

  // Own photos: nothing to authorize.
  if (targetId !== user.id) {
    const { data: blocked } = await admin
      .from("blocks")
      .select("blocker_id")
      .or(
        `and(blocker_id.eq.${user.id},blocked_id.eq.${targetId}),` +
          `and(blocker_id.eq.${targetId},blocked_id.eq.${user.id})`,
      )
      .limit(1);
    if (blocked && blocked.length > 0) return json({ urls: [] });
  }

  const { data: profile, error: profErr } = await admin
    .from("profiles")
    .select("photos")
    .eq("user_id", targetId)
    .maybeSingle();
  if (profErr) return json({ error: profErr.message }, 500);

  const paths: string[] = profile?.photos ?? [];
  if (paths.length === 0) return json({ urls: [] });

  const { data: signed, error: signErr } = await admin.storage
    .from(BUCKET)
    .createSignedUrls(paths, SIGN_TTL_SECONDS);
  if (signErr) return json({ error: signErr.message }, 500);

  const urls = (signed ?? [])
    .map((s) => s.signedUrl)
    .filter((u): u is string => !!u);

  return json({ urls });
});
