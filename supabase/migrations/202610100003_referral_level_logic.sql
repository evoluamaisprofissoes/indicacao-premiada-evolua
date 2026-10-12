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
