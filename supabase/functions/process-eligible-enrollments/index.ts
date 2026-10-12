import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Content-Type":"application/json"};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response(JSON.stringify({error:"Método não permitido."}), {status:405,headers:cors});
  const url = Deno.env.get("SUPABASE_URL")!;
  const key = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY")!;
  const auth = req.headers.get("Authorization");
  if (!auth) return new Response(JSON.stringify({error:"Autenticação necessária."}), {status:401,headers:cors});
  const client = createClient(url,key,{global:{headers:{Authorization:auth}}});
  const {data:userData,error:userError}=await client.auth.getUser();
  if(userError||!userData.user) return new Response(JSON.stringify({error:"Sessão inválida."}),{status:401,headers:cors});
  const {data:profile,error:profileError}=await client.from("profiles").select("role").eq("id",userData.user.id).single();
  if(profileError||profile?.role!=="admin") return new Response(JSON.stringify({error:"Apenas administradores podem processar matrículas."}),{status:403,headers:cors});
  const {data,error}=await client.rpc("admin_process_eligible_enrollments");
  if(error) return new Response(JSON.stringify({error:error.message}),{status:400,headers:cors});
  return new Response(JSON.stringify(data),{status:200,headers:cors});
});
