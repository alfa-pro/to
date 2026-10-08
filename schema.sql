-- TRYOUTKU: jalankan di Supabase > SQL Editor
create table profiles(id uuid primary key references auth.users on delete cascade, full_name text, whatsapp text, jenjang text, kelas int, sekolah text, role text default 'user', plan text default 'FREE', plan_end timestamptz);
create table tryouts(id serial primary key, title text, jenjang text, kelas int, subject text, difficulty text, duration_min int, access text default 'FREE', published bool default true);
create table questions(id serial primary key, tryout_id int references tryouts on delete cascade, body text, a text, b text, c text, d text, correct char(1), explanation text);
create table attempts(id uuid primary key default gen_random_uuid(), user_id uuid references auth.users default auth.uid(), tryout_id int references tryouts, started_at timestamptz default now(), finished_at timestamptz, answers jsonb default '{}', score int, correct int, wrong int, blank int);
create unique index one_open on attempts(user_id, tryout_id) where finished_at is null;
create index on attempts(user_id, started_at);
create index on questions(tryout_id);

alter table profiles enable row level security; alter table tryouts enable row level security;
alter table questions enable row level security; alter table attempts enable row level security;
create policy own_profile on profiles for select using (id = auth.uid());
create policy own_update on profiles for update using (id = auth.uid());
create policy pub_tryouts on tryouts for select using (published);
create policy own_attempts on attempts for select using (user_id = auth.uid());
-- questions: tanpa policy = tidak bisa dibaca langsung (kunci jawaban aman)
revoke update on profiles from anon, authenticated;
grant update(full_name, whatsapp, jenjang, kelas, sekolah) on profiles to authenticated;
revoke insert, update, delete on attempts from anon, authenticated;

create function plan_rank(p text) returns int language sql immutable as $$ select case p when 'PREMIUM' then 2 when 'BASIC' then 1 else 0 end $$;
create function eff_plan() returns text language sql stable security definer set search_path=public as $$
  select case when plan_end > now() then plan else 'FREE' end from profiles where id = auth.uid() $$;

-- Daftar: profil + trial Premium 3 hari
create function new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into profiles(id, full_name, whatsapp, jenjang, kelas, sekolah, plan, plan_end)
 values(new.id, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'whatsapp', new.raw_user_meta_data->>'jenjang',
  nullif(new.raw_user_meta_data->>'kelas','')::int, new.raw_user_meta_data->>'sekolah', 'PREMIUM', now() + interval '3 days');
 return new; end $$;
create trigger on_signup after insert on auth.users for each row execute function new_user();

create function start_attempt(tid int) returns uuid language plpgsql security definer set search_path=public as $$
declare t tryouts; p text := eff_plan(); used int; lim int; x uuid;
begin
 if auth.uid() is null then raise exception 'Silakan masuk dulu'; end if;
 select * into t from tryouts where id = tid and published;
 if not found then raise exception 'Tryout tidak ditemukan'; end if;
 if plan_rank(t.access) > plan_rank(p) then raise exception 'Upgrade paket untuk membuka tryout ini'; end if;
 select id into x from attempts where user_id = auth.uid() and tryout_id = tid and finished_at is null;
 if x is not null then return x; end if;
 lim := case p when 'FREE' then 3 when 'BASIC' then 20 else 1000000 end;
 select count(*) into used from attempts where user_id = auth.uid() and started_at >= date_trunc('month', now());
 if used >= lim then raise exception 'Kuota tryout bulan ini habis. Upgrade paketmu.'; end if;
 insert into attempts(user_id, tryout_id) values(auth.uid(), tid) returning id into x; return x;
end $$;

create function submit_attempt(aid uuid) returns json language plpgsql security definer set search_path=public as $$
declare r attempts; n int; c int; w int;
begin
 select * into r from attempts where id = aid and user_id = auth.uid() for update;
 if not found then raise exception 'Tidak ditemukan'; end if;
 if r.finished_at is null then
  select count(*), count(*) filter (where r.answers->>q.id::text = q.correct),
   count(*) filter (where r.answers ? q.id::text and r.answers->>q.id::text <> q.correct) into n, c, w from questions q where q.tryout_id = r.tryout_id;
  update attempts set finished_at = now(), correct = c, wrong = w, blank = n-c-w, score = round(100.0*c/greatest(n,1)) where id = aid returning * into r;
 end if;
 return row_to_json(r);
end $$;

create function get_exam(aid uuid) returns json language plpgsql security definer set search_path=public as $$
declare r attempts; t tryouts;
begin
 select * into r from attempts where id = aid and user_id = auth.uid();
 if not found then raise exception 'Tidak ditemukan'; end if;
 select * into t from tryouts where id = r.tryout_id;
 if r.finished_at is null and now() > r.started_at + make_interval(mins => t.duration_min) then
  perform submit_attempt(aid); select * into r from attempts where id = aid; end if;
 return json_build_object('attempt', row_to_json(r), 'tryout', row_to_json(t),
  'left', greatest(0, extract(epoch from r.started_at + make_interval(mins => t.duration_min) - now())::int),
  'questions', (select coalesce(json_agg(json_build_object('id',id,'body',body,'a',a,'b',b,'c',c,'d',d) order by id),'[]') from questions where tryout_id = t.id));
end $$;

create function save_answers(aid uuid, ans jsonb) returns void language sql security definer set search_path=public as $$
 update attempts set answers = ans from tryouts t
 where attempts.id = aid and attempts.user_id = auth.uid() and attempts.finished_at is null
  and t.id = attempts.tryout_id and now() <= attempts.started_at + make_interval(mins => t.duration_min) + interval '10 seconds' $$;

-- Pembahasan hanya terbuka untuk BASIC/PREMIUM (dicek di server)
create function get_review(aid uuid) returns json language plpgsql security definer set search_path=public as $$
declare r attempts; ok bool;
begin
 select * into r from attempts where id = aid and user_id = auth.uid() and finished_at is not null;
 if not found then raise exception 'Tidak ditemukan'; end if;
 ok := plan_rank(eff_plan()) >= 1;
 return json_build_object('unlocked', ok, 'items', (select json_agg(json_build_object('id',id,'body',body,'a',a,'b',b,'c',c,'d',d,
  'correct',correct,'mine',r.answers->>id::text,'explanation',case when ok then explanation end) order by id) from questions where tryout_id = r.tryout_id));
end $$;

create view leaderboard as
 select a.user_id, p.full_name, p.sekolah, max(a.score) score, count(*) tryouts
 from attempts a join profiles p on p.id = a.user_id where a.finished_at is not null group by 1,2,3;
grant select on leaderboard to anon, authenticated;

-- Data demo
insert into tryouts(title,jenjang,kelas,subject,difficulty,duration_min,access) values
('Tryout TKA Matematika Kelas 12','SMA',12,'Matematika','Sedang',60,'FREE'),
('Tryout Bahasa Indonesia','SMA',12,'Bahasa Indonesia','Sedang',60,'BASIC'),
('Tryout Bahasa Inggris','SMA',12,'Bahasa Inggris','Sulit',60,'PREMIUM'),
('Matematika Dasar Kelas 9','SMP',9,'Matematika','Mudah',30,'FREE');
insert into questions(tryout_id,body,a,b,c,d,correct,explanation) values
(1,'Hasil dari 25 × 4 adalah ...','50','75','100','125','c','25 × 4 = 100.'),
(1,'Jika 2x + 6 = 14, maka x = ...','2','4','6','8','b','2x = 8, sehingga x = 4.'),
(1,'Turunan dari f(x) = x² adalah ...','x','2x','x²','2','b','Aturan pangkat: d/dx x² = 2x.'),
(1,'Peluang muncul angka genap pada satu dadu adalah ...','1/6','1/3','1/2','2/3','c','Ada 3 angka genap dari 6 sisi: 3/6 = 1/2.'),
(1,'Nilai dari log₁₀ 1000 adalah ...','1','2','3','10','c','10³ = 1000, jadi log = 3.'),
(4,'Hasil dari 12 + 8 × 2 adalah ...','28','40','20','24','a','Kalikan dulu: 8 × 2 = 16, lalu 12 + 16 = 28.'),
(4,'Keliling persegi dengan sisi 5 cm adalah ...','10 cm','20 cm','25 cm','15 cm','b','4 × 5 = 20 cm.'),
(4,'Hasil dari 3² + 4² adalah ...','14','25','49','7','b','9 + 16 = 25.'),
(2,'Kalimat yang efektif adalah kalimat yang ...','panjang','singkat, jelas, tepat','berbunga-bunga','rumit','b','Kalimat efektif hemat kata dan mudah dipahami.'),
(2,'Antonim kata "gigih" adalah ...','tekun','ulet','mudah menyerah','rajin','c','Gigih = pantang menyerah.'),
(3,'She ___ to school every day.','go','goes','going','gone','b','Subjek tunggal (she) pada simple present memakai verb+s.'),
(3,'They ___ playing football now.','is','am','are','be','c','They + are untuk present continuous.');
