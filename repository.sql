------------------------------------------------------------------------------
-- DATA MODEL
------------------------------------------------------------------------------

--
-- commit
--

create table commit (
    id uuid not null default public.uuid_generate_v7() primary key,
    parent_id uuid references commit(id), --null means first commit
    merge_parent_id uuid references commit(id),

    -- rows jsonb array. values are row_id::text
    jsonb_rows jsonb not null default '[]' check (jsonb_typeof(jsonb_rows) = 'array'),
    -- fields jsonb obj.  key is row_id, value is "column": "value hash" map
    jsonb_fields jsonb not null default '{}' check (jsonb_typeof(jsonb_fields) = 'object'),

    author_name text not null default '',
    author_email text not null default '',
    message text not null default '',
    commit_time timestamptz not null default now()
);
-- TODO: check constraint for only one null parent_id per repo
-- TODO: i am not my own grandpa


--
-- repository
--

create table repository (
    id uuid not null default public.uuid_generate_v7() primary key,
    name text not null unique check(name != ''),
    head_commit_id uuid unique references commit(id) on delete set null deferrable initially deferred,
    checkout_commit_id uuid unique references commit(id) on delete set null deferrable initially deferred,

    tracked_rows_added     jsonb not null default '[]' check (jsonb_typeof(tracked_rows_added) = 'array'),

    stage_rows_to_add      jsonb not null default '[]' check (jsonb_typeof(stage_rows_to_add) = 'array'),
    stage_rows_to_remove   jsonb not null default '[]' check (jsonb_typeof(stage_rows_to_remove) = 'array'),
    stage_fields_to_change jsonb not null default '[]' check (jsonb_typeof(stage_fields_to_change) = 'array') -- {} ?
);
-- TODO: stage_commit can't be checkout_commit or head_commit

-- circular fk
alter table commit add column repository_id uuid /* not null FIXME why is deferrable not working?? */ references repository(id) on delete cascade deferrable initially deferred;


/*
--
-- migrations
--

create table commit_migration (
    id uuid not null default public.uuid_generate_v7() primary key,
    commit_id uuid not null references commit(id),
    up_code text,
    down_code text, -- can we auto-generate a lot of this?
    before_checkout boolean,
    ordinal_position integer
);


--
-- dependencies
--

create table dependency (
    id uuid not null default public.uuid_generate_v7() primary key
);
*/


-------------------------------
-- Name/id functions
-------------------------------

--
-- repository_id()
--

create or replace function repository_id( repository_name text ) returns uuid as $$
    select id from bundle.repository where name=repository_name;
$$ stable language sql;


--
-- repository_name()
--

create or replace function _repository_name( repository_id uuid ) returns text as $$
    select name from bundle.repository where id=repository_id;
$$ stable language sql;


--
-- head_commit_id()
--

create or replace function _head_commit_id( repository_id uuid ) returns uuid as $$
    select head_commit_id from bundle.repository where id=repository_id;
$$ stable language sql;

create or replace function head_commit_id( repository_name text ) returns uuid as $$
    select head_commit_id from bundle.repository where name=repository_name;
$$ stable language sql;


--
-- checkout_commit_id()
--

create or replace function _checkout_commit_id( repository_id uuid ) returns uuid as $$
    select checkout_commit_id from bundle.repository where id=repository_id;
$$ stable language sql;

create or replace function checkout_commit_id( repository_name text ) returns uuid as $$
    select checkout_commit_id from bundle.repository where name=repository_name;
$$ stable language sql;


-------------------------------
-- operation functions
-------------------------------

--
-- create_repository()
--

create or replace function create_repository( repository_name text ) returns uuid as $$
declare
    _repository_id uuid;
--     _stage_commit_id uuid;
begin
    raise notice 'Create repository %', repository_name;
    if repository_name = '' then
        raise exception 'Repository name cannot be empty string.';
    end if;

    if repository_name is null then
        raise exception 'Repository name cannot be null.';
    end if;

    -- create repository
    insert into bundle.repository (name) values (repository_name) returning id into _repository_id;

    return _repository_id;
exception
    when unique_violation then
        raise exception 'Repository with name % already exists.', repository_name;
    when others then raise;
end
$$ language plpgsql;


--
-- delete_repository()
--

create or replace function _delete_repository( repository_id uuid ) returns void as $$
    begin
        if not bundle._repository_exists(repository_id) then
            raise exception 'Repository with id % does not exist.', repository_id;
        end if;

        delete from bundle.repository where id = repository_id;
    end;
$$ language plpgsql;

create or replace function delete_repository( repository_name text ) returns void as $$
    begin
    raise notice 'Delete repository %', repository_name;
        if not bundle.repository_exists(repository_name) then
            raise exception 'Repository with name % does not exist.', repository_name;
        end if;

        perform bundle._delete_repository(bundle.repository_id(repository_name));

    end;
