-- SETUP COMPLEMENTAR DO PROJETO INDICAÇÃO PREMIADA EVOLUA
-- O SQL base já foi executado no projeto Supabase existente.
-- Execute este arquivo UMA ÚNICA VEZ no SQL Editor do Supabase.
-- Não execute este arquivo e as migrações individuais em duplicidade.
-- Faça backup antes de aplicar em produção.


-- ============================================================
-- SOURCE: 202610100001_campaign_storage_and_draw.sql
-- ============================================================

-- Complemento para o esquema inicial já executado no Supabase.
-- Execute somente depois de confirmar que as tabelas base profiles/campaigns/prizes/leads/enrollments/tickets/draws existem.
-- Não apaga dados existentes.

create extension if not exists pgcrypto;

-- Compatibilidade: o frontend usa prize_snapshot para exibir o resultado histórico.
alter table public.draws add column if not exists prize_snapshot jsonb;
alter table public.draws add column if not exists ticket_id uuid;
alter table public.draws add column if not exists student_id uuid;
alter table public.draws add column if not exists campaign_id uuid;
alter table public.draws add column if not exists prize_id uuid;
alter table public.draws add column if not exists created_at timestamptz default now();
alter table public.campaigns add column if not exists start_at date;
alter table public.campaigns add column if not exists end_at date;
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='campaigns' and column_name='start_date') then
    execute 'update public.campaigns set start_at = coalesce(start_at, start_date::date)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='campaigns' and column_name='end_date') then
    execute 'update public.campaigns set end_at = coalesce(end_at, end_date::date)';
  end if;
end $$;
alter table public.prizes add column if not exists image_url text;
alter table public.prizes add column if not exists is_consolation boolean not null default false;
alter table public.enrollments add column if not exists eligible_at timestamptz;
alter table public.tickets add column if not exists issue_reason text;

