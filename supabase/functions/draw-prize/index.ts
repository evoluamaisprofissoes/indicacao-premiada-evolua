import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "Método não permitido." }), { status: 405, headers: cors });
  const url = Deno.env.get("SUPABASE_URL")!;
  const publishableKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY")!;
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response(JSON.stringify({ error: "Autenticação necessária." }), { status: 401, headers: cors });

  const client = createClient(url, publishableKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await client.auth.getUser();
  if (userError || !userData.user) return new Response(JSON.stringify({ error: "Sessão inválida." }), { status: 401, headers: cors });

  try {
    const body = await req.json();
    if (!body?.ticket_id) return new Response(JSON.stringify({ error: "Informe o ticket." }), { status: 400, headers: cors });
    const { data, error } = await client.rpc("draw_prize_for_ticket", { p_ticket_id: body.ticket_id });
    if (error) return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: cors });
    return new Response(JSON.stringify(data), { status: 200, headers: cors });
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : "Erro inesperado." }), { status: 500, headers: cors });
  }
});