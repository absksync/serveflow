/**
 * Public (browser-safe) environment configuration.
 *
 * NEXT_PUBLIC_* values are inlined into the JavaScript bundle that every
 * visitor downloads. Only the Supabase URL and the *publishable* key may live
 * here. A secret / service_role key would bypass Row Level Security for
 * anyone who opens DevTools, so we refuse to start if one is detected.
 */

function looksLikeSecretKey(key: string): boolean {
  // New-format Supabase secret keys.
  if (key.startsWith("sb_secret_")) return true;

  // Legacy JWT keys: decode the payload and check the role claim.
  const parts = key.split(".");
  if (parts.length === 3) {
    try {
      const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
      const payload = JSON.parse(atob(b64)) as { role?: string };
      return payload.role === "service_role";
    } catch {
      return false;
    }
  }
  return false;
}

function readPublicEnv() {
  // Must be referenced literally so Next.js can inline them at build time.
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const supabasePublishableKey =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

  if (!supabaseUrl || !supabasePublishableKey) {
    throw new Error(
      "Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY. " +
        "Copy frontend/.env.example to frontend/.env.local and fill it in.",
    );
  }

  let parsed: URL;
  try {
    parsed = new URL(supabaseUrl);
  } catch {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL is not a valid URL.");
  }
  const isLocal =
    parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1";
  if (parsed.protocol !== "https:" && !isLocal) {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL must use https.");
  }

  if (looksLikeSecretKey(supabasePublishableKey)) {
    throw new Error(
      "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY contains a SECRET/service_role key. " +
        "Never expose it to the browser. Use the publishable key, and rotate " +
        "the secret key in the Supabase dashboard if it was ever committed or deployed.",
    );
  }

  return { supabaseUrl, supabasePublishableKey } as const;
}

export const env = readPublicEnv();
