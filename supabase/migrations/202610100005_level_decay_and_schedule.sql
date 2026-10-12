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
