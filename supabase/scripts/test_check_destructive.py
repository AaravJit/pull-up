"""Tests for check_destructive.py. Run: python3 -m unittest discover -s supabase/scripts -p 'test_*.py'"""
import unittest

from check_destructive import check

REFUSED = {
    "plain drop": "drop table public.t;",
    "split across lines": "DROP\n  TABLE\n  foo;",
    "drop column": "alter table t drop column c;",
    "drop column without COLUMN": "alter table t\n  drop\n  old_col;",
    "truncate": "truncate\n  t;",
    "delete without where": "delete from t;",
    "delete with where": "delete from t where id = 1;",
    "delete after WITH": "with doomed as (select id from p where true) delete from p using doomed where p.id = doomed.id;",
    "delete in DO block": "do $$ begin delete from public.t; end $$;",
    "delete in tagged DO block": "do language plpgsql $x$ begin if true then delete from t; end if; end $x$;",
    "retype": "alter table t alter column name\n type text;",
    "retype without COLUMN": "alter table t alter value type text;",
    "retype with digits": "alter table t alter column value2 type text;",
    "retype quoted with a doubled quote": 'alter table t alter column "old""value" type text;',
    "retype quoted": 'ALTER TABLE public.t ALTER "Odd Name" SET DATA TYPE bigint;',
    "comment marker in a string": "select '--'; delete from profiles;",
    "block comment marker in a string": "select '/*'; drop table t; select '*/';",
    "escaped quote in a string": "select E'it\\'s -- fine'; drop table t;",
    "doubled quote in a string": "select 'it''s -- fine'; truncate t;",
    "created function called later": (
        "create function purge() returns void language sql as $$ delete from profiles $$;\n"
        "select purge();"
    ),
    "procedure called later": (
        "create procedure public.wipe() language plpgsql as $p$ begin truncate t; end $p$;\ncall public.wipe();"
    ),
    "function called by another function that is called": (
        "create function inner_wipe() returns void language sql as $$ delete from t $$;\n"
        "create function outer_fn() returns void language plpgsql as $$ begin perform inner_wipe(); end $$;\n"
        "select outer_fn();"
    ),
    "function called from a DO block": (
        "create function purge() returns void language sql as $$ delete from t $$;\n"
        "do $$ begin perform purge(); end $$;"
    ),
    "write that fires a destructive trigger": (
        "create function cleanup() returns trigger language plpgsql as $$ begin delete from t; return new; end $$;\n"
        "create trigger c after insert on public.s for each row execute function cleanup();\n"
        "insert into public.s values (1);"
    ),
    "write in a DO block that fires a trigger installed in a DO block": (
        "create function private.cleanup() returns trigger language plpgsql as $$ begin truncate t; return new; end $$;\n"
        "do $$ begin create trigger c before update on s for each row execute function private.cleanup(); end $$;\n"
        "do $$ begin update s set a = 1; end $$;"
    ),
    "dynamic SQL": "do $$ begin execute 'drop table ' || 'x'; end $$;",
    "drop schema": "drop schema old cascade;",
    "approval line inside a block comment": (
        "/* To approve, add:\n-- pullup: destructive change approved by <name> on <date>\n*/\ndrop table t;"
    ),
    "approval line inside a string": "select '\n-- pullup: destructive change approved by x'; drop table t;",
    "approval template left unfilled": "-- pullup: destructive change approved by <name> on <date>\ndrop table t;",
    "approval without a date": "-- pullup: destructive change approved by Aarav\ndrop table t;",
    "approval after code on the same line": "select 1; -- pullup: destructive change approved by x\ndrop table t;",
    "single-quoted function body called later": (
        "create function purge() returns void language sql as 'delete from profiles';\nselect purge();"
    ),
    "single-quoted DO body": "do 'begin delete from t; end';",
    "SQL-standard body called later": (
        "CREATE PROCEDURE wipe() LANGUAGE SQL BEGIN ATOMIC DELETE FROM profiles; END;\nCALL wipe();"
    ),
    "SQL-standard body with CASE called later": (
        "create function f() returns int language sql begin atomic select case when true then 1 end; "
        "delete from t; end;\nselect f();"
    ),
    "SQL-standard RETURN body calling a destructive function": (
        "create function purge() returns void language sql as $$ delete from t $$;\n"
        "create function wrapper() returns void language sql return purge();\nselect wrapper();"
    ),
    "write in an SQL-standard body that fires a destructive trigger": (
        "create function cleanup() returns trigger language plpgsql as $$ begin delete from t; return new; end $$;\n"
        "create trigger c after insert on s for each row execute function cleanup();\n"
        "create procedure p() language sql begin atomic insert into s values (1); end;\ncall p();"
    ),
    "called function whose write fires a destructive trigger": (
        "create function cleanup() returns trigger language plpgsql as $$ begin truncate t; return new; end $$;\n"
        "create trigger c after update on s for each row execute function cleanup();\n"
        "create function touch() returns void language plpgsql as $$ begin update s set a = 1; end $$;\nselect touch();"
    ),
    "write under IF in a called function fires a destructive trigger": (
        "create function cleanup() returns trigger language plpgsql as $$ begin delete from t; return new; end $$;\n"
        "create trigger c after insert on s for each row execute function cleanup();\n"
        "create function touch() returns void language plpgsql as $$ begin if true then insert into s values (1); end if; end $$;\n"
        "select touch();"
    ),
    "destructive overload called after a harmless one is created": (
        "create function f(integer) returns void language sql as $$ delete from t $$;\n"
        "create function f(text) returns void language sql as $$ select 1 $$;\nselect f(1);"
    ),
    "same name in another schema": (
        "create function private.f() returns void language sql as $$ truncate t $$;\n"
        "create function public.f() returns void language sql as $$ select 1 $$;\nselect private.f();"
    ),
    "drop foreign table": "drop foreign table remote_rows;",
    "drop type cascade": "drop type mood cascade;",
    "drop function cascade": "drop function f() cascade;",
    "merge with delete": "merge into t using s on t.id = s.id when matched then delete;",
    "alter foreign table drop column": "alter foreign table r drop column c;",
    "alter type drop attribute": "alter type addr drop attribute zip;",
    "destructive event trigger": (
        "create function wipe() returns event_trigger language plpgsql as $$ begin delete from t; end $$;\n"
        "create event trigger w on ddl_command_end execute function wipe();"
    ),
    "quoted BEGIN in an SQL-standard body": (
        'create function f() returns int language sql begin atomic select 1 as "begin"; end;\ndelete from profiles;'
    ),
    "SQL-standard body that never closes": "create function f() returns int language sql begin atomic select 1;\ndelete from t;",
    "dynamic SQL split across literals": "DO $$ BEGIN EXECUTE 'DROP ' || 'TABLE profiles'; END $$;",
    "dynamic SQL built with format": "do $$ begin execute format('%s %s x', 'drop', 'table'); end $$;",
}

ALLOWED = {
    "create table": "create table t (id int);",
    "add column": "alter table t add column c int;",
    "drop constraint": "alter table t drop constraint t_pk;",
    "drop default": "alter table t alter column c drop default;",
    "drop not null": "alter table t alter column c drop not null;",
    "set default": "alter table t alter column c set default 0;",
    "comment mentioning drop table": "-- we never drop table here\ncreate table t (id int);",
    "block comment": "/* drop table x; */ create table y (id int);",
    "nested block comment": "/* a /* drop table x; */ b */ create table y (id int);",
    "string mentioning delete": "comment on table t is 'rows delete from here never';",
    "function only created": (
        "create or replace function public.delete_my_post(p uuid) returns void language plpgsql as $fn$\n"
        "begin delete from public.posts where id = p and author = auth.uid(); end;\n$fn$;"
    ),
    "revoke truncate": "revoke truncate on table public.t from anon;",
    "delete policy": "create policy p on public.t for delete using (true);",
    "on delete cascade": "alter table x add constraint fk foreign key (a) references y on delete cascade;",
    "enum value": "alter type mood add value 'meh';",
    "approved": "-- pullup: destructive change approved by Aarav on 2026-10-19\ndrop table t;",
    "approved, indented": "  -- pullup: destructive change approved by Aarav on 2026-10-19\ndrop table t;",
    "destructive trigger only installed": (
        "create function cleanup() returns trigger language plpgsql as $$ begin delete from t; return new; end $$;\n"
        "create trigger c after insert on s for each row execute function cleanup();"
    ),
    "grants on a destructive function": (
        "create function public.unsend(p uuid) returns void language sql as $$ delete from m where id = p $$;\n"
        "revoke execute on function public.unsend(uuid) from public, anon;\n"
        "grant execute on function public.unsend(uuid) to authenticated;"
    ),
    "write before the destructive trigger exists": (
        "update t set a = 1;\n"
        "create function cleanup() returns trigger language plpgsql as $$ begin delete from x; return new; end $$;\n"
        "create trigger c before update on t for each row execute function cleanup();"
    ),
    "write to a table whose trigger is harmless": (
        "create function stamp() returns trigger language plpgsql as $$ begin new.at = now(); return new; end $$;\n"
        "create trigger s before insert on t for each row execute function stamp();\ninsert into t values (1);"
    ),
    "SQL-standard body only created": (
        "create function wipe() returns void language sql begin atomic delete from t; end;\ncreate table y (id int);"
    ),
    "SQL-standard RETURN body only created": (
        "create function purge() returns void language sql as $$ delete from t $$;\n"
        "create function wrapper() returns void language sql return purge();"
    ),
    "drop function without cascade": "drop function if exists f(int);",
    "drop policy": "drop policy if exists p on t;",
    "harmless event trigger": (
        "create function note() returns event_trigger language plpgsql as $$ begin raise notice 'ddl'; end $$;\n"
        "create event trigger n on ddl_command_end execute function note();"
    ),
    "quoted END in an SQL-standard body": (
        'create function f() returns int language sql begin atomic select 1 as "end"; end;\ncreate table y (id int);'
    ),
    "trigger and grant mention EXECUTE": (
        "create function stamp() returns trigger language plpgsql as $$ begin new.at = now(); return new; end $$;\n"
        "create trigger s before insert on t for each row execute function stamp();\n"
        "grant execute on function stamp() to authenticated;\ninsert into t values (1);"
    ),
    "dynamic SQL only in a created function": (
        "create function f() returns void language plpgsql as $$ begin execute 'drop table x'; end $$;"
    ),
    "positional parameter": "create function f(int) returns int language sql as $$ select $1 $$; select f(1);",
}