-- Evita premiar estoque já esgotado. A função de sorteio executa com transação Postgres.
create or replace function public.draw_prize_for_ticket(p_ticket_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_ticket public.tickets%rowtype;
  v_prize public.prizes%rowtype;
  v_total numeric;
  v_pick numeric;
  v_running numeric := 0;
  v_snapshot jsonb;
  v_campaign_status text;
  v_campaign_start date;
  v_campaign_end date;
  v_level text;
  v_fallback boolean := false;
begin
  if v_uid is null then
    raise exception 'Você precisa entrar na sua conta.';
  end if;

  select * into v_ticket
  from public.tickets
  where id = p_ticket_id
  for update;

  if not found then raise exception 'Ticket não encontrado.'; end if;
  if v_ticket.student_id <> v_uid and not public.is_admin() then
    raise exception 'Você não tem acesso a este ticket.';
  end if;
  if v_ticket.status <> 'available' then
    raise exception 'Este ticket não está disponível para sorteio.';
  end if;

  select status,start_at,end_at into v_campaign_status,v_campaign_start,v_campaign_end
  from public.campaigns where id = v_ticket.campaign_id;
  if v_campaign_status <> 'active' then
    raise exception 'A campanha não está ativa.';
  end if;
  if (v_campaign_start is not null and current_date < v_campaign_start) or (v_campaign_end is not null and current_date > v_campaign_end) then
    raise exception 'Esta campanha está fora do período de participação.';
  end if;

  select coalesce(current_level, 'explorador') into v_level
  from public.profiles where id = v_ticket.student_id;

  select coalesce(sum(probability_weight), 0) into v_total
  from public.prizes
  where campaign_id = v_ticket.campaign_id
    and active = true
    and stock_awarded < stock_total
    and category in (v_level, 'all')
    and coalesce(is_consolation, false) = false;

  -- Se todos os prêmios regulares desse nível acabaram, recorre aos prêmios de consolação.
  if v_total <= 0 then
    select coalesce(sum(probability_weight), 0) into v_total
    from public.prizes
    where campaign_id = v_ticket.campaign_id
      and active = true
      and stock_awarded < stock_total
      and coalesce(is_consolation, false) = true;
    v_fallback := true;
  end if;

  if coalesce(v_total, 0) <= 0 then
    raise exception 'Não há prêmios disponíveis, incluindo prêmios de consolação. A administração precisa repor o estoque antes de liberar novos sorteios.';
  end if;

  v_pick := random() * v_total;
  for v_prize in
    select * from public.prizes
    where campaign_id = v_ticket.campaign_id
      and active = true
      and stock_awarded < stock_total
      and (
        (v_fallback = true and coalesce(is_consolation, false) = true)
        or
        (v_fallback = false and category in (v_level, 'all') and coalesce(is_consolation, false) = false)
      )
    order by id
    for update
  loop
    v_running := v_running + v_prize.probability_weight;
    if v_pick <= v_running then exit; end if;
  end loop;

  if v_prize.id is null then raise exception 'Não foi possível selecionar um prêmio.'; end if;

  update public.prizes set stock_awarded = stock_awarded + 1 where id = v_prize.id;
  update public.tickets set status = 'used', used_at = now() where id = v_ticket.id;

  v_snapshot := jsonb_build_object(
    'id', v_prize.id, 'name', v_prize.name,
    'description', v_prize.description, 'image_url', v_prize.image_url,
    'category', v_prize.category
  );

  insert into public.draws(ticket_id, student_id, campaign_id, prize_id, prize_snapshot, created_at)
  values (v_ticket.id, v_ticket.student_id, v_ticket.campaign_id, v_prize.id, v_snapshot, now());

  return jsonb_build_object('ticket_id', v_ticket.id, 'prize', v_snapshot);
end;
$$;

revoke all on function public.draw_prize_for_ticket(uuid) from public, anon;
grant execute on function public.draw_prize_for_ticket(uuid) to authenticated;

-- Storage: bucket público apenas para leitura dos banners; uploads e alterações só para administradores.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('campaign-assets', 'campaign-assets', true, 5242880, array['image/png','image/jpeg','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880,
  allowed_mime_types = array['image/png','image/jpeg','image/webp'];

drop policy if exists "campaign assets public read" on storage.objects;
create policy "campaign assets public read"
on storage.objects for select
to anon, authenticated
using (bucket_id = 'campaign-assets');

drop policy if exists "campaign assets admin insert" on storage.objects;
create policy "campaign assets admin insert"
on storage.objects for insert
to authenticated
with check (bucket_id = 'campaign-assets' and public.is_admin());

drop policy if exists "campaign assets admin update" on storage.objects;
create policy "campaign assets admin update"
on storage.objects for update
to authenticated
using (bucket_id = 'campaign-assets' and public.is_admin())
with check (bucket_id = 'campaign-assets' and public.is_admin());

drop policy if exists "campaign assets admin delete" on storage.objects;
create policy "campaign assets admin delete"
on storage.objects for delete
to authenticated
using (bucket_id = 'campaign-assets' and public.is_admin());

-- Segurança adicional para função de sorteio: autenticação e RLS continuam obrigatórias.


-- ============================================================
-- SOURCE: 202610100002_admin_ticket_issuance.sql
-- ============================================================

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

-- ============================================================
-- SOURCE: 202610100003_referral_level_logic.sql
-- ============================================================

-- Regras de nível e histórico de indicações válidas.
-- Não apaga histórico: total_valid_enrollments é contagem acumulada de matrículas válidas.
alter table public.profiles add column if not exists total_valid_enrollments integer not null default 0;
alter table public.profiles add column if not exists level_last_changed_at timestamptz;
alter table public.enrollments add column if not exists valid_for_referral boolean not null default false;
alter table public.enrollments add column if not exists tickets_issued_at timestamptz;

create or replace function public.refresh_student_level(p_student_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total integer;
  v_level text;
  v_last timestamptz;
  v_target text;
begin
  select total_valid_enrollments,current_level,last_valid_referral_at
    into v_total,v_level,v_last
  from public.profiles where id=p_student_id for update;
  if not found then return; end if;
  v_target := case when v_total>=15 then 'elite' when v_total>=6 then 'conquistador' else 'explorador' end;
  -- Redução de nível: no máximo um nível a cada 30 dias sem matrícula válida.
  if v_last is not null and now() >= v_last + interval '30 days' then
    if v_level='elite' then v_target:='conquistador';
    elsif v_level='conquistador' then v_target:='explorador';
    end if;
  end if;
  update public.profiles set current_level=v_target,level_last_changed_at=now() where id=p_student_id;
end;
$$;
revoke all on function public.refresh_student_level(uuid) from public, anon, authenticated;
-- Função interna invocada por tarefas administrativas futuras, não exposta como RPC pública.


-- ============================================================
-- SOURCE: 202610100004_process_eligible_enrollments.sql
-- ============================================================

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


-- ============================================================
-- SOURCE: 202610100005_level_decay_and_schedule.sql
-- ============================================================

-- Regressão automática de nível: no máximo um nível a cada 30 dias sem matrícula válida.
create or replace function public.apply_student_level_decay()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles%rowtype;
  v_new_level text;
  v_changed integer := 0;
begin
  for v_profile in
    select * from public.profiles
    where last_valid_referral_at is not null
      and last_valid_referral_at <= now() - interval '30 days'
      and (level_last_changed_at is null or level_last_changed_at <= now() - interval '30 days')
      and current_level in ('elite','conquistador')
    for update skip locked
  loop
    v_new_level := case when v_profile.current_level='elite' then 'conquistador' else 'explorador' end;
    update public.profiles set current_level=v_new_level,level_last_changed_at=now() where id=v_profile.id;
    v_changed := v_changed + 1;
  end loop;
  return v_changed;
end;
$$;
revoke all on function public.apply_student_level_decay() from public, anon, authenticated;

-- Supabase oferece pg_cron em projetos compatíveis. Se a extensão não estiver habilitada,
-- habilite-a no Dashboard e execute este trecho novamente.
create extension if not exists pg_cron;
do $$
declare j record;
begin
  for j in select jobid from cron.job where jobname in ('evolua-process-eligible-enrollments','evolua-level-decay-daily') loop
    perform cron.unschedule(j.jobid);
  end loop;
end $$;
select cron.schedule('evolua-process-eligible-enrollments','*/15 * * * *', $$select public.process_eligible_enrollments_internal();$$);
select cron.schedule('evolua-level-decay-daily','20 7 * * *', $$select public.apply_student_level_decay();$$);
