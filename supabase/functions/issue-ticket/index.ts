import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Content-Type":"application/json"};

Deno.serve(async (req) => {
  if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
  if(req.method!=="POST") return new Response(JSON.stringify({error:"Método não permitido."}),{status:405,headers:cors});
  const url=Deno.env.get("SUPABASE_URL")!;
  const key=Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY")!;
  const auth=req.headers.get("Authorization");
  if(!auth) return new Response(JSON.stringify({error:"Autenticação necessária."}),{status:401,headers:cors});
  const client=createClient(url,key,{global:{headers:{Authorization:auth}}});
  const {data:ud,error:ue}=await client.auth.getUser();
  if(ue||!ud.user) return new Response(JSON.stringify({error:"Sessão inválida."}),{status:401,headers:cors});
  const {data:profile}=await client.from("profiles").select("role").eq("id",ud.user.id).single();
  if(profile?.role!=="admin") return new Response(JSON.stringify({error:"Apenas administradores podem liberar tickets manualmente."}),{status:403,headers:cors});
  try {
    const body=await req.json();
    const {student_id,campaign_id,quantity=1,reason="Liberação manual administrativa"}=body||{};
    if(!student_id||!campaign_id||!Number.isInteger(quantity)||quantity<1||quantity>100) return new Response(JSON.stringify({error:"Informe aluno, campanha e quantidade entre 1 e 100."}),{status:400,headers:cors});
    const {data,error}=await client.rpc("admin_issue_tickets",{p_student_id:student_id,p_campaign_id:campaign_id,p_quantity:quantity,p_reason:reason});
    if(error) return new Response(JSON.stringify({error:error.message}),{status:400,headers:cors});
    return new Response(JSON.stringify({tickets:data}),{status:200,headers:cors});
  } catch(error) {
    return new Response(JSON.stringify({error:error instanceof Error?error.message:"Erro inesperado."}),{status:500,headers:cors});
  }
});