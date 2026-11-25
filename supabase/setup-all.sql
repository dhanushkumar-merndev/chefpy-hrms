-- Chefpy HRMS: run in Supabase > SQL Editor. Creates/updates only hrms_* tables and functions. Safe to run again.
-- Chefpy HRMS: tables (locked with RLS) + SECURITY DEFINER functions (the only way in).
-- Everything is prefixed hrms_ so nothing else in the project is touched.

create extension if not exists pgcrypto with schema extensions;

-- ---------- tables ----------
create table if not exists public.hrms_settings (
  id int primary key default 1 check (id = 1),
  inc numeric not null default 1,
  rzp_balance numeric not null default 850000,
  rzp_acct text not null default 'RazorpayX current account ••7788',
  golive date not null default ((now() at time zone 'Asia/Kolkata')::date),
  late_after int not null default 585,
  updated_at timestamptz not null default now()
);

create table if not exists public.hrms_employees (
  id text primary key,
  name text not null,
  role text not null check (role in ('admin','hr','manager','sales','ops')),
  dept text not null default '',
  title text not null default '',
  salary numeric not null default 0 check (salary >= 0),
  mgr text references public.hrms_employees(id),
  phone text not null default '',
  bank text not null default '',
  pw_hash text not null,
  joined date not null default ((now() at time zone 'Asia/Kolkata')::date),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.hrms_sessions (
  token uuid primary key default gen_random_uuid(),
  emp text not null references public.hrms_employees(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days'
);
create index if not exists hrms_sessions_emp on public.hrms_sessions(emp);

create table if not exists public.hrms_days (
  emp text not null references public.hrms_employees(id) on delete cascade,
  day date not null,
  in_at timestamptz not null,
  out_at timestamptz,
  last_seen timestamptz not null default now(),
  primary key (emp, day)
);

create table if not exists public.hrms_segments (
  id bigserial primary key,
  emp text not null references public.hrms_employees(id) on delete cascade,
  day date not null,
  kind text not null check (kind in ('work','break','idle')),
  start_at timestamptz not null,
  end_at timestamptz
);
create index if not exists hrms_segments_emp_day on public.hrms_segments(emp, day);

create table if not exists public.hrms_calls (
  id bigserial primary key,
  emp text not null references public.hrms_employees(id) on delete cascade,
  at timestamptz not null default now(),
  day date not null default ((now() at time zone 'Asia/Kolkata')::date),
  lead text not null,
  phone text not null default '',
  outcome text not null check (outcome in ('Connected','No answer','Callback','Converted')),
  dur_sec int not null default 0 check (dur_sec >= 0),
  rev numeric not null default 0 check (rev >= 0),
  note text not null default ''
);
create index if not exists hrms_calls_emp_day on public.hrms_calls(emp, day);

create table if not exists public.hrms_tasks (
  id bigserial primary key,
  title text not null,
  descr text not null default '',
  to_emp text not null references public.hrms_employees(id) on delete cascade,
  by_emp text not null references public.hrms_employees(id) on delete cascade,
  due date not null,
  pri text not null default 'Medium' check (pri in ('High','Medium','Low')),
  st text not null default 'todo' check (st in ('todo','doing','done')),
  created_at timestamptz not null default now()
);

create table if not exists public.hrms_leaves (
  id bigserial primary key,
  emp text not null references public.hrms_employees(id) on delete cascade,
  type text not null check (type in ('Casual','Sick','Earned')),
  from_d date not null,
  to_d date not null,
  reason text not null default '',
  st text not null default 'pending' check (st in ('pending','approved','rejected')),
  applied date not null default ((now() at time zone 'Asia/Kolkata')::date),
  by_emp text references public.hrms_employees(id),
  check (to_d >= from_d)
);

create table if not exists public.hrms_targets (
  emp text primary key references public.hrms_employees(id) on delete cascade,
  calls int not null default 900, talk int not null default 2400,
  conv int not null default 24, rev numeric not null default 400000
);

create table if not exists public.hrms_adj (
  id bigserial primary key,
  emp text not null references public.hrms_employees(id) on delete cascade,
  ym text not null,
  amt numeric not null,
  reason text not null,
  by_emp text references public.hrms_employees(id),
  at timestamptz not null default now()
);

create table if not exists public.hrms_payouts (
  id text primary key,
  emp text not null references public.hrms_employees(id) on delete cascade,
  ym text not null,
  label text not null,
  amt numeric not null check (amt > 0),
  mode text not null,
  to_acct text not null,
  st text not null default 'processing' check (st in ('processing','processed')),
  at timestamptz not null default now(),
  done_at timestamptz,
  by_emp text references public.hrms_employees(id),
  utr text
);
create unique index if not exists hrms_payouts_once on public.hrms_payouts(emp, ym);

create table if not exists public.hrms_notes (
  id bigserial primary key,
  to_emp text not null references public.hrms_employees(id) on delete cascade,
  at timestamptz not null default now(),
  msg text not null,
  view text not null default 'dash',
  read boolean not null default false
);
create index if not exists hrms_notes_to on public.hrms_notes(to_emp, at desc);

-- Lock every table: no direct access for anon/authenticated; only the functions below.
do $$ declare t text; begin
  foreach t in array array['hrms_settings','hrms_employees','hrms_sessions','hrms_days','hrms_segments','hrms_calls','hrms_tasks','hrms_leaves','hrms_targets','hrms_adj','hrms_payouts','hrms_notes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ---------- helpers (not callable from the browser) ----------
create or replace function public.hrms_today() returns date language sql stable
set search_path = public as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

create or replace function public.hrms_me(p_token uuid) returns public.hrms_employees
language plpgsql stable security definer set search_path = public as $$
declare e public.hrms_employees;
begin
  select x.* into e from hrms_sessions s join hrms_employees x on x.id = s.emp
   where s.token = p_token and s.expires_at > now() and x.active;
  if e.id is null then raise exception 'Your session has ended. Please sign in again.' using errcode = '28000'; end if;
  return e;
end $$;

create or replace function public.hrms_note(p_to text, p_msg text, p_view text) returns void
language sql security definer set search_path = public as $$
  insert into hrms_notes(to_emp, msg, view) values (p_to, p_msg, p_view) $$;

create or replace function public.hrms_scope(p_me public.hrms_employees) returns setof text
language sql stable security definer set search_path = public as $$
  select id from hrms_employees
   where active and (p_me.role in ('admin','hr') or id = p_me.id or (p_me.role = 'manager' and mgr = p_me.id)) $$;

create or replace function public.hrms_fmt_inr(n numeric) returns text language sql immutable set search_path = public as $$
  select '₹' || to_char(round(n), 'FM99,99,99,99,999') $$;

-- close any open segment for emp at p_at
create or replace function public.hrms_close_open(p_emp text, p_at timestamptz) returns void
language sql security definer set search_path = public as $$
  update hrms_segments set end_at = greatest(start_at, p_at) where emp = p_emp and end_at is null $$;

-- ---------- auth ----------
create or replace function public.hrms_login(p_id text, p_pw text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare e public.hrms_employees; t uuid;
begin
  select * into e from hrms_employees where id = upper(trim(p_id)) and active;
  if e.id is null or e.pw_hash <> extensions.crypt(p_pw, e.pw_hash) then
    perform pg_sleep(0.4);
    raise exception 'Wrong employee ID or password';
  end if;
  delete from hrms_sessions where emp = e.id and expires_at < now();
  insert into hrms_sessions(emp) values (e.id) returning token into t;
  return json_build_object('token', t, 'id', e.id, 'name', e.name, 'role', e.role);
end $$;

create or replace function public.hrms_logout(p_token uuid) returns void
language sql security definer set search_path = public as $$ delete from hrms_sessions where token = p_token $$;

create or replace function public.hrms_change_password(p_token uuid, p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare e public.hrms_employees := hrms_me(p_token);
begin
  if e.pw_hash <> extensions.crypt(p_old, e.pw_hash) then raise exception 'Current password is wrong'; end if;
  if length(p_new) < 6 then raise exception 'New password must be at least 6 characters'; end if;
  update hrms_employees set pw_hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where id = e.id;
  delete from hrms_sessions where emp = e.id and token <> p_token;
end $$;

create or replace function public.hrms_reset_password(p_token uuid, p_emp text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare e public.hrms_employees := hrms_me(p_token);
begin
  if e.role <> 'admin' then raise exception 'Only Admin can change another person''s password'; end if;
  if length(p_new) < 6 then raise exception 'Password must be at least 6 characters'; end if;
  update hrms_employees set pw_hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where id = p_emp;
  delete from hrms_sessions where emp = p_emp;
  perform hrms_note(p_emp, e.name || ' reset your password. Use the new one to sign in.', 'dash');
end $$;

-- ---------- everything the signed-in person may see ----------
create or replace function public.hrms_data(p_token uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  e public.hrms_employees := hrms_me(p_token);
  td date := hrms_today();
  since date := (date_trunc('month', hrms_today()) - interval '1 month')::date;
  boss boolean := e.role in ('admin','hr');
  r json;
begin
  -- settle test-mode payouts a few seconds after they were sent
  with done as (
    update hrms_payouts set st = 'processed', done_at = now(),
      utr = lpad((floor(random()*1e12))::bigint::text, 12, '1')
     where st = 'processing' and at < now() - interval '3 seconds' returning *)
  insert into hrms_notes(to_emp, msg, view)
    select emp, 'Your ' || label || ' salary of ' || hrms_fmt_inr(amt) || ' was credited to ' || to_acct ||
           ' through Razorpay (' || mode || ', UTR ' || utr || ').', 'payslip' from done
    union all
    select by_emp, 'Payout to ' || (select name from hrms_employees where id = done.emp) || ' processed: ' ||
           hrms_fmt_inr(amt) || ', UTR ' || utr || '.', 'payroll' from done where by_emp is not null and by_emp <> emp;

  select json_build_object(
    'me', e.id,
    'today', td,
    'now', now(),
    'settings', (select json_build_object('inc', inc, 'balance', rzp_balance, 'acct', rzp_acct, 'golive', golive, 'late', late_after) from hrms_settings where id = 1),
    'employees', (select coalesce(json_agg(json_build_object(
        'id', x.id, 'name', x.name, 'role', x.role, 'dept', x.dept, 'title', x.title, 'mgr', x.mgr, 'phone', x.phone, 'joined', x.joined,
        'salary', case when boss or x.id = e.id then x.salary end,
        'bank', case when boss or x.id = e.id then x.bank end) order by x.id), '[]') from hrms_employees x where x.active),
    'today_days', (select coalesce(json_agg(json_build_object('emp', d.emp, 'in', d.in_at, 'out', d.out_at, 'seen', d.last_seen,
        'segs', (select coalesce(json_agg(json_build_object('t', s.kind, 's', s.start_at, 'e', s.end_at) order by s.start_at), '[]')
                   from hrms_segments s where s.emp = d.emp and s.day = d.day))), '[]')
        from hrms_days d where d.day = td and d.emp in (select hrms_scope(e))),
    'past_days', (select coalesce(json_agg(json_build_object('emp', d.emp, 'day', d.day, 'in', d.in_at,
        'out', coalesce(d.out_at, (select max(coalesce(s.end_at, d.last_seen)) from hrms_segments s where s.emp = d.emp and s.day = d.day), d.last_seen),
        'work', (select coalesce(sum(extract(epoch from coalesce(s.end_at, d.last_seen) - s.start_at)), 0)/60 from hrms_segments s where s.emp = d.emp and s.day = d.day and s.kind = 'work'),
        'brk',  (select coalesce(sum(extract(epoch from coalesce(s.end_at, d.last_seen) - s.start_at)), 0)/60 from hrms_segments s where s.emp = d.emp and s.day = d.day and s.kind = 'break'),
        'idle', (select coalesce(sum(extract(epoch from coalesce(s.end_at, d.last_seen) - s.start_at)), 0)/60 from hrms_segments s where s.emp = d.emp and s.day = d.day and s.kind = 'idle'))), '[]')
        from hrms_days d where d.day < td and d.day >= since and d.emp in (select hrms_scope(e))),
    'calls_today', (select coalesce(json_agg(json_build_object('id', c.id, 'emp', c.emp, 'at', c.at, 'lead', c.lead, 'phone', c.phone,
        'out', c.outcome, 'dur', c.dur_sec, 'rev', c.rev, 'note', c.note) order by c.at desc), '[]')
        from hrms_calls c where c.day = td and c.emp in (select hrms_scope(e))),
    'calls_daily', (select coalesce(json_agg(json_build_object('emp', emp, 'day', day, 'calls', n, 'talk', talk, 'conv', conv, 'rev', rev)), '[]') from (
        select c.emp, c.day, count(*) n, sum(c.dur_sec)/60.0 talk, count(*) filter (where c.outcome = 'Converted') conv, sum(c.rev) rev
          from hrms_calls c where c.day < td and c.day >= since and c.emp in (select hrms_scope(e)) group by c.emp, c.day) q),
    'tasks', (select coalesce(json_agg(json_build_object('id', t.id, 'title', t.title, 'desc', t.descr, 'to', t.to_emp, 'by', t.by_emp,
        'due', t.due, 'pri', t.pri, 'st', t.st) order by t.created_at desc), '[]')
        from hrms_tasks t where t.to_emp in (select hrms_scope(e)) or t.by_emp = e.id),
    'leaves', (select coalesce(json_agg(json_build_object('id', l.id, 'emp', l.emp, 'type', l.type, 'from', l.from_d, 'to', l.to_d,
        'reason', l.reason, 'st', l.st, 'applied', l.applied, 'by', l.by_emp) order by l.id desc), '[]')
        from hrms_leaves l where l.emp in (select hrms_scope(e))),
    'targets', (select coalesce(json_object_agg(t.emp, json_build_object('calls', t.calls, 'talk', t.talk, 'conv', t.conv, 'rev', t.rev)), '{}')
        from hrms_targets t where t.emp in (select hrms_scope(e))),
    'adj', (select coalesce(json_agg(json_build_object('id', a.id, 'emp', a.emp, 'ym', a.ym, 'amt', a.amt, 'reason', a.reason) order by a.at), '[]')
        from hrms_adj a where boss or a.emp = e.id),
    'payouts', (select coalesce(json_agg(json_build_object('id', p.id, 'emp', p.emp, 'ym', p.ym, 'label', p.label, 'amt', p.amt, 'mode', p.mode,
        'to', p.to_acct, 'st', p.st, 'at', p.at, 'utr', p.utr, 'by', p.by_emp) order by p.at desc), '[]')
        from hrms_payouts p where boss or p.emp = e.id),
    'notes', (select coalesce(json_agg(json_build_object('id', n.id, 'at', n.at, 'msg', n.msg, 'view', n.view, 'read', n.read) order by n.at desc), '[]')
        from (select * from hrms_notes where to_emp = e.id order by at desc limit 100) n)
  ) into r;
  return r;
end $$;

-- ---------- work day ----------
create or replace function public.hrms_checkin(p_token uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token); td date := hrms_today(); late int; mins int; h text;
begin
  if exists (select 1 from hrms_days where emp = e.id and day = td) then raise exception 'You have already checked in today'; end if;
  perform hrms_close_open(e.id, now());
  insert into hrms_days(emp, day, in_at, last_seen) values (e.id, td, now(), now());
  insert into hrms_segments(emp, day, kind, start_at) values (e.id, td, 'work', now());
  select late_after into late from hrms_settings where id = 1;
  mins := extract(hour from now() at time zone 'Asia/Kolkata') * 60 + extract(minute from now() at time zone 'Asia/Kolkata');
  if mins > late then
    h := to_char(now() at time zone 'Asia/Kolkata', 'FMHH12:MI am');
    perform hrms_note(x.id, e.name || ' checked in late at ' || h || '.', 'attendance')
       from hrms_employees x where x.active and x.id <> e.id and (x.role = 'hr' or (x.id = e.mgr and x.role = 'manager'));
  end if;
end $$;

-- p_kind: work | break | idle ; p_at lets the app back-date idle to the last activity
create or replace function public.hrms_state(p_token uuid, p_kind text, p_at timestamptz default null) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token); td date := hrms_today(); d public.hrms_days; t timestamptz;
begin
  if p_kind not in ('work','break','idle') then raise exception 'Unknown state'; end if;
  select * into d from hrms_days where emp = e.id and day = td;
  if d.emp is null then raise exception 'Check in first'; end if;
  if d.out_at is not null then raise exception 'You have already checked out today'; end if;
  t := least(now(), greatest(coalesce(p_at, now()), d.in_at, coalesce((select max(start_at) from hrms_segments where emp = e.id and day = td), d.in_at)));
  if (select kind from hrms_segments where emp = e.id and end_at is null order by start_at desc limit 1) = p_kind then return; end if;
  perform hrms_close_open(e.id, t);
  insert into hrms_segments(emp, day, kind, start_at) values (e.id, td, p_kind, t);
  update hrms_days set last_seen = now() where emp = e.id and day = td;
end $$;

-- heartbeat while the app is open; a gap over 5 minutes (app closed) becomes idle time
create or replace function public.hrms_ping(p_token uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token); td date := hrms_today(); d public.hrms_days; open_kind text;
begin
  select * into d from hrms_days where emp = e.id and day = td;
  if d.emp is null or d.out_at is not null then return; end if;
  select kind into open_kind from hrms_segments where emp = e.id and day = td and end_at is null order by start_at desc limit 1;
  if open_kind = 'work' and d.last_seen < now() - interval '5 minutes' then
    perform hrms_close_open(e.id, d.last_seen);
    insert into hrms_segments(emp, day, kind, start_at, end_at) values (e.id, td, 'idle', d.last_seen, now());
    insert into hrms_segments(emp, day, kind, start_at) values (e.id, td, 'work', now());
  end if;
  update hrms_days set last_seen = now() where emp = e.id and day = td;
end $$;

create or replace function public.hrms_checkout(p_token uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token); td date := hrms_today();
begin
  if not exists (select 1 from hrms_days where emp = e.id and day = td and out_at is null) then raise exception 'You are not checked in'; end if;
  perform hrms_close_open(e.id, now());
  update hrms_days set out_at = now(), last_seen = now() where emp = e.id and day = td;
end $$;

-- ---------- calls ----------
create or replace function public.hrms_log_call(p_token uuid, p_lead text, p_phone text, p_out text, p_dur int, p_rev numeric, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token);
begin
  if coalesce(trim(p_lead), '') = '' then raise exception 'Customer name is required'; end if;
  insert into hrms_calls(emp, lead, phone, outcome, dur_sec, rev, note)
  values (e.id, left(trim(p_lead), 80), left(coalesce(p_phone, ''), 20), p_out,
          case when p_out = 'No answer' then 0 else greatest(0, coalesce(p_dur, 0)) end,
          case when p_out = 'Converted' then greatest(0, coalesce(p_rev, 0)) else 0 end, left(coalesce(p_note, ''), 120));
  if p_out = 'Converted' and e.mgr is not null then
    perform hrms_note(e.mgr, e.name || ' booked ' || hrms_fmt_inr(coalesce(p_rev, 0)) || ' with ' || trim(p_lead) || '.', 'sales');
  end if;
end $$;

-- ---------- leave ----------
create or replace function public.hrms_workdays(a date, b date) returns int language sql immutable set search_path = public as $$
  select count(*)::int from generate_series(a, b, interval '1 day') g where extract(dow from g) <> 0 $$;

create or replace function public.hrms_apply_leave(p_token uuid, p_type text, p_from date, p_to date, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token); n int; quota int; used int;
begin
  if p_to < p_from then raise exception 'End date is before start date'; end if;
  if p_from < hrms_today() then raise exception 'Leave cannot start in the past'; end if;
  n := hrms_workdays(p_from, p_to);
  quota := case p_type when 'Casual' then 8 when 'Sick' then 6 when 'Earned' then 12 end;
  if quota is null then raise exception 'Unknown leave type'; end if;
  select coalesce(sum(hrms_workdays(from_d, to_d)), 0) into used from hrms_leaves
   where emp = e.id and type = p_type and st in ('approved','pending') and extract(year from from_d) = extract(year from p_from);
  if used + n > quota then raise exception 'Not enough % leave left', lower(p_type); end if;
  insert into hrms_leaves(emp, type, from_d, to_d, reason, st, by_emp)
  values (e.id, p_type, p_from, p_to, left(coalesce(p_reason, ''), 200),
          case when e.role = 'admin' then 'approved' else 'pending' end, case when e.role = 'admin' then e.id end);
  if e.role <> 'admin' then
    perform hrms_note(x.id, e.name || ' applied for ' || n || ' day' || case when n > 1 then 's' else '' end || ' of ' || lower(p_type) ||
                      ' leave (' || to_char(p_from, 'Dy DD Mon') || ').', 'leaves')
      from hrms_employees x where x.active and x.id <> e.id and (x.role = 'hr' or (x.id = e.mgr and x.role in ('manager','admin')));
  end if;
end $$;

create or replace function public.hrms_decide_leave(p_token uuid, p_id bigint, p_st text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token); l public.hrms_leaves; owner public.hrms_employees;
begin
  if p_st not in ('approved','rejected') then raise exception 'Unknown decision'; end if;
  select * into l from hrms_leaves where id = p_id;
  select * into owner from hrms_employees where id = l.emp;
  if l.id is null then raise exception 'Leave request not found'; end if;
  if l.emp = e.id or not (e.role in ('admin','hr') or (e.role = 'manager' and owner.mgr = e.id)) then
    raise exception 'You cannot decide this request'; end if;
  update hrms_leaves set st = p_st, by_emp = e.id where id = p_id;
  perform hrms_note(l.emp, e.name || ' ' || p_st || ' your ' || lower(l.type) || ' leave for ' || to_char(l.from_d, 'Dy DD Mon') ||
     case when l.to_d <> l.from_d then ' to ' || to_char(l.to_d, 'Dy DD Mon') else '' end || '.' ||
     case when p_st = 'approved' then ' It is paid and shows in attendance.' else '' end, 'leaves');
end $$;

-- ---------- tasks ----------
create or replace function public.hrms_save_task(p_token uuid, p_id bigint, p_title text, p_desc text, p_to text, p_due date, p_pri text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token); t public.hrms_tasks;
begin
  if coalesce(trim(p_title), '') = '' then raise exception 'Task title is required'; end if;
  if not (e.role in ('admin','hr') or (e.role = 'manager' and (p_to = e.id or exists (select 1 from hrms_employees where id = p_to and mgr = e.id)))) then
    raise exception 'You cannot assign tasks to this person'; end if;
  if p_id is null then
    insert into hrms_tasks(title, descr, to_emp, by_emp, due, pri) values (left(trim(p_title), 120), left(coalesce(p_desc, ''), 400), p_to, e.id, p_due, p_pri);
    if p_to <> e.id then perform hrms_note(p_to, e.name || ' assigned you: ' || trim(p_title) || ' (due ' || to_char(p_due, 'Dy DD Mon') || ')', 'tasks'); end if;
  else
    select * into t from hrms_tasks where id = p_id;
    if t.id is null then raise exception 'Task not found'; end if;
    if e.role <> 'admin' then raise exception 'Only Admin can edit tasks'; end if;
    update hrms_tasks set title = left(trim(p_title), 120), descr = left(coalesce(p_desc, ''), 400), to_emp = p_to, due = p_due, pri = p_pri where id = p_id;
    if p_to <> e.id then perform hrms_note(p_to, e.name || ' updated your task: ' || trim(p_title), 'tasks'); end if;
  end if;
end $$;

create or replace function public.hrms_task_status(p_token uuid, p_id bigint, p_st text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token); t public.hrms_tasks;
begin
  select * into t from hrms_tasks where id = p_id;
  if t.id is null or not (t.to_emp = e.id or t.by_emp = e.id or e.role in ('admin','hr')) then raise exception 'You cannot change this task'; end if;
  if p_st not in ('todo','doing','done') then raise exception 'Unknown status'; end if;
  update hrms_tasks set st = p_st where id = p_id;
  if p_st = 'done' and t.by_emp <> e.id then perform hrms_note(t.by_emp, e.name || ' completed: ' || t.title, 'tasks'); end if;
end $$;

create or replace function public.hrms_delete_task(p_token uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token);
begin
  if e.role <> 'admin' then raise exception 'Only Admin can delete tasks'; end if;
  delete from hrms_tasks where id = p_id;
end $$;

-- ---------- targets, payroll ----------
create or replace function public.hrms_set_target(p_token uuid, p_emp text, p_calls int, p_talk int, p_conv int, p_rev numeric) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token);
begin
  if not (e.role = 'admin' or (e.role = 'manager' and exists (select 1 from hrms_employees where id = p_emp and mgr = e.id))) then
    raise exception 'You cannot set this target'; end if;
  insert into hrms_targets(emp, calls, talk, conv, rev) values (p_emp, p_calls, p_talk, p_conv, p_rev)
  on conflict (emp) do update set calls = excluded.calls, talk = excluded.talk, conv = excluded.conv, rev = excluded.rev;
  perform hrms_note(p_emp, e.name || ' set your ' || to_char(hrms_today(), 'FMMonth') || ' target: ' || p_calls || ' calls, ' || p_conv ||
                    ' bookings, ' || hrms_fmt_inr(p_rev) || ' revenue.', 'sales');
end $$;

create or replace function public.hrms_add_adj(p_token uuid, p_emp text, p_ym text, p_amt numeric, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token);
begin
  if e.role not in ('admin','hr') then raise exception 'Only HR or Admin can adjust pay'; end if;
  if exists (select 1 from hrms_payouts where emp = p_emp and ym = p_ym) then raise exception 'This month is already paid'; end if;
  insert into hrms_adj(emp, ym, amt, reason, by_emp) values (p_emp, p_ym, p_amt, left(trim(p_reason), 80), e.id);
  perform hrms_note(p_emp, case when p_amt > 0 then 'Bonus' else 'Deduction' end || ' of ' || hrms_fmt_inr(abs(p_amt)) ||
                    ' added to your pay: ' || trim(p_reason) || '.', 'payslip');
end $$;

create or replace function public.hrms_set_inc(p_token uuid, p_inc numeric) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token);
begin
  if e.role <> 'admin' then raise exception 'Only Admin can change the incentive'; end if;
  update hrms_settings set inc = greatest(0, least(20, p_inc)), updated_at = now() where id = 1;
end $$;

-- p_items: [{emp, ym, label, amt}]  (amounts are calculated by the payroll screen)
create or replace function public.hrms_pay(p_token uuid, p_items json) returns int
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token); it json; tot numeric := 0; n int := 0; x public.hrms_employees;
begin
  if e.role not in ('admin','hr') then raise exception 'Only HR or Admin can pay salaries'; end if;
  select coalesce(sum((v->>'amt')::numeric), 0) into tot from json_array_elements(p_items) v;
  if tot > (select rzp_balance from hrms_settings where id = 1) then raise exception 'Not enough balance in RazorpayX'; end if;
  for it in select * from json_array_elements(p_items) loop
    select * into x from hrms_employees where id = it->>'emp' and active;
    continue when x.id is null or (it->>'amt')::numeric <= 0;
    continue when exists (select 1 from hrms_payouts where emp = x.id and ym = it->>'ym');
    insert into hrms_payouts(id, emp, ym, label, amt, mode, to_acct, by_emp)
    values ('pout_' || substr(md5(random()::text || clock_timestamp()::text), 1, 14), x.id, it->>'ym', it->>'label', round((it->>'amt')::numeric),
            case when x.bank ilike 'UPI%' then 'UPI' else 'IMPS' end, coalesce(nullif(x.bank, ''), 'Bank account'), e.id);
    update hrms_settings set rzp_balance = rzp_balance - round((it->>'amt')::numeric) where id = 1;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- notifications ----------
create or replace function public.hrms_read(p_token uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token);
begin
  update hrms_notes set read = true where to_emp = e.id and (p_id is null or id = p_id);
end $$;

-- ---------- people ----------
create or replace function public.hrms_add_employee(p_token uuid, p_name text, p_role text, p_dept text, p_title text, p_salary numeric,
  p_mgr text, p_phone text, p_bank text, p_pw text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare e public.hrms_employees := hrms_me(p_token); nid text; n int;
begin
  if e.role not in ('admin','hr') then raise exception 'Only HR or Admin can add employees'; end if;
  if p_role = 'admin' and e.role <> 'admin' then raise exception 'Only Admin can create another admin'; end if;
  if length(coalesce(p_pw, '')) < 6 then raise exception 'Password must be at least 6 characters'; end if;
  select coalesce(max(substr(id, 2)::int), 0) + 1 into n from hrms_employees where id ~ '^E[0-9]+$';
  nid := 'E' || lpad(n::text, 2, '0');
  insert into hrms_employees(id, name, role, dept, title, salary, mgr, phone, bank, pw_hash)
  values (nid, trim(p_name), p_role, trim(p_dept), trim(p_title), p_salary, nullif(p_mgr, ''), coalesce(p_phone, ''), coalesce(p_bank, ''),
          extensions.crypt(p_pw, extensions.gen_salt('bf')));
  if p_role = 'sales' then insert into hrms_targets(emp, calls, talk, conv, rev) values (nid, 900, 2400, 20, 350000); end if;
  perform hrms_note(nid, 'Welcome to Chefpy HRMS. Check in from My day when you start work.', 'me');
  return nid;
end $$;

create or replace function public.hrms_remove_employee(p_token uuid, p_emp text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token);
begin
  if e.role <> 'admin' then raise exception 'Only Admin can delete employees'; end if;
  if p_emp = e.id then raise exception 'You cannot delete yourself'; end if;
  update hrms_employees set active = false where id = p_emp;
  update hrms_employees set mgr = null where mgr = p_emp;
  delete from hrms_sessions where emp = p_emp;
end $$;


-- ---------- admin: edit and delete ----------
create or replace function public.hrms_admin(p_token uuid) returns public.hrms_employees
language plpgsql stable security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token);
begin
  if e.role <> 'admin' then raise exception 'Only Admin can edit or delete records'; end if;
  return e;
end $$;

create or replace function public.hrms_update_employee(p_token uuid, p_emp text, p_name text, p_role text, p_dept text, p_title text, p_salary numeric,
  p_mgr text, p_phone text, p_bank text, p_pw text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare e public.hrms_employees := hrms_admin(p_token);
begin
  if not exists (select 1 from hrms_employees where id = p_emp and active) then raise exception 'Employee not found'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Name is required'; end if;
  if p_role not in ('admin','hr','manager','sales','ops') then raise exception 'Unknown role'; end if;
  if p_emp = e.id and p_role <> 'admin' then raise exception 'You cannot remove your own Admin access'; end if;
  if coalesce(p_salary, 0) < 0 then raise exception 'Salary cannot be negative'; end if;
  if nullif(p_mgr, '') = p_emp then raise exception 'A person cannot report to themselves'; end if;
  if nullif(p_mgr, '') is not null and not exists (select 1 from hrms_employees where id = p_mgr and active) then raise exception 'Reports-to person not found'; end if;
  if coalesce(p_pw, '') <> '' and length(p_pw) < 6 then raise exception 'Password must be at least 6 characters'; end if;
  update hrms_employees set name = trim(p_name), role = p_role, dept = trim(coalesce(p_dept, '')), title = trim(coalesce(p_title, '')),
         salary = coalesce(p_salary, 0), mgr = nullif(p_mgr, ''), phone = trim(coalesce(p_phone, '')), bank = trim(coalesce(p_bank, ''))
   where id = p_emp;
  if p_role = 'sales' then insert into hrms_targets(emp) values (p_emp) on conflict do nothing; end if;
  if coalesce(p_pw, '') <> '' then
    update hrms_employees set pw_hash = extensions.crypt(p_pw, extensions.gen_salt('bf')) where id = p_emp;
    delete from hrms_sessions where emp = p_emp and token <> p_token;
    if p_emp <> e.id then perform hrms_note(p_emp, e.name || ' set a new password for you. Use it the next time you sign in.', 'dash'); end if;
  end if;
end $$;

create or replace function public.hrms_update_leave(p_token uuid, p_id bigint, p_type text, p_from date, p_to date, p_reason text, p_st text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_admin(p_token); l public.hrms_leaves;
begin
  select * into l from hrms_leaves where id = p_id;
  if l.id is null then raise exception 'Leave request not found'; end if;
  if p_type not in ('Casual','Sick','Earned') then raise exception 'Unknown leave type'; end if;
  if p_st not in ('pending','approved','rejected') then raise exception 'Unknown status'; end if;
  if p_to < p_from then raise exception 'End date is before start date'; end if;
  update hrms_leaves set type = p_type, from_d = p_from, to_d = p_to, reason = left(coalesce(p_reason, ''), 200), st = p_st,
         by_emp = case when p_st = 'pending' then null else e.id end where id = p_id;
  if l.emp <> e.id then perform hrms_note(l.emp, e.name || ' updated your ' || lower(p_type) || ' leave (' || to_char(p_from, 'Dy DD Mon') || '): ' || p_st || '.', 'leaves'); end if;
end $$;

create or replace function public.hrms_delete_leave(p_token uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_admin(p_token); l public.hrms_leaves;
begin
  delete from hrms_leaves where id = p_id returning * into l;
  if l.id is not null and l.emp <> e.id then
    perform hrms_note(l.emp, e.name || ' deleted your ' || lower(l.type) || ' leave request for ' || to_char(l.from_d, 'Dy DD Mon') || '.', 'leaves'); end if;
end $$;

create or replace function public.hrms_calls_on(p_token uuid, p_day date) returns json
language plpgsql stable security definer set search_path = public as $$
declare e public.hrms_employees := hrms_me(p_token);
begin
  return (select coalesce(json_agg(json_build_object('id', c.id, 'emp', c.emp, 'at', c.at, 'lead', c.lead, 'phone', c.phone,
        'out', c.outcome, 'dur', c.dur_sec, 'rev', c.rev, 'note', c.note) order by c.at desc), '[]')
    from hrms_calls c where c.day = p_day and c.emp in (select hrms_scope(e)));
end $$;

create or replace function public.hrms_update_call(p_token uuid, p_id bigint, p_lead text, p_phone text, p_out text, p_dur int, p_rev numeric, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_admin(p_token);
begin
  if coalesce(trim(p_lead), '') = '' then raise exception 'Customer name is required'; end if;
  if p_out not in ('Connected','No answer','Callback','Converted') then raise exception 'Unknown outcome'; end if;
  update hrms_calls set lead = left(trim(p_lead), 80), phone = left(coalesce(p_phone, ''), 20), outcome = p_out,
         dur_sec = case when p_out = 'No answer' then 0 else greatest(0, coalesce(p_dur, 0)) end,
         rev = case when p_out = 'Converted' then greatest(0, coalesce(p_rev, 0)) else 0 end, note = left(coalesce(p_note, ''), 120)
   where id = p_id;
  if not found then raise exception 'Call not found'; end if;
end $$;

create or replace function public.hrms_delete_call(p_token uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_admin(p_token);
begin
  delete from hrms_calls where id = p_id;
end $$;

-- set a day's attendance by hand (times are India time, 'HH:MM'); creates the day if it has no record
create or replace function public.hrms_set_day(p_token uuid, p_emp text, p_day date, p_in text, p_out text, p_brk int, p_idle int) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_admin(p_token); tin timestamptz; tout timestamptz;
  b interval := make_interval(mins => greatest(0, coalesce(p_brk, 0))); i interval := make_interval(mins => greatest(0, coalesce(p_idle, 0))); w timestamptz;
begin
  if not exists (select 1 from hrms_employees where id = p_emp) then raise exception 'Employee not found'; end if;
  if p_day > hrms_today() then raise exception 'You cannot edit a future day'; end if;
  if coalesce(p_in, '') = '' then raise exception 'Check-in time is required'; end if;
  tin := (p_day + p_in::time) at time zone 'Asia/Kolkata';
  if coalesce(p_out, '') <> '' then
    tout := (p_day + p_out::time) at time zone 'Asia/Kolkata';
    if tout <= tin then raise exception 'Check-out must be after check-in'; end if;
    if tout - tin < b + i then raise exception 'Break and idle time are longer than the working day'; end if;
  elsif p_day < hrms_today() then raise exception 'Check-out time is required for a past day';
  elsif tin > now() then raise exception 'Check-in time is later than now';
  elsif now() - tin < b + i then raise exception 'Break and idle time are longer than the time since check-in';
  end if;
  delete from hrms_segments where emp = p_emp and day = p_day;
  insert into hrms_days(emp, day, in_at, out_at, last_seen) values (p_emp, p_day, tin, tout, coalesce(tout, now()))
  on conflict (emp, day) do update set in_at = excluded.in_at, out_at = excluded.out_at, last_seen = excluded.last_seen;
  w := coalesce(tout, now()) - b - i;
  insert into hrms_segments(emp, day, kind, start_at, end_at) values (p_emp, p_day, 'work', tin, w);
  if b > interval '0' then insert into hrms_segments(emp, day, kind, start_at, end_at) values (p_emp, p_day, 'break', w, w + b); end if;
  if i > interval '0' then insert into hrms_segments(emp, day, kind, start_at, end_at) values (p_emp, p_day, 'idle', w + b, w + b + i); end if;
  if tout is null then insert into hrms_segments(emp, day, kind, start_at) values (p_emp, p_day, 'work', now()); end if;
  if p_emp <> e.id then perform hrms_note(p_emp, e.name || ' updated your attendance for ' || to_char(p_day, 'Dy DD Mon') || '.', 'attendance'); end if;
end $$;

create or replace function public.hrms_delete_day(p_token uuid, p_emp text, p_day date) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_admin(p_token);
begin
  delete from hrms_segments where emp = p_emp and day = p_day;
  delete from hrms_days where emp = p_emp and day = p_day;
  if p_emp <> e.id then perform hrms_note(p_emp, e.name || ' removed your attendance record for ' || to_char(p_day, 'Dy DD Mon') || '.', 'attendance'); end if;
end $$;

create or replace function public.hrms_delete_adj(p_token uuid, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_admin(p_token); a public.hrms_adj;
begin
  select * into a from hrms_adj where id = p_id;
  if a.id is null then return; end if;
  if exists (select 1 from hrms_payouts where emp = a.emp and ym = a.ym) then raise exception 'This month is already paid'; end if;
  delete from hrms_adj where id = p_id;
  if a.emp <> e.id then perform hrms_note(a.emp, e.name || ' removed a pay adjustment: ' || a.reason || '.', 'payslip'); end if;
end $$;

-- test mode only: cancel a payout record and put the amount back in the balance, so the month can be paid again
create or replace function public.hrms_delete_payout(p_token uuid, p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.hrms_employees := hrms_admin(p_token); p public.hrms_payouts;
begin
  delete from hrms_payouts where id = p_id returning * into p;
  if p.id is null then raise exception 'Payout not found'; end if;
  update hrms_settings set rzp_balance = rzp_balance + p.amt where id = 1;
  if p.emp <> e.id then perform hrms_note(p.emp, e.name || ' cancelled the ' || p.label || ' salary payout record of ' || hrms_fmt_inr(p.amt) || '.', 'payslip'); end if;
end $$;

-- ---------- permissions: only the public API functions are callable ----------
do $$ declare f text; begin
  foreach f in array array[
    'hrms_today()','hrms_me(uuid)','hrms_note(text,text,text)','hrms_scope(public.hrms_employees)','hrms_fmt_inr(numeric)',
    'hrms_close_open(text,timestamptz)','hrms_workdays(date,date)','hrms_admin(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'hrms_login(text,text)','hrms_logout(uuid)','hrms_change_password(uuid,text,text)','hrms_reset_password(uuid,text,text)',
    'hrms_data(uuid)','hrms_checkin(uuid)','hrms_state(uuid,text,timestamptz)','hrms_ping(uuid)','hrms_checkout(uuid)',
    'hrms_log_call(uuid,text,text,text,int,numeric,text)','hrms_apply_leave(uuid,text,date,date,text)','hrms_decide_leave(uuid,bigint,text)',
    'hrms_save_task(uuid,bigint,text,text,text,date,text)','hrms_task_status(uuid,bigint,text)','hrms_delete_task(uuid,bigint)',
    'hrms_set_target(uuid,text,int,int,int,numeric)','hrms_add_adj(uuid,text,text,numeric,text)','hrms_set_inc(uuid,numeric)',
    'hrms_pay(uuid,json)','hrms_read(uuid,bigint)',
    'hrms_add_employee(uuid,text,text,text,text,numeric,text,text,text,text)','hrms_remove_employee(uuid,text)',
    'hrms_update_employee(uuid,text,text,text,text,text,numeric,text,text,text,text)','hrms_update_leave(uuid,bigint,text,date,date,text,text)',
    'hrms_delete_leave(uuid,bigint)','hrms_calls_on(uuid,date)','hrms_update_call(uuid,bigint,text,text,text,int,numeric,text)','hrms_delete_call(uuid,bigint)',
    'hrms_set_day(uuid,text,date,text,text,int,int)','hrms_delete_day(uuid,text,date)','hrms_delete_adj(uuid,bigint)','hrms_delete_payout(uuid,text)'] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

-- Starting data: settings + the Chefpy team (sample people; replace with real staff in the Team screen)
insert into public.hrms_settings(id) values (1) on conflict (id) do nothing;
insert into public.hrms_employees(id,name,role,dept,title,salary,mgr,phone,bank,pw_hash) values
 ('E01','Ananya Rao','admin','Management','Operations Head',90000,null,'98450 11201','HDFC Bank ••4521',extensions.crypt('admin123',extensions.gen_salt('bf'))),
 ('E02','Kavya Menon','hr','HR','HR Manager',55000,null,'98450 11202','ICICI Bank ••0917',extensions.crypt('hr123',extensions.gen_salt('bf'))),
 ('E03','Rohit Sharma','manager','Sales','Sales Manager',60000,null,'98450 11203','Axis Bank ••3310',extensions.crypt('sales123',extensions.gen_salt('bf')))
on conflict (id) do nothing;
insert into public.hrms_employees(id,name,role,dept,title,salary,mgr,phone,bank,pw_hash) values
 ('E04','Priya Nair','sales','Sales','Sales Executive',28000,'E03','98450 11204','UPI priya.nair@okhdfc',extensions.crypt('emp123',extensions.gen_salt('bf'))),
 ('E05','Arjun Patil','sales','Sales','Sales Executive',26000,'E03','98450 11205','SBI ••8842',extensions.crypt('emp123',extensions.gen_salt('bf'))),
 ('E06','Sneha Kulkarni','sales','Sales','Senior Sales Executive',32000,'E03','98450 11206','Kotak ••1206',extensions.crypt('emp123',extensions.gen_salt('bf'))),
 ('E07','Vikram Joshi','sales','Sales','Sales Executive',25000,'E03','98450 11207','UPI vikramj@ybl',extensions.crypt('emp123',extensions.gen_salt('bf'))),
 ('E08','Meera Iyer','sales','Sales','Sales Executive',27000,'E03','98450 11208','HDFC Bank ••5570',extensions.crypt('emp123',extensions.gen_salt('bf'))),
 ('E09','Farhan Shaikh','ops','Chef Operations','Chef Coordinator',32000,'E01','98450 11209','SBI ••4418',extensions.crypt('emp123',extensions.gen_salt('bf'))),
 ('E10','Divya Reddy','ops','Chef Operations','Booking Coordinator',30000,'E01','98450 11210','UPI divya.r@oksbi',extensions.crypt('emp123',extensions.gen_salt('bf')))
on conflict (id) do nothing;
insert into public.hrms_targets(emp,calls,talk,conv,rev) values
 ('E04',900,2400,24,450000),('E05',900,2400,22,400000),('E06',1000,2700,30,550000),('E07',850,2200,20,350000),('E08',900,2400,24,420000)
on conflict (emp) do nothing;