class Refused(unittest.TestCase):
    def test_routine_created_in_an_earlier_migration(self):
        earlier = "create function purge() returns void language sql as $$ delete from profiles $$;"
        self.assertTrue(check("select purge();", earlier))

    def test_trigger_installed_in_an_earlier_migration(self):
        earlier = (
            "create function cleanup() returns trigger language plpgsql as $$ begin delete from t; return new; end $$;\n"
            "create trigger c after insert on s for each row execute function cleanup();")
        self.assertTrue(check("insert into s values (1);", earlier))

    def test_redefined_revoke_helper(self):
        earlier = ("create function private.revoke_anon_execute(p text) returns integer language plpgsql as $$ "
                   "begin execute 'drop table ' || p; return 1; end $$;")
        self.assertTrue(check("select private.revoke_anon_execute('x');", earlier))

    def test_routine_renamed_in_an_earlier_migration(self):
        earlier = ("create function purge() returns void language sql as $$ delete from t $$;\n"
                   "alter function purge() rename to wipe;")
        self.assertTrue(check("select wipe();", earlier))

    def test_quoted_call(self):
        earlier = "create function purge() returns void language sql as $$ delete from t $$;"
        self.assertTrue(check('select "purge"();', earlier))
        self.assertTrue(check('select public."purge"();', earlier))

    def test_main_reads_earlier_files(self):
        import os, tempfile
        from check_destructive import main
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "20260101000100_a.sql"), "w") as f:
                f.write("create function purge() returns void language sql as $$ delete from t $$;")
            with open(os.path.join(d, "20260101000200_b.sql"), "w") as f:
                f.write("select purge();")
            self.assertEqual(main([os.path.join(d, "20260101000100_a.sql")]), 0)
            self.assertEqual(main([os.path.join(d, "20260101000200_b.sql")]), 1)


class Allowed(unittest.TestCase):
    def test_reviewed_revoke_helper(self):
        import os
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "../migrations/20261016000800_security_hardening.sql"), encoding="utf-8") as f:
            earlier = f.read()
        self.assertEqual(check("select private.revoke_anon_execute('20270101000100');", earlier), [])

    def test_earlier_routine_only_defined(self):
        earlier = "create function purge() returns void language sql as $$ delete from profiles $$;"
        self.assertEqual(check("create table y (id int);", earlier), [])


for label, sql in REFUSED.items():
    setattr(Refused, "test_" + label.replace(" ", "_"), lambda self, sql=sql: self.assertTrue(check(sql), sql))
for label, sql in ALLOWED.items():
    setattr(Allowed, "test_" + label.replace(" ", "_"), lambda self, sql=sql: self.assertEqual(check(sql), [], sql))

if __name__ == "__main__":
    unittest.main()
