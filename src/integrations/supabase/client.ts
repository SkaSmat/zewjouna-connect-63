import { createClient } from "@supabase/supabase-js";

// Existing ZEWJOUNA Supabase backend (consumed read-only — do not modify schema).
// The publishable (anon) key is safe to ship in the browser; RLS protects all data.
const SUPABASE_URL = "https://yahkxceolwolgglllcbt.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_mhaM9jttRd8R7ktktjxdjw_5zb0uy3s";

export const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storageKey: "zewjouna-auth",
  },
});
