SET client_min_messages TO WARNING;
SET SEARCH_PATH to pgstac, public;
alter table "pgstac"."queryables" drop constraint "queryables_name_key";

drop function if exists "pgstac"."missing_queryables"(_collection text, _tablesample integer);

drop function if exists "pgstac"."missing_queryables"(_tablesample integer);

alter table "pgstac"."stac_extensions" drop constraint "stac_extensions_pkey";

drop index if exists "pgstac"."queryables_name_key";

drop index if exists "pgstac"."stac_extensions_pkey";

alter table "pgstac"."stac_extensions" drop column "enableable";

alter table "pgstac"."stac_extensions" drop column "enbabled_by_default";

alter table "pgstac"."stac_extensions" drop column "name";

alter table "pgstac"."stac_extensions" add column "content" jsonb;

alter table "pgstac"."stac_extensions" alter column "url" set not null;

CREATE UNIQUE INDEX stac_extensions_pkey ON pgstac.stac_extensions USING btree (url);

alter table "pgstac"."stac_extensions" add constraint "stac_extensions_pkey" PRIMARY KEY using index "stac_extensions_pkey";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION pgstac.first_notnull_sfunc(anyelement, anyelement)
 RETURNS anyelement
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
    SELECT COALESCE($1,$2);
$function$
;

CREATE OR REPLACE FUNCTION pgstac.get_queryables()
 RETURNS jsonb
 LANGUAGE sql
AS $function$
    SELECT get_queryables(NULL::text[]);
$function$
;

