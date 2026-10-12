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
