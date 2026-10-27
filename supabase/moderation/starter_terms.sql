-- A minimal, reviewed starting set for the text filter (migration
-- 20261025000300). NOT a migration: the owner reads it, edits it and runs it
-- in the SQL editor of each project (docs/MODERATION_RUNBOOK.md, "Term list").
--
-- It holds only unambiguous threats and incitement to self-harm, so it can
-- live in this public repository. Slurs and sexual terms are deliberately not
-- here: the owner adds them from a vetted list in the SQL editor (or with
-- public.mod_add_term from a moderator account), so the list isn't published
-- for people to work around. Every change is written to the audit log.
--
-- "word" terms match whole words after folding (case, accents, digit swaps,
-- spaced-out letters); "contains" terms match anywhere. Test a text with
--   select public.mod_check_text('...');

select public.mod_add_term('kill yourself', 'word', 'threat', 'incitement to self-harm');
select public.mod_add_term('kys', 'word', 'threat', 'abbreviation of kill yourself');
select public.mod_add_term('neck yourself', 'word', 'threat', 'incitement to self-harm');
select public.mod_add_term('hope you die', 'word', 'threat', 'death wish');
select public.mod_add_term('i will kill you', 'word', 'threat', 'threat of violence');
select public.mod_add_term('ill kill you', 'word', 'threat', 'threat of violence (i''ll, folded)');
select public.mod_add_term('i ll kill you', 'word', 'threat', 'threat of violence (i''ll, folded)');

select term, match, category from public.mod_terms();