CREATE OR REPLACE FUNCTION pgstac.get_token_val_str(_field text, _item pgstac.items)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
literal text;
BEGIN
RAISE NOTICE '% %', _field, _item;
CREATE TEMP TABLE _token_item ON COMMIT DROP AS SELECT (_item).*;
EXECUTE format($q$ SELECT quote_literal(%s) FROM _token_item $q$, _field) INTO literal;
DROP TABLE IF EXISTS _token_item;
RETURN literal;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgstac.jsonb_array_unique(j jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT nullif_jsonbnullempty(jsonb_agg(DISTINCT a)) v FROM jsonb_array_elements(j) a;
$function$
;

CREATE OR REPLACE FUNCTION pgstac.jsonb_concat_ignorenull(a jsonb, b jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT coalesce(a,'[]'::jsonb) || coalesce(b,'[]'::jsonb);
$function$
;

CREATE OR REPLACE FUNCTION pgstac.jsonb_greatest(a jsonb, b jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT nullif_jsonbnullempty(greatest(a, b));
$function$
;

CREATE OR REPLACE FUNCTION pgstac.jsonb_least(a jsonb, b jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT nullif_jsonbnullempty(least(nullif_jsonbnullempty(a), nullif_jsonbnullempty(b)));
$function$
;

CREATE OR REPLACE FUNCTION pgstac.missing_queryables(_collection text, _tablesample double precision DEFAULT 5, minrows double precision DEFAULT 10)
 RETURNS TABLE(collection text, name text, definition jsonb, property_wrapper text)
 LANGUAGE plpgsql
AS $function$
DECLARE
    q text;
    _partition text;
    explain_json json;
    psize float;
    estrows float;
BEGIN
    SELECT format('_items_%s', key) INTO _partition FROM collections WHERE id=_collection;

    EXECUTE format('EXPLAIN (format json) SELECT 1 FROM %I;', _partition)
    INTO explain_json;
    psize := explain_json->0->'Plan'->'Plan Rows';
    estrows := _tablesample * .01 * psize;
    IF estrows < minrows THEN
        _tablesample := least(100,greatest(_tablesample, (estrows / psize) / 100));
        RAISE NOTICE '%', (psize / estrows) / 100;
    END IF;
    RAISE NOTICE 'Using tablesample % to find missing queryables from % % that has ~% rows estrows: %', _tablesample, _collection, _partition, psize, estrows;

    q := format(
        $q$
            WITH q AS (
                SELECT * FROM queryables
                WHERE
                    collection_ids IS NULL
                    OR %L = ANY(collection_ids)
            ), t AS (
                SELECT
                    content->'properties' AS properties
                FROM
                    %I
                TABLESAMPLE SYSTEM(%L)
            ), p AS (
                SELECT DISTINCT ON (key)
                    key,
                    value,
                    s.definition
                FROM t
                JOIN LATERAL jsonb_each(properties) ON TRUE
                LEFT JOIN q ON (q.name=key)
                LEFT JOIN stac_extension_queryables s ON (s.name=key)
                WHERE q.definition IS NULL
            )
            SELECT
                %L,
                key,
                COALESCE(definition, jsonb_build_object('type',jsonb_typeof(value))) as definition,
                CASE
                    WHEN definition->>'type' = 'integer' THEN 'to_int'
                    WHEN COALESCE(definition->>'type', jsonb_typeof(value)) = 'number' THEN 'to_float'
                    WHEN COALESCE(definition->>'type', jsonb_typeof(value)) = 'array' THEN 'to_text_array'
                    ELSE 'to_text'
                END
            FROM p;
        $q$,
        _collection,
        _partition,
        _tablesample,
        _collection
    );
    RETURN QUERY EXECUTE q;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgstac.missing_queryables(_tablesample double precision DEFAULT 5)
 RETURNS TABLE(collection_ids text[], name text, definition jsonb, property_wrapper text)
 LANGUAGE sql
AS $function$
    SELECT
        array_agg(collection),
        name,
        definition,
        property_wrapper
    FROM
        collections
        JOIN LATERAL
        missing_queryables(id, _tablesample) c
        ON TRUE
    GROUP BY
        2,3,4
    ORDER BY 2,1
    ;
$function$
;

CREATE OR REPLACE FUNCTION pgstac.nullif_jsonbnullempty(j jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE STRICT
AS $function$
    SELECT nullif(nullif(nullif(j,'null'::jsonb),'{}'::jsonb),'[]'::jsonb);
$function$
;

CREATE OR REPLACE FUNCTION pgstac.schema_qualify_refs(url text, j jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE STRICT
AS $function$
    SELECT regexp_replace(j::text, '"\$ref": "#', concat('"$ref": "', url, '#'), 'g')::jsonb;
$function$
;

create or replace view "pgstac"."stac_extension_queryables" as  SELECT DISTINCT j.key AS name,
    pgstac.schema_qualify_refs(e.url, j.value) AS definition
   FROM pgstac.stac_extensions e,
    LATERAL jsonb_each((((e.content -> 'definitions'::text) -> 'fields'::text) -> 'properties'::text)) j(key, value);


CREATE OR REPLACE AGGREGATE first_notnull(anyelement)(
    SFUNC = first_notnull_sfunc,
    STYPE = anyelement
);

CREATE OR REPLACE AGGREGATE jsonb_array_unique_merge(jsonb) (
    STYPE = jsonb,
    SFUNC = jsonb_concat_ignorenull,
    FINALFUNC = jsonb_array_unique
);

CREATE OR REPLACE AGGREGATE jsonb_min(jsonb) (
    STYPE = jsonb,
    SFUNC = jsonb_least
);

CREATE OR REPLACE AGGREGATE jsonb_max(jsonb) (
    STYPE = jsonb,
    SFUNC = jsonb_greatest
);


CREATE OR REPLACE FUNCTION pgstac.get_queryables(_collection_ids text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
BEGIN
    -- Build up queryables if the input contains valid collection ids or is empty
    IF EXISTS (
        SELECT 1 FROM collections
        WHERE
            _collection_ids IS NULL
            OR cardinality(_collection_ids) = 0
            OR id = ANY(_collection_ids)
    )
    THEN
        RETURN (
            WITH base AS (
                SELECT
                    unnest(collection_ids) as collection_id,
                    name,
                    coalesce(definition, '{"type":"string"}'::jsonb) as definition
                FROM queryables
                WHERE
                    _collection_ids IS NULL OR
                    _collection_ids = '{}'::text[] OR
                    _collection_ids && collection_ids
                UNION ALL
                SELECT null, name, coalesce(definition, '{"type":"string"}'::jsonb) as definition
                FROM queryables WHERE collection_ids IS NULL OR collection_ids = '{}'::text[]
            ), g AS (
                SELECT
                    name,
                    first_notnull(definition) as definition,
                    jsonb_array_unique_merge(definition->'enum') as enum,
                    jsonb_min(definition->'minimum') as minimum,
                    jsonb_min(definition->'maxiumn') as maximum
                FROM base
                GROUP BY 1
            )
            SELECT
                jsonb_build_object(
                    '$schema', 'http://json-schema.org/draft-07/schema#',
                    '$id', '',
                    'type', 'object',
                    'title', 'STAC Queryables.',
                    'properties', jsonb_object_agg(
                        name,
                        definition
                        ||
                        jsonb_strip_nulls(jsonb_build_object(
                            'enum', enum,
                            'minimum', minimum,
                            'maximum', maximum
                        ))
                    )
                )
                FROM g
        );
    ELSE
        RETURN NULL;
    END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgstac.get_token_filter(_search jsonb DEFAULT '{}'::jsonb, token_rec jsonb DEFAULT NULL::jsonb)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    token_id text;
    filters text[] := '{}'::text[];
    prev boolean := TRUE;
    field text;
    dir text;
    sort record;
    orfilters text[] := '{}'::text[];
    andfilters text[] := '{}'::text[];
    output text;
    token_where text;
    token_item items%ROWTYPE;
BEGIN
    RAISE NOTICE 'Getting Token Filter. % %', _search, token_rec;
    -- If no token provided return NULL
    IF token_rec IS NULL THEN
        IF NOT (_search ? 'token' AND
                (
                    (_search->>'token' ILIKE 'prev:%')
                    OR
                    (_search->>'token' ILIKE 'next:%')
                )
        ) THEN
            RETURN NULL;
        END IF;
        prev := (_search->>'token' ILIKE 'prev:%');
        token_id := substr(_search->>'token', 6);
        SELECT to_jsonb(items) INTO token_rec
        FROM items WHERE id=token_id;
    END IF;
    RAISE NOTICE 'TOKEN ID: % %', token_rec, token_rec->'id';


    RAISE NOTICE 'TOKEN ID: % %', token_rec, token_rec->'id';
    token_item := jsonb_populate_record(null::items, token_rec);
    RAISE NOTICE 'TOKEN ITEM ----- %', token_item;


    CREATE TEMP TABLE sorts (
        _row int GENERATED ALWAYS AS IDENTITY NOT NULL,
        _field text PRIMARY KEY,
        _dir text NOT NULL,
        _val text
    ) ON COMMIT DROP;

    -- Make sure we only have distinct columns to sort with taking the first one we get
    INSERT INTO sorts (_field, _dir)
        SELECT
            (queryable(value->>'field')).expression,
            get_sort_dir(value)
        FROM
            jsonb_array_elements(coalesce(_search->'sortby','[{"field":"datetime","direction":"desc"}]'))
    ON CONFLICT DO NOTHING
    ;
    RAISE NOTICE 'sorts 1: %', (SELECT jsonb_agg(to_json(sorts)) FROM sorts);
    -- Get the first sort direction provided. As the id is a primary key, if there are any
    -- sorts after id they won't do anything, so make sure that id is the last sort item.
    SELECT _dir INTO dir FROM sorts ORDER BY _row ASC LIMIT 1;
    IF EXISTS (SELECT 1 FROM sorts WHERE _field = 'id') THEN
        DELETE FROM sorts WHERE _row > (SELECT _row FROM sorts WHERE _field = 'id' ORDER BY _row ASC);
    ELSE
        INSERT INTO sorts (_field, _dir) VALUES ('id', dir);
    END IF;

    -- Add value from looked up item to the sorts table
    UPDATE sorts SET _val=get_token_val_str(_field, token_item);

    -- Check if all sorts are the same direction and use row comparison
    -- to filter
    RAISE NOTICE 'sorts 2: %', (SELECT jsonb_agg(to_json(sorts)) FROM sorts);

        FOR sort IN SELECT * FROM sorts ORDER BY _row asc LOOP
            RAISE NOTICE 'SORT: %', sort;
            IF sort._row = 1 THEN
                IF sort._val IS NULL THEN
                    orfilters := orfilters || format('(%s IS NOT NULL)', sort._field);
                ELSE
                    orfilters := orfilters || format('(%s %s %s)',
                        sort._field,
                        CASE WHEN (prev AND sort._dir = 'ASC') OR (NOT prev AND sort._dir = 'DESC') THEN '<' ELSE '>' END,
                        sort._val
                    );
                END IF;
            ELSE
                IF sort._val IS NULL THEN
                    orfilters := orfilters || format('(%s AND %s IS NOT NULL)',
                    array_to_string(andfilters, ' AND '), sort._field);
                ELSE
                    orfilters := orfilters || format('(%s AND %s %s %s)',
                        array_to_string(andfilters, ' AND '),
                        sort._field,
                        CASE WHEN (prev AND sort._dir = 'ASC') OR (NOT prev AND sort._dir = 'DESC') THEN '<' ELSE '>' END,
                        sort._val
                    );
                END IF;
            END IF;
            IF sort._val IS NULL THEN
                andfilters := andfilters || format('%s IS NULL',
                    sort._field
                );
            ELSE
                andfilters := andfilters || format('%s = %s',
                    sort._field,
                    sort._val
                );
            END IF;
        END LOOP;
        output := array_to_string(orfilters, ' OR ');

    DROP TABLE IF EXISTS sorts;
    token_where := concat('(',coalesce(output,'true'),')');
    IF trim(token_where) = '' THEN
        token_where := NULL;
    END IF;
    RAISE NOTICE 'TOKEN_WHERE: |%|',token_where;
    RETURN token_where;
    END;
$function$
;

CREATE OR REPLACE FUNCTION pgstac.items_staging_triggerfunc()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    p record;
    _partitions text[];
    ts timestamptz := clock_timestamp();
BEGIN
    RAISE NOTICE 'Creating Partitions. %', clock_timestamp() - ts;
    WITH ranges AS (
        SELECT
            n.content->>'collection' as collection,
            stac_daterange(n.content->'properties') as dtr
        FROM newdata n
    ), p AS (
        SELECT
            collection,
            lower(dtr) as datetime,
            upper(dtr) as end_datetime,
            (partition_name(
                collection,
                lower(dtr)
            )).partition_name as name
        FROM ranges
    )
    INSERT INTO partitions (collection, datetime_range, end_datetime_range)
        SELECT
            collection,
            tstzrange(min(datetime), max(datetime), '[]') as datetime_range,
            tstzrange(min(end_datetime), max(end_datetime), '[]') as end_datetime_range
        FROM p
            GROUP BY collection, name
        ON CONFLICT (name) DO UPDATE SET
            datetime_range = EXCLUDED.datetime_range,
            end_datetime_range = EXCLUDED.end_datetime_range
    ;

    RAISE NOTICE 'Doing the insert. %', clock_timestamp() - ts;
    IF TG_TABLE_NAME = 'items_staging' THEN
        INSERT INTO items
        SELECT
            (content_dehydrate(content)).*
        FROM newdata;
        DELETE FROM items_staging;
    ELSIF TG_TABLE_NAME = 'items_staging_ignore' THEN
        INSERT INTO items
        SELECT
            (content_dehydrate(content)).*
        FROM newdata
        ON CONFLICT DO NOTHING;
        DELETE FROM items_staging_ignore;
    ELSIF TG_TABLE_NAME = 'items_staging_upsert' THEN
        WITH staging_formatted AS (
            SELECT (content_dehydrate(content)).* FROM newdata
        ), deletes AS (
            DELETE FROM items i USING staging_formatted s
                WHERE
                    i.id = s.id
                    AND i.collection = s.collection
                    AND i IS DISTINCT FROM s
            RETURNING i.id, i.collection
        )
        INSERT INTO items
        SELECT s.* FROM
            staging_formatted s
            ON CONFLICT DO NOTHING;
        DELETE FROM items_staging_upsert;
    END IF;
    RAISE NOTICE 'Done. %', clock_timestamp() - ts;

    RETURN NULL;

END;
$function$
;



SELECT set_version('0.6.12');