$$ language plpgsql;


--
-- garbage_collect()
--

/*
create or replace function garbage_collect() returns setof text as $$
    delete from bundle.blob
    using (
        select b.hash as bad_hash from bundle.blob b
            left join GONE: bundle.commit_field_changed cfc on cfc.value_hash = b.hash
        where  cfc.value_hash is null
    )
    where hash = bad_hash
    returning bad_hash
$$ language sql;
*/

-------------------------------
-- info functions
-------------------------------

--
-- repository_exists()
--

create or replace function repository_exists( _name text ) returns boolean as $$
    select exists (select 1 from bundle.repository where name = _name);
$$ language sql;

create or replace function _repository_exists( repository_id uuid ) returns boolean as $$
    select exists (select 1 from bundle.repository where id = repository_id);
$$ language sql;


--
-- repository_has_commits()
--

create or replace function _repository_has_commits( _repository_id uuid ) returns boolean as $$
    select exists (select 1 from bundle.commit where repository_id = _repository_id);
$$ language sql;


--
-- repository_has_uncommitted_changes()
--

create or replace function _repository_has_uncommitted_changes( _repository_id uuid ) returns boolean as $$
    declare
        is_checked_out boolean;
    begin
        -- if it isn't checked out, it doesn't have uncommitted changes
        select (checkout_commit_id is not null) from bundle.repository where id=_repository_id
        into is_checked_out;

        if is_checked_out then return false; end if;

        -- TODO: check for it
        return false;
    end;
$$ language plpgsql;


--
-- commit_exists()
--

create or replace function _commit_exists(commit_id uuid) returns boolean as $$
    select exists (select 1 from bundle.commit where id=commit_id);
$$ language sql;


--
-- get_commit_rows()
--

create or replace function _get_commit_rows( _commit_id uuid, _relation_id_filter meta.relation_id default null )
returns table(_position integer, row_id meta.row_id)
as $$
    select position, row_id
    from (
        select row_number() over (order by ord) as position, elem::meta.row_id as row_id -- id as commit_id, jsonb_array_elements_text(jsonb_rows)::meta.row_id as row_id
        from bundle.commit c, lateral jsonb_array_elements_text(c.jsonb_rows) with ordinality as u(elem, ord)
        where c.id = _commit_id
    ) as subquery
    where (row_id)::meta.relation_id = _relation_id_filter or _relation_id_filter is null;
$$ language sql;

--
-- get_head_commit_rows()
--

create or replace function _get_head_commit_rows( _repository_id uuid, _relation_id_filter meta.relation_id default null )
 returns table(_position integer, row_id meta.row_id) as $$
    select * from bundle._get_commit_rows(bundle._head_commit_id(_repository_id), _relation_id_filter);
$$ language sql;

create or replace function get_head_commit_rows( repository_name text, _relation_id_filter meta.relation_id default null )
 returns table(_position integer, row_id meta.row_id) as $$
    select *
    from bundle._get_commit_rows(
        bundle._head_commit_id(bundle.repository_id(repository_name)),
        _relation_id_filter
    );
$$ language sql;


--
-- get_commit_fields()
--
-- returns all fields and their value hashes

create type field_hash as ( field_id meta.field_id, value_hash text);

create or replace function _get_commit_fields(_commit_id uuid /*, _relation_id_filter meta.relation_id default null TODO? */)
returns setof field_hash as $$
    select meta.field_id(e.key::meta.row_id, (jsonb_each_text(e.value)).key), (jsonb_each_text(e.value)).value as val from bundle.commit, lateral jsonb_each(jsonb_fields) e where id=_commit_id;
$$ language sql;


--
-- get_head_commit_fields()
--
create or replace function _get_head_commit_fields( _repository_id uuid ) returns setof field_hash as $$
    select * from bundle._get_commit_fields(bundle._head_commit_id(_repository_id));
$$ language sql;


--
-- get_commit_jsonb_rows()
--

create or replace function _get_commit_jsonb_rows( _commit_id uuid ) returns jsonb as $$
    select jsonb_rows from bundle.commit where id = _commit_id;
$$ language sql;


-- get_commit_jsonb_fields()
--

create or replace function _get_commit_jsonb_fields( _commit_id uuid ) returns jsonb as $$
    select jsonb_fields from bundle.commit where id = _commit_id;
$$ language sql;


--
-- get_commit_row_count_by_relation( _commit_id uuid, relation_id uuid )
-- used in summary

create or replace function _get_commit_row_count_by_relation( _commit_id uuid )
returns table( relation_id meta.relation_id, row_count integer ) as $$
    select row_id::meta.relation_id as relation_id, count(*) as row_count
    from bundle._get_commit_rows(_commit_id)
    group by row_id::meta.relation_id
$$ language sql;
