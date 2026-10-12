-- Emite tickets após a janela de 7 dias, com proteção transacional e sem limitar uma matrícula a um ticket.
-- O processo interno é executável pelo banco/agendador; a função pública exige administrador.
do $$
declare r record;
begin
  for r in
    select i.relname as index_name
    from pg_index x
    join pg_class t on t.oid=x.indrelid
    join pg_class i on i.oid=x.indexrelid
    join pg_namespace n on n.oid=t.relnamespace
    where n.nspname='public' and t.relname='tickets' and x.indisunique
      and pg_get_indexdef(x.indexrelid) ilike '%enrollment_id%'
  loop
    execute format('drop index if exists public.%I', r.index_name);
  end loop;
end $$;
create index if not exists tickets_enrollment_id_idx on public.tickets(enrollment_id);

create or replace function public.process_eligible_enrollments_internal()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enrollment public.enrollments%rowtype;
  v_ticket_id uuid;
  v_ticket_ids uuid[];
  v_count integer := 0;
  v_issued integer := 0;
  v_qty integer;
  v_total integer;
  v_level text;
  v_actor uuid;
  v_fallback_stock integer;
  v_outstanding integer;
begin
  v_actor := coalesce(auth.uid(), (select id from public.profiles where role='admin' order by created_at asc limit 1));
  if v_actor is null then raise exception 'Cadastre ao menos um administrador antes de processar matrículas.'; end if;

  for v_enrollment in
    select * from public.enrollments
    where status='confirmed'
      and eligible_at is not null and eligible_at <= now()
      and tickets_issued_at is null
    order by eligible_at
    for update skip locked
  loop
    v_qty := greatest(1, least(coalesce(v_enrollment.ticket_quantity,1),100));
    select coalesce(sum(stock_total-stock_awarded),0) into v_fallback_stock from public.prizes where campaign_id=v_enrollment.campaign_id and active=true and is_consolation=true and stock_awarded<stock_total;
    select count(*) into v_outstanding from public.tickets where campaign_id=v_enrollment.campaign_id and status='available';
    if v_fallback_stock < v_outstanding + v_qty then
      raise exception 'Estoque de consolação insuficiente para liberar tickets da campanha %. Reponha o estoque e tente novamente.', v_enrollment.campaign_id;
    end if;
    v_ticket_ids := array[]::uuid[];
    for i in 1..v_qty loop
      insert into public.tickets(student_id,campaign_id,enrollment_id,status,issued_by,issue_reason)
      values(v_enrollment.student_id,v_enrollment.campaign_id,v_enrollment.id,'available',v_actor,'Matrícula validada após 7 dias')
      returning id into v_ticket_id;
      v_ticket_ids := array_append(v_ticket_ids,v_ticket_id);
    end loop;

    update public.enrollments set tickets_issued_at=now(), valid_for_referral=true where id=v_enrollment.id;

    select coalesce(total_valid_enrollments,0)+1 into v_total
      from public.profiles where id=v_enrollment.student_id for update;
    if found then
      v_level := case when v_total >= 15 then 'elite' when v_total >= 6 then 'conquistador' else 'explorador' end;
      update public.profiles
        set total_valid_enrollments=v_total,
            current_level=v_level,
            last_valid_referral_at=now(),
            level_last_changed_at=now()
        where id=v_enrollment.student_id;
    end if;

    insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
    values(v_actor,'eligible_enrollment_ticket_issue','enrollment',v_enrollment.id,
      jsonb_build_object('ticket_ids',v_ticket_ids,'quantity',v_qty,'student_id',v_enrollment.student_id,'campaign_id',v_enrollment.campaign_id));

    v_count := v_count + 1;
    v_issued := v_issued + v_qty;
  end loop;
  return jsonb_build_object('enrollments_processed',v_count,'tickets_issued',v_issued);
end;
$$;
revoke all on function public.process_eligible_enrollments_internal() from public, anon, authenticated;

create or replace function public.admin_process_eligible_enrollments()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Apenas administradores podem processar matrículas elegíveis.';
  end if;
  return public.process_eligible_enrollments_internal();
end;
$$;
revoke all on function public.admin_process_eligible_enrollments() from public, anon;
grant execute on function public.admin_process_eligible_enrollments() to authenticated;
