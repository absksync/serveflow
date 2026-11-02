import { createClient } from "@supabase/supabase-js";

import { env } from "@/lib/env";

/**
 * Browser-side Supabase client.
 *
 * This client runs with the publishable key, so it is only as safe as the
 * database's Row Level Security policies. Every table it touches must have
 * RLS enabled (see database/migrations/).
 */
export const supabase = createClient(
  env.supabaseUrl,
  env.supabasePublishableKey,
);
