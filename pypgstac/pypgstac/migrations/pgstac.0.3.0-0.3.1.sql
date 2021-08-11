SET SEARCH_PATH to pgstac, public;
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION pgstac.ftime()
 RETURNS interval
 LANGUAGE sql
AS $function$
SELECT age(clock_timestamp(), transaction_timestamp());
$function$
;

CREATE OR REPLACE FUNCTION pgstac.geojsonsearch(geojson jsonb, queryhash text, fields jsonb DEFAULT NULL::jsonb, _scanlimit integer DEFAULT 10000, _limit integer DEFAULT 100, _timelimit interval DEFAULT '00:00:05'::interval, skipcovered boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
AS $function$
    SELECT * FROM geometrysearch(
        st_geomfromgeojson(geojson),
        queryhash,
        fields,
        _scanlimit,
        _limit,
        _timelimit,
        skipcovered
    );
$function$
;

CREATE OR REPLACE FUNCTION pgstac.geometrysearch(geom geometry, queryhash text, fields jsonb DEFAULT NULL::jsonb, _scanlimit integer DEFAULT 10000, _limit integer DEFAULT 100, _timelimit interval DEFAULT '00:00:05'::interval, skipcovered boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    search searches%ROWTYPE;
    curs refcursor;
    _where text;
    query text;
    iter_record items%ROWTYPE;
    out_records jsonb[] := '{}'::jsonb[];
    exit_flag boolean := FALSE;
    counter int := 1;
    scancounter int := 1;
    remaining_limit int := _scanlimit;
    tilearea float;
    unionedgeom geometry;
    clippedgeom geometry;
    unionedgeom_area float := 0;
    prev_area float := 0;
    excludes text[];
    includes text[];

BEGIN
    SELECT * INTO search FROM searches WHERE hash=queryhash;
    tilearea := st_area(geom);
    _where := format('%s AND st_intersects(geometry, %L::geometry)', search._where, geom);

    IF fields IS NOT NULL THEN
        IF fields ? 'fields' THEN
            fields := fields->'fields';
        END IF;
        IF fields ? 'exclude' THEN
            excludes=textarr(fields->'exclude');
        END IF;
        IF fields ? 'include' THEN
            includes=textarr(fields->'include');
            IF array_length(includes, 1)>0 AND NOT 'id' = ANY (includes) THEN
                includes = includes || '{id}';
            END IF;
        END IF;
    END IF;
    RAISE NOTICE 'fields: %, includes: %, excludes: %', fields, includes, excludes;

    FOR query IN SELECT * FROM partition_queries(_where, search.orderby) LOOP
        query := format('%s LIMIT %L', query, remaining_limit);
        RAISE NOTICE '%', query;
        curs = create_cursor(query);
        LOOP
            FETCH curs INTO iter_record;
            EXIT WHEN NOT FOUND;

            clippedgeom := st_intersection(geom, iter_record.geometry);

            IF unionedgeom IS NULL THEN
                unionedgeom := clippedgeom;
            ELSE
                unionedgeom := st_union(unionedgeom, clippedgeom);
            END IF;

            unionedgeom_area := st_area(unionedgeom);

            IF skipcovered AND prev_area = unionedgeom_area THEN
                scancounter := scancounter + 1;
                CONTINUE;
            END IF;

            prev_area := unionedgeom_area;

            RAISE NOTICE '% % % %', st_area(unionedgeom)/tilearea, counter, scancounter, ftime();
            IF fields IS NOT NULL THEN
                out_records := out_records || filter_jsonb(iter_record.content, includes, excludes);
            ELSE
                out_records := out_records || iter_record.content;
            END IF;

            IF counter > _limit
                OR scancounter > _scanlimit
                OR ftime() > _timelimit
                OR unionedgeom_area >= tilearea
            THEN
                exit_flag := TRUE;
                EXIT;
            END IF;
            counter := counter + 1;
            scancounter := scancounter + 1;

        END LOOP;
        EXIT WHEN exit_flag;
        remaining_limit := _scanlimit - scancounter;
    END LOOP;

    RETURN jsonb_build_object(
        'type', 'FeatureCollection',
        'features', array_to_json(out_records)::jsonb
    );
END;
$function$
;

CREATE OR REPLACE FUNCTION pgstac.tileenvelope(zoom integer, x integer, y integer)
 RETURNS geometry
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
WITH t AS (
    SELECT
        20037508.3427892 as merc_max,
        -20037508.3427892 as merc_min,
        (2 * 20037508.3427892) / (2 ^ zoom) as tile_size
)
SELECT st_makeenvelope(
    merc_min + (tile_size * x),
    merc_max - (tile_size * (y + 1)),
    merc_min + (tile_size * (x + 1)),
    merc_max - (tile_size * y),
    3857
) FROM t;
$function$
;

CREATE OR REPLACE FUNCTION pgstac.xyzsearch(_x integer, _y integer, _z integer, queryhash text, fields jsonb DEFAULT NULL::jsonb, _scanlimit integer DEFAULT 10000, _limit integer DEFAULT 100, _timelimit interval DEFAULT '00:00:05'::interval, skipcovered boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
AS $function$
    SELECT * FROM geometrysearch(
        st_transform(tileenvelope(_z, _x, _y), 4326),
        queryhash,
        fields,
        _scanlimit,
        _limit,
        _timelimit,
        skipcovered
    );
$function$
;



INSERT INTO migrations (version) VALUES ('0.3.1');