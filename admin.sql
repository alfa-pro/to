-- TRYOUTKU admin: jalankan SETELAH schema.sql
create function is_admin() returns bool language sql stable security definer set search_path=public as $$
  select coalesce((select role = 'admin' from profiles where id = auth.uid()), false) $$;

-- Admin boleh kelola tryout & soal (termasuk yang belum publish)
create policy adm_tryouts on tryouts for all using (is_admin()) with check (is_admin());
create policy adm_questions on questions for all using (is_admin()) with check (is_admin());
create policy adm_profiles on profiles for select using (is_admin());
create policy adm_attempts on attempts for select using (is_admin());

create function admin_stats() returns json language plpgsql security definer set search_path=public as $$
begin
 if not is_admin() then raise exception 'Akses ditolak'; end if;
 return json_build_object(
  'users', (select count(*) from profiles),
  'paid', (select count(*) from profiles where plan <> 'FREE' and plan_end > now()),
  'attempts', (select count(*) from attempts where finished_at is not null),
  'questions', (select count(*) from questions),
  'tryouts', (select count(*) from tryouts),
  'daily', (select json_agg(json_build_object('d', to_char(d,'DD/MM'), 'n', coalesce(c,0)) order by d)
    from generate_series(current_date - 6, current_date, interval '1 day') d
    left join (select finished_at::date f, count(*) c from attempts where finished_at is not null group by 1) a on a.f = d::date));
end $$;

create function admin_users() returns json language plpgsql security definer set search_path=public as $$
begin
 if not is_admin() then raise exception 'Akses ditolak'; end if;
 return (select coalesce(json_agg(x), '[]') from (
  select p.id, u.email, p.full_name as name, p.sekolah, p.plan, p.plan_end, case when p.plan_end > now() then p.plan else 'FREE' end as eff
  from profiles p join auth.users u on u.id = p.id order by u.created_at desc limit 200) x);
end $$;

-- Aktifkan / ubah paket user (mis. setelah pembayaran dikonfirmasi)
create function admin_set_plan(uid uuid, p text, days int) returns void language plpgsql security definer set search_path=public as $$
begin
 if not is_admin() then raise exception 'Akses ditolak'; end if;
 if p not in ('FREE','BASIC','PREMIUM') then raise exception 'Paket tidak valid'; end if;
 update profiles set plan = p, plan_end = case when p = 'FREE' then null else now() + make_interval(days => days) end where id = uid;
end $$;

-- Jadikan dirimu admin (ganti email):
-- update profiles set role='admin' where id=(select id from auth.users where email='emailkamu@contoh.com');
