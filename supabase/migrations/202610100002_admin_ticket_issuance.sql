-- Função transacional de emissão manual, apenas para administradores.
create or replace function public.admin_issue_tickets(
  p_student_id uuid,
  p_campaign_id uuid,
  p_quantity integer default 1,
  p_reason text default 'Liberação manual administrativa'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_ids uuid[] := array[]::uuid[];
  v_status text;
  v_fallback_stock integer;
  v_outstanding integer;
  i integer;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Apenas administradores podem liberar tickets.';
  end if;
  if p_quantity < 1 or p_quantity > 100 then raise exception 'Quantidade inválida.'; end if;
  select status into v_status from public.campaigns where id=p_campaign_id;
  if v_status is null then raise exception 'Campanha não encontrada.'; end if;
  if v_status not in ('active','draft','paused') then raise exception 'Campanha encerrada não recebe tickets.'; end if;
  if not exists(select 1 from public.profiles where id=p_student_id) then raise exception 'Aluno não encontrado.'; end if;
  select coalesce(sum(stock_total-stock_awarded),0) into v_fallback_stock from public.prizes where campaign_id=p_campaign_id and active=true and is_consolation=true and stock_awarded<stock_total;
  select count(*) into v_outstanding from public.tickets where campaign_id=p_campaign_id and status='available';
  if v_fallback_stock < v_outstanding + p_quantity then raise exception 'Estoque de prêmios de consolação insuficiente para garantir prêmio a todos os tickets. Reponha o estoque antes de liberar.'; end if;
  for i in 1..p_quantity loop
    insert into public.tickets(student_id,campaign_id,status,issued_by,issue_reason)
    values(p_student_id,p_campaign_id,'available',auth.uid(),left(coalesce(p_reason,'Liberação manual'),250))
    returning id into v_id;
    v_ids := array_append(v_ids,v_id);
  end loop;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'manual_ticket_issue','ticket',v_ids[1],jsonb_build_object('student_id',p_student_id,'campaign_id',p_campaign_id,'quantity',p_quantity,'ticket_ids',v_ids));
  return jsonb_build_object('ticket_ids',to_jsonb(v_ids),'quantity',p_quantity);
end;
$$;
revoke all on function public.admin_issue_tickets(uuid,uuid,integer,text) from public, anon;
grant execute on function public.admin_issue_tickets(uuid,uuid,integer,text) to authenticated;