---------------------------------------------------------------------------
-- PostSail => Postgres + TimescaleDB + PostGIS + PostgREST
-- 
-- Inspired from:
-- https://groups.google.com/g/signalk/c/W2H15ODCic4
--
-- Description:
-- Insert data into table metadata from API using PostgREST
-- Insert data into table metrics from API using PostgREST
-- TimescaleDB Hypertable to store signalk metrics
-- pgsql functions to generate logbook, stays, moorages
-- CRON functions to process logbook, stays, moorages
-- python functions for geo reverse and send notification via email and/or pushover
-- Views statistics, timelapse, monitoring, logs
-- Always store time in UTC
---------------------------------------------------------------------------

-- vessels signalk -(POST)-> metadata -> metadata_upsert -(trigger)-> metadata_upsert_trigger_fn (INSERT or UPDATE)
-- vessels signalk -(POST)-> metrics -> metrics -(trigger)-> metrics_fn new log,stay,moorage

---------------------------------------------------------------------------

-- Drop database
-- % docker exec -i timescaledb-postgis psql -Uusername -W postgres -c "drop database signalk;"

-- Import Schema
-- % cat signalk.sql | docker exec -i timescaledb-postgis psql -Uusername postgres

-- Export hypertable
-- % docker exec -i timescaledb-postgis psql -Uusername -W signalk -c "\COPY (SELECT * FROM api.metrics ORDER BY time ASC) TO '/var/lib/postgresql/data/metrics.csv' DELIMITER ',' CSV"
-- Export hypertable to gzip
-- # docker exec -i timescaledb-postgis psql -Uusername -W signalk -c "\COPY (SELECT * FROM api.metrics ORDER BY time ASC) TO PROGRAM 'gzip > /var/lib/postgresql/data/metrics.csv.gz' CSV HEADER;"

DO $$
BEGIN
RAISE WARNING '
  _________.__                     .__   ____  __.
 /   _____/|__| ____   ____ _____  |  | |    |/ _|
 \_____  \ |  |/ ___\ /    \\__  \ |  | |      <  
 /        \|  / /_/  >   |  \/ __ \|  |_|    |  \ 
/_______  /|__\___  /|___|  (____  /____/____|__ \
        \/   /_____/      \/     \/             \/
 %', now();
END $$;

select version();

-- Database
CREATE DATABASE signalk;

-- connext to the DB
\c signalk

-- Schema
CREATE SCHEMA IF NOT EXISTS api;
COMMENT ON SCHEMA api IS 'api schema expose to postgrest';

-- Revoke default privileges to all public functions
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Extensions
CREATE EXTENSION IF NOT EXISTS timescaledb; -- provides time series functions for PostgreSQL
-- CREATE EXTENSION IF NOT EXISTS timescaledb_toolkit; -- provides time series functions for PostgreSQL
CREATE EXTENSION IF NOT EXISTS postgis; -- adds support for geographic objects to the PostgreSQL object-relational database
CREATE EXTENSION IF NOT EXISTS plpgsql; -- PL/pgSQL procedural language
CREATE EXTENSION IF NOT EXISTS plpython3u; -- implements PL/Python based on the Python 3 language variant.
CREATE EXTENSION IF NOT EXISTS jsonb_plpython3u CASCADE; -- tranform jsonb to python json type.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements; -- provides a means for tracking planning and execution statistics of all SQL statements executed

-- Trust plpython3u language by default
UPDATE pg_language SET lanpltrusted = true WHERE lanname = 'plpython3u';

---------------------------------------------------------------------------
-- Tables
--
-- Metrics from signalk
CREATE TABLE IF NOT EXISTS api.metrics (
  time TIMESTAMP WITHOUT TIME ZONE NOT NULL,
  client_id VARCHAR(255) NOT NULL,
  latitude DOUBLE PRECISION NULL,
  longitude DOUBLE PRECISION NULL,
  speedOverGround DOUBLE PRECISION NULL,
  courseOverGroundTrue DOUBLE PRECISION NULL,
  windSpeedApparent DOUBLE PRECISION NULL,
  angleSpeedApparent DOUBLE PRECISION NULL,
  status VARCHAR(100) NULL,
  metrics jsonb NULL
);
-- Description
COMMENT ON TABLE
    api.metrics
    IS 'Stores metrics from vessel';

-- Index todo!
CREATE INDEX ON api.metrics (client_id, time DESC);
CREATE INDEX ON api.metrics (status, time DESC);
-- json index??
CREATE INDEX ON api.metrics using GIN (metrics);
-- timescaledb hypertable
SELECT create_hypertable('api.metrics', 'time');

---------------------------------------------------------------------------
-- Metadata from signalk
CREATE TABLE IF NOT EXISTS api.metadata(
  id SERIAL PRIMARY KEY,
  name VARCHAR(150) NULL,
  mmsi VARCHAR(10) NULL,
  client_id VARCHAR(255) UNIQUE NOT NULL,
  length DOUBLE PRECISION NULL,
  beam DOUBLE PRECISION NULL,
  height DOUBLE PRECISION NULL,
  ship_type VARCHAR(255) NULL,
  plugin_version VARCHAR(10) NOT NULL,
  signalk_version VARCHAR(10) NOT NULL,
  time TIMESTAMP WITHOUT TIME ZONE NOT NULL, -- last_update
  active BOOLEAN DEFAULT True -- monitor online/offline
);
-- Description
COMMENT ON TABLE
    api.metadata
    IS 'Stores metadata from vessel';

-- Index todo!
CREATE INDEX metadata_client_id_idx ON api.metadata (client_id);

---------------------------------------------------------------------------
-- Logbook
-- todo add clientid ref
-- todo add cosumption fuel?
-- todo add engine hour?
-- todo add geom object http://epsg.io/4326 EPSG:4326 Unit: degres
-- todo add geog object http://epsg.io/3857 EPSG:3857 Unit: meters
-- https://postgis.net/workshops/postgis-intro/geography.html#using-geography
-- https://medium.com/coord/postgis-performance-showdown-geometry-vs-geography-ec99967da4f0
-- virtual logbook by boat by client_id impossible? 
-- https://www.postgresql.org/docs/current/ddl-partitioning.html
-- Issue:
-- https://www.reddit.com/r/PostgreSQL/comments/di5mbr/postgresql_12_foreign_keys_and_partitioned_tables/f3tsoop/
CREATE TABLE IF NOT EXISTS api.logbook(
  id SERIAL PRIMARY KEY,
  client_id VARCHAR(255) NOT NULL REFERENCES api.metadata(client_id) ON DELETE RESTRICT,
--  client_id VARCHAR(255) NOT NULL,
  active BOOLEAN DEFAULT false,
  name VARCHAR(255),
  _from VARCHAR(255),
  _from_lat DOUBLE PRECISION NULL,
  _from_lng DOUBLE PRECISION NULL,
  _to VARCHAR(255),
  _to_lat DOUBLE PRECISION NULL,
  _to_lng DOUBLE PRECISION NULL,
  --track_geom Geometry(LINESTRING)
  track_geom geometry(LINESTRING,4326) NULL,
  track_geog geography(LINESTRING) NULL,
  track_geojson JSON NULL,
  _from_time TIMESTAMP WITHOUT TIME ZONE NOT NULL,
  _to_time TIMESTAMP WITHOUT TIME ZONE NULL,
  distance NUMERIC, -- meters?
  duration INTERVAL, -- duration in days and hours?
  avg_speed DOUBLE PRECISION NULL,
  max_speed DOUBLE PRECISION NULL,
  max_wind_speed DOUBLE PRECISION NULL,
  notes TEXT NULL
);
-- Description
COMMENT ON TABLE
    api.logbook
    IS 'Stores generated logbook';
COMMENT ON COLUMN api.logbook.distance IS 'in NM';

-- Index todo!
CREATE INDEX logbook_client_id_idx ON api.logbook (client_id);
CREATE INDEX ON api.logbook USING GIST ( track_geom );
COMMENT ON COLUMN api.logbook.track_geom IS 'postgis geometry type EPSG:4326 Unit: degres';
CREATE INDEX ON api.logbook USING GIST ( track_geog );
COMMENT ON COLUMN api.logbook.track_geog IS 'postgis geography type default SRID 4326 Unit: degres';
-- Otherwise -- ERROR:  Only lon/lat coordinate systems are supported in geography.

---------------------------------------------------------------------------
-- Stays
-- todo add clientid ref
-- todo add FOREIGN KEY?
-- virtual logbook by boat? 
CREATE TABLE IF NOT EXISTS api.stays(
  id SERIAL PRIMARY KEY,
  client_id VARCHAR(255) NOT NULL REFERENCES api.metadata(client_id) ON DELETE RESTRICT,
--  client_id VARCHAR(255) NOT NULL,
  active BOOLEAN DEFAULT false,
  name VARCHAR(255),
  latitude DOUBLE PRECISION NULL,
  longitude DOUBLE PRECISION NULL,
  geog GEOGRAPHY(POINT) NULL,
  arrived TIMESTAMP WITHOUT TIME ZONE NOT NULL,
  departed TIMESTAMP WITHOUT TIME ZONE,
  duration INTERVAL, -- duration in days and hours?
  stay_code INT DEFAULT 1, -- REFERENCES api.stays_at(stay_code),
  notes TEXT NULL
);
-- Description
COMMENT ON TABLE
    api.stays
    IS 'Stores generated stays';

-- Index
CREATE INDEX stays_client_id_idx ON api.stays (client_id);
CREATE INDEX ON api.stays USING GIST ( geog );
COMMENT ON COLUMN api.stays.geog IS 'postgis geography type default SRID 4326 Unit: degres';
-- With other SRID ERROR: Only lon/lat coordinate systems are supported in geography.

---------------------------------------------------------------------------
-- Moorages
-- todo add clientid ref
-- virtual logbook by boat? 
CREATE TABLE IF NOT EXISTS api.moorages(
  id SERIAL PRIMARY KEY,
  client_id VARCHAR(255) NOT NULL REFERENCES api.metadata(client_id) ON DELETE RESTRICT,
--  client_id VARCHAR(255) NOT NULL,
  name VARCHAR(255),
  country VARCHAR(255), -- todo need to update reverse_geocode_py_fn
  stay_id INT NOT NULL, -- needed?
  stay_code INT DEFAULT 1, -- needed?  REFERENCES api.stays_at(stay_code)
  stay_duration INTERVAL NULL,
  reference_count INT DEFAULT 1,
  latitude DOUBLE PRECISION NULL,
  longitude DOUBLE PRECISION NULL,
  geog GEOGRAPHY(POINT) NULL,
  home_flag BOOLEAN DEFAULT false,
  notes TEXT NULL
);
-- Description
COMMENT ON TABLE
    api.moorages
    IS 'Stores generated moorages';

-- Index
CREATE INDEX moorages_client_id_idx ON api.moorages (client_id);
CREATE INDEX ON api.moorages USING GIST ( geog );
COMMENT ON COLUMN api.moorages.geog IS 'postgis geography type default SRID 4326 Unit: degres';
-- With other SRID ERROR: Only lon/lat coordinate systems are supported in geography.

---------------------------------------------------------------------------
-- Stay Type
CREATE TABLE IF NOT EXISTS api.stays_at(
  stay_code   INTEGER,
  description TEXT
);
-- Description
COMMENT ON TABLE api.stays_at IS 'Stay Type';
-- Insert default possible values
INSERT INTO api.stays_at(stay_code, description) VALUES
  (1, 'Unknow'),
  (2, 'Anchor'),
  (3, 'Mooring Buoy'),
  (4, 'Dock');

---------------------------------------------------------------------------
-- Trigger Functions Metadata table
--
-- UPSERT - Insert vs Update for Metadata
DROP FUNCTION IF EXISTS metadata_upsert_trigger_fn; 
CREATE FUNCTION metadata_upsert_trigger_fn() RETURNS trigger AS $metadata_upsert$
    DECLARE
        metadata_id integer;
        metadata_active boolean;
    BEGIN
        -- UPSERT - Insert vs Update for Metadata
        RAISE NOTICE 'metadata_upsert_trigger_fn';
        SELECT m.id,m.active INTO metadata_id,metadata_active
            FROM api.metadata m
            WHERE (m.mmsi IS NOT NULL AND m.mmsi = NEW.mmsi) 
                    OR (m.client_id IS NOT NULL AND m.client_id = NEW.client_id);
        RAISE NOTICE 'metadata_id %', metadata_id;
        IF metadata_id IS NOT NULL THEN
            -- send notifitacion if boat is back online
            IF metadata_active is False THEN
                -- Add monitor online entry to process queue for later notification
                INSERT INTO process_queue (channel, payload, stored) 
                    VALUES ('monitoring_online', metadata_id, now());
            END IF;
            -- Update vessel metadata
            UPDATE api.metadata
                SET
                    name = NEW.name,
                    mmsi = NEW.mmsi,
                    client_id = NEW.client_id,
                    length = NEW.length,
                    beam = NEW.beam,
                    height = NEW.height,
                    ship_type = NEW.ship_type,
                    plugin_version = NEW.plugin_version,
                    signalk_version = NEW.signalk_version,
                    time = NEW.time,
                    active = true
                WHERE id = metadata_id;
            RETURN NULL; -- Ignore insert
        ELSE
            -- Insert new vessel metadata
            RETURN NEW; -- Insert new vessel metadata
        END IF;
    END;
$metadata_upsert$ LANGUAGE plpgsql;
-- Description
COMMENT ON FUNCTION
    public.metadata_upsert_trigger_fn
    IS 'process metadata from vessel, upsert';

-- Metadata notification for new vessel after insert
DROP FUNCTION IF EXISTS metadata_notification_trigger_fn; 
CREATE FUNCTION metadata_notification_trigger_fn() RETURNS trigger AS $metadata_notification$
    DECLARE
    BEGIN
        RAISE NOTICE 'metadata_notification_trigger_fn';
        INSERT INTO process_queue (channel, payload, stored) 
            VALUES ('monitoring_online', NEW.id, now());
        RETURN NULL;
    END;
$metadata_notification$ LANGUAGE plpgsql;
-- Description
COMMENT ON FUNCTION
    public.metadata_notification_trigger_fn
    IS 'process metadata notification from vessel, monitoring_online';

-- Metadata trigger BEFORE INSERT
CREATE TRIGGER metadata_upsert_trigger BEFORE INSERT ON api.metadata
    FOR EACH ROW EXECUTE FUNCTION metadata_upsert_trigger_fn();
-- Description
COMMENT ON TRIGGER 
    metadata_upsert_trigger ON api.metadata 
    IS 'BEFORE INSERT ON api.metadata run function metadata_upsert_trigger_fn';

-- Metadata trigger AFTER INSERT
CREATE TRIGGER metadata_notification_trigger AFTER INSERT ON api.metadata
    FOR EACH ROW EXECUTE FUNCTION metadata_notification_trigger_fn();
-- Description
COMMENT ON TRIGGER 
    metadata_notification_trigger ON api.metadata 
    IS 'AFTER INSERT ON api.metadata run function metadata_update_trigger_fn for notification on new vessel';

---------------------------------------------------------------------------
-- Trigger Functions metrics table
--
-- Create a logbook or stay entry base on the vessel state, eg: navigation.state
-- https://github.com/meri-imperiumi/signalk-autostate

DROP FUNCTION IF EXISTS metrics_trigger_fn;
CREATE FUNCTION metrics_trigger_fn() RETURNS trigger AS $metrics$
    DECLARE
        previous_status varchar;
        previous_time TIMESTAMP WITHOUT TIME ZONE;
        stay_code integer;
        logbook_id integer;
        stay_id integer;
    BEGIN
        RAISE NOTICE 'metrics_trigger_fn';
        -- todo: Check we have the boat metadata?
        -- Do we have a log in progress?
        -- Do we have a stay in progress?
        -- Fetch the latest entry to compare status against the new status to be insert
        SELECT coalesce(m.status, 'moored'), m.time INTO previous_status, previous_time
            FROM api.metrics m 
            WHERE m.client_id IS NOT NULL
                AND m.client_id = NEW.client_id
            ORDER BY m.time DESC LIMIT 1;
        RAISE NOTICE 'Metrics Status, New:[%] Previous:[%]', NEW.status, previous_status;
        IF NEW.status IS NULL THEN
            RAISE WARNING 'Invalid new status [%], update to default moored', NEW.status;
            NEW.status := 'moored';
        END IF;
        IF previous_status IS NULL THEN
            RAISE WARNING 'Invalid previous status [%], update to default moored', previous_status;
            previous_status := 'moored';
            -- Add new stay as no previous entry exist
            INSERT INTO api.stays 
                (client_id, active, arrived, latitude, longitude, stay_code) 
                VALUES (NEW.client_id, true, NEW.time, NEW.latitude, NEW.longitude, stay_code)
                RETURNING id INTO stay_id;
            -- Add stay entry to process queue for further processing
            INSERT INTO process_queue (channel, payload, stored) values ('new_stay', stay_id, now());
            RAISE WARNING 'Insert first stay as no previous metrics exist, stay_id %', stay_id;
        END IF;
        IF previous_time = NEW.time THEN
            -- Ignore entry if same time
            RAISE WARNING 'Ignoring metric, duplicate time [%] = [%]', previous_time, NEW.time;
            RETURN NULL;
        END IF;

        --
        -- Check the state and if any previous/current entry
        IF previous_status <> NEW.status AND (NEW.status = 'sailing' OR NEW.status = 'motoring') THEN
            -- Start new log
            RAISE WARNING 'Start new log, New:[%] Previous:[%]', NEW.status, previous_status;
            RAISE NOTICE 'Inserting new trip [%]', NEW.status;
            INSERT INTO api.logbook 
                (client_id, active, _from_time, _from_lat, _from_lng)
                VALUES (NEW.client_id, true, NEW.time, NEW.latitude, NEW.longitude);
            -- End current stay
            -- Fetch stay_id by client_id
            SELECT id INTO stay_id
                FROM api.stays s
                WHERE s.client_id IS NOT NULL
                    AND s.client_id = NEW.client_id
                    AND active IS true
                LIMIT 1;
            RAISE NOTICE 'Updating stay status [%] [%] [%]', stay_id, NEW.status, NEW.time;
            IF stay_id IS NOT NULL THEN
                UPDATE api.stays
                    SET
                        active = false, 
                        departed = NEW.time
                    WHERE id = stay_id;       
                -- Add moorage entry to process queue for further processing
                INSERT INTO process_queue (channel, payload, stored) values ('new_moorage', stay_id, now());
            ELSE
                RAISE WARNING 'Invalid stay_id [%] [%]', stay_id, NEW.time;
            END IF;
        ELSIF previous_status <> NEW.status AND (NEW.status = 'moored' OR NEW.status = 'anchored') THEN
            -- Start new stays
            RAISE WARNING 'Start new stay, New:[%] Previous:[%]', NEW.status, previous_status;
            RAISE NOTICE 'Inserting new stay [%]', NEW.status;
            -- if metric status is anchored set stay_code accordingly
            stay_code = 1;
            IF NEW.status = 'anchored' THEN
                stay_code = 2;
            END IF;
            -- Add new stay
            INSERT INTO api.stays 
                (client_id, active, arrived, latitude, longitude, stay_code) 
                VALUES (NEW.client_id, true, NEW.time, NEW.latitude, NEW.longitude, stay_code)
                RETURNING id INTO stay_id;
            -- Add stay entry to process queue for further processing
            INSERT INTO process_queue (channel, payload, stored) values ('new_stay', stay_id, now());
            -- End current log/trip
            -- Fetch logbook_id by client_id
            SELECT id INTO logbook_id
                FROM api.logbook l
                WHERE l.client_id IS NOT NULL
                    AND l.client_id = NEW.client_id
                    AND active IS true
                LIMIT 1;
            IF logbook_id IS NOT NULL THEN
                -- todo check on time start vs end
                RAISE NOTICE 'Updating trip status [%] [%] [%]', logbook_id, NEW.status, NEW.time;
                UPDATE api.logbook 
                    SET 
                        active = false, 
                        _to_time = NEW.time,
                        _to_lat = NEW.latitude,
                        _to_lng = NEW.longitude
                    WHERE id = logbook_id;
                -- Add logbook entry to process queue for later processing
                INSERT INTO process_queue (channel, payload, stored) values ('new_logbook', logbook_id, now());
            ELSE
                RAISE WARNING 'Invalid logbook_id [%] [%]', logbook_id, NEW.time;
            END IF;
        END IF;
        RETURN NEW; -- Finally insert the actual new metric
    END;
$metrics$ LANGUAGE plpgsql;
-- Description
COMMENT ON FUNCTION
    public.metrics_trigger_fn
    IS 'process metrics from vessel, generate new_logbook and new_stay';

--
-- Triggers logbook update on metrics insert
CREATE TRIGGER metrics_trigger BEFORE INSERT ON api.metrics
    FOR EACH ROW EXECUTE FUNCTION metrics_trigger_fn();
-- Description
COMMENT ON TRIGGER 
    metrics_trigger ON api.metrics 
    IS  'BEFORE INSERT ON api.metrics run function metrics_trigger_fn';

---------------------------------------------------------------------------
-- API helper functions
--
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Functions API schema
-- Export a log entry to geojson
DROP FUNCTION IF EXISTS api.export_logbook_geojson_point_fn;
CREATE OR REPLACE FUNCTION api.export_logbook_geojson_point_fn(IN _id INTEGER, OUT geojson JSON) RETURNS JSON AS $export_logbook_geojson_point$
    DECLARE
        logbook_rec record;
    BEGIN
        -- If _id is is not NULL and > 0
        SELECT * INTO logbook_rec
            FROM api.logbook WHERE id = _id;
        
        WITH log AS (
            SELECT m.time as time, m.latitude as lat, m.longitude as lng, m.courseOverGroundTrue as cog
            FROM api.metrics m
            WHERE m.latitude IS NOT null
                AND m.longitude IS NOT null
                AND m.time >= logbook_rec._from_time::timestamp without time zone
                AND m.time <= logbook_rec._to_time::timestamp without time zone
            GROUP by m.time,m.latitude,m.longitude,m.courseOverGroundTrue
            ORDER BY m.time ASC)
        SELECT json_build_object(
            'type', 'FeatureCollection',
            'crs',  json_build_object(
                'type',      'name', 
                'properties', json_build_object(
                    'name', 'EPSG:4326'  
                )
            ), 
            'features', json_agg(
                json_build_object(
                    'type',       'Feature',
                --   'id',         {id}, -- the GeoJson spec includes an 'id' field, but it is optional, replace {id} with your id field
                    'geometry',   ST_AsGeoJSON(st_makepoint(lng,lat))::json,
                    'properties', json_build_object(
                        -- list of fields
                        'field1', time,
                        'field2', cog
                    )
                )
            )
        ) INTO geojson
        FROM log;
    END;
$export_logbook_geojson_point$ LANGUAGE plpgsql;
-- Description
COMMENT ON FUNCTION
    api.export_logbook_geojson_point_fn
    IS 'Export a log entry to geojson feature point with Time and courseOverGroundTrue properties';

-- Export a log entry to geojson
DROP FUNCTION IF EXISTS api.export_logbook_geojson_linestring_fn;
CREATE FUNCTION api.export_logbook_geojson_linestring_fn(IN _id INTEGER) RETURNS JSON AS $export_logbook_geojson_linestring$
    DECLARE
        geojson json;
    BEGIN
        -- If _id is is not NULL and > 0
        SELECT ST_AsGeoJSON(l.*) INTO geojson
            FROM api.logbook l 
            WHERE l.id = _id;
        RETURN geojson;
    END;
$export_logbook_geojson_linestring$ LANGUAGE plpgsql;
-- Description
COMMENT ON FUNCTION
    api.export_logbook_geojson_linestring_fn
    IS 'Export a log entry to geojson feature linestring';

-- export_logbook_geojson_fn
DROP FUNCTION IF EXISTS api.export_logbook_geojson_fn;
CREATE FUNCTION api.export_logbook_geojson_fn(IN _id integer, OUT geojson JSON) RETURNS JSON AS $export_logbook_geojson$
    DECLARE
        logbook_rec record;
        log_geojson jsonb;
        metrics_geojson jsonb;
        _map jsonb;
    BEGIN
        -- Gather log details
        -- If _id is is not NULL and > 0
        SELECT * INTO logbook_rec
            FROM api.logbook WHERE id = _id;
		-- GeoJson Feature Logbook linestring
	    SELECT
		  ST_AsGeoJSON(l.*) into log_geojson
		FROM
		  api.logbook l
		WHERE l.id = _id;
		-- GeoJson Feature Metrics point
		SELECT
		  json_agg(ST_AsGeoJSON(t.*)::json) into metrics_geojson
		FROM (
		  ( SELECT
                time,
                courseovergroundtrue,
                speedoverground,
                anglespeedapparent,
                longitude,latitude,
                st_makepoint(longitude,latitude) AS geo_point
		    FROM api.metrics m
		    WHERE m.latitude IS NOT NULL
		        AND m.longitude IS NOT NULL
                AND time >= logbook_rec._from_time::TIMESTAMP WITHOUT TIME ZONE
                AND time <= logbook_rec._to_time::TIMESTAMP WITHOUT TIME ZONE
		    ORDER BY m.time ASC
		   )
		) AS t;

		-- Merge jsonb
		select log_geojson::jsonb || metrics_geojson::jsonb into _map;
        -- output
	    SELECT
        json_build_object(
            'type', 'FeatureCollection',
            'features', _map
        ) into geojson;
    END;
$export_logbook_geojson$ LANGUAGE plpgsql;
-- Description
COMMENT ON FUNCTION
    api.export_logbook_geojson_fn
    IS 'Export a log entry to geojson feature linestring and multipoint';

-- Generate GPX XML file output
-- https://opencpn.org/OpenCPN/info/gpxvalidation.html
--
DROP FUNCTION IF EXISTS api.export_logbook_gpx_fn;
CREATE OR REPLACE FUNCTION api.export_logbook_gpx_fn(IN _id INTEGER) RETURNS pg_catalog.xml
AS $export_logbook_gpx$
    DECLARE
        log_rec record;
    BEGIN
        -- Gather log details _from_time and _to_time
        SELECT * into log_rec
            FROM
            api.logbook l
            WHERE l.id = _id;
        -- Generate XML
        RETURN xmlelement(name gpx,
                            xmlattributes(  '1.1' as version,
                                            'PostgSAIL' as creator,
                                            'http://www.topografix.com/GPX/1/1' as xmlns,
                                            'http://www.opencpn.org' as "xmlns:opencpn",
                                            'http://www.w3.org/2001/XMLSchema-instance' as "xmlns:xsi",
                                            'http://www.garmin.com/xmlschemas/GpxExtensions/v3' as "xmlns:gpxx",
                                            'http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd http://www.garmin.com/xmlschemas/GpxExtensions/v3 http://www8.garmin.com/xmlschemas/GpxExtensionsv3.xsd' as "xsi:schemaLocation"),
                xmlelement(name trk,
                    xmlelement(name name, 'Track Name'),
                    xmlelement(name desc, 'Track Description'),
                    xmlelement(name link, xmlattributes('https://openplotter.cloud/log/{_id}' as href),
                                                xmlelement(name text, 'Link name')),
                    xmlelement(name extensions, xmlelement(name "opencpn:guid", uuid_generate_v4()),
                                                xmlelement(name "opencpn:viz", '1'),
                                                xmlelement(name "opencpn:start", log_rec._from_time),
                                                xmlelement(name "opencpn:end", log_rec._to_time)
                                                ),
                    xmlelement(name trkseg, xmlagg(
                                                xmlelement(name trkpt,
                                                    xmlattributes(latitude  as lat, longitude as lon),
                                                        xmlelement(name time, time)
                                                )))))::pg_catalog.xml
            FROM api.metrics m
            WHERE m.latitude IS NOT null
                AND m.longitude IS NOT null
                AND m.time >= log_rec._from_time::TIMESTAMP WITHOUT TIME ZONE
                AND m.time <= log_rec._to_time::TIMESTAMP WITHOUT TIME ZONE;
    END;
$export_logbook_gpx$ LANGUAGE plpgsql;
-- Description
COMMENT ON FUNCTION
    api.export_logbook_gpx_fn
    IS 'Export a log entry to GPX XML format';

-- Find all log from and to moorage geopoint within 100m
DROP FUNCTION IF EXISTS api.find_log_from_moorage_fn;
CREATE FUNCTION api.find_log_from_moorage_fn(IN _id INTEGER) RETURNS void AS $find_log_from_moorage$
    DECLARE
        moorage_rec record;
        logbook_rec record;
    BEGIN
        -- If _id is is not NULL and > 0
        SELECT * INTO moorage_rec
            FROM api.moorages m 
            WHERE m.id = _id;
        -- find all log from and to moorage geopoint within 100m
        --RETURN QUERY
            SELECT id,name,_from,_to,_from_time,_to_time,distance,duration
                FROM api.logbook
                WHERE ST_DWithin(
                        Geography(ST_MakePoint(_from_lng, _from_lat)),
                        moorage_rec.geog,
                        100 -- in meters ?
                    )
                    OR ST_DWithin(
                        Geography(ST_MakePoint(_to_lng, _to_lat)),
                        moorage_rec.geog,
                        100 -- in meters ?
                    )
                ORDER BY _from_time DESC;
    END;
$find_log_from_moorage$ LANGUAGE plpgsql;
-- Description
COMMENT ON FUNCTION
    api.find_log_from_moorage_fn
    IS 'Find all log from and to moorage geopoint within 100m';

-- Find all stay within 100m of moorage geopoint
DROP FUNCTION IF EXISTS api.find_stay_from_moorage_fn;
CREATE FUNCTION api.find_stay_from_moorage_fn(IN _id INTEGER) RETURNS void AS $find_stay_from_moorage$
    DECLARE
        moorage_rec record;
        stay_rec record;
    BEGIN
        -- If _id is is not NULL and > 0
        SELECT * INTO moorage_rec
            FROM api.moorages m 
            WHERE m.id = _id;
        -- find all log from and to moorage geopoint within 100m
        --RETURN QUERY
            SELECT s.id,s.arrived,s.departed,s.duration,sa.description
                FROM api.stays s, api.stays_at sa
                WHERE ST_DWithin(
                        s.geog,
                        moorage_rec.geog,
                        100 -- in meters ?
                    )
                    AND departed IS NOT NULL
                    AND s.name IS NOT NULL
                    AND s.stay_code = sa.stay_code
                ORDER BY s.arrived DESC;
    END;
$find_stay_from_moorage$ LANGUAGE plpgsql;
-- Description
COMMENT ON FUNCTION
    api.find_stay_from_moorage_fn
    IS 'Find all stay within 100m of moorage geopoint';

---------------------------------------------------------------------------
-- API helper view
--
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Views
-- Views are invoked with the privileges of the view owner,
-- make the user_role the view’s owner.
---------------------------------------------------------------------------

CREATE VIEW first_metric AS
    SELECT * 
        FROM api.metrics
        ORDER BY time ASC LIMIT 1;

CREATE VIEW last_metric AS
    SELECT * 
        FROM api.metrics
        ORDER BY time DESC LIMIT 1;

CREATE VIEW trip_in_progress AS
    SELECT * 
        FROM api.logbook 
        WHERE active IS true;

CREATE VIEW stay_in_progress AS
    SELECT * 
        FROM api.stays 
        WHERE active IS true;

-- TODO: Use materialized views instead as it is not live data
-- Logs web view
DROP VIEW IF EXISTS api.logs_view;
CREATE OR REPLACE VIEW api.logs_view AS
    SELECT id,
            name as "Name",
            _from as "From",
            _from_time as "Started",
            _to as "To",
            _to_time as "Ended",
            distance as "Distance",
            duration as "Duration"
        FROM api.logbook l
        WHERE _to_time IS NOT NULL
        ORDER BY _from_time DESC;
-- Description
COMMENT ON VIEW
    api.logs_view
    IS 'Logs web view';

DROP VIEW IF EXISTS api.log_view;
CREATE OR REPLACE VIEW api.log_view AS
    SELECT id,
            name as "Name",
            _from as "From",
            _from_time as "Started",
            _to as "To",
            _to_time as "Ended",
            distance as "Distance",
            duration as "Duration",
            notes as "Notes",
            track_geojson as geojson,
            avg_speed as avg_speed,
            max_speed as max_speed,
            max_wind_speed as max_wind_speed
        FROM api.logbook l
        WHERE _to_time IS NOT NULL
        ORDER BY _from_time DESC;
-- Description
COMMENT ON VIEW
    api.logs_view
    IS 'Log web view';

-- Stays web view
-- TODO group by month
DROP VIEW IF EXISTS api.stays_view;
CREATE VIEW api.stays_view AS
    SELECT 
        concat(
            extract(DAYS FROM (s.departed-s.arrived)::interval),
    	    ' days',
            --DATE_TRUNC('day', s.departed-s.arrived),
            ' stay at ',
            s.name,
            ' in ',
            RTRIM(TO_CHAR(s.departed, 'Month')),
            ' ',
            TO_CHAR(s.departed, 'YYYY')
            ) as Name,  
		s.name AS Moorage,
		s.arrived AS Arrived,
		s.departed AS Departed,
		sa.description AS "Stayed at",
		(s.departed-s.arrived) AS Duration
	FROM api.stays s, api.stays_at sa
	WHERE departed is not null 
        AND s.name is not null 
        AND s.stay_code = sa.stay_code
    ORDER BY s.arrived DESC;
-- Description
COMMENT ON VIEW
    api.stays_view
    IS 'Stays web view';

-- Moorages web view
-- TODO, this is wrong using distinct (m.name) should be using postgis geog feature
--DROP VIEW IF EXISTS api.moorages_view_old;
--CREATE VIEW api.moorages_view_old AS
--    SELECT
--        m.name AS Moorage,
--        sa.description AS "Default Stay",
--        sum((m.departed-m.arrived)) OVER (PARTITION by m.name) AS "Total Stay",
--        count(m.departed) OVER (PARTITION by m.name) AS "Arrivals & Departures"
--    FROM api.moorages m, api.stays_at sa
--    WHERE departed is not null 
--        AND m.name is not null
--        AND m.stay_code = sa.stay_code
--    GROUP BY m.name,sa.description,m.departed,m.arrived
--    ORDER BY 4 DESC;

-- the good way?
DROP VIEW IF EXISTS api.moorages_view;
CREATE OR REPLACE VIEW api.moorages_view AS
    SELECT
        m.name AS Moorage,
        sa.description AS "Default Stay",
        EXTRACT(DAY FROM justify_hours ( m.stay_duration )) AS "Total Stay",
        m.reference_count AS "Arrivals & Departures",
        m.geog
--        m.stay_duration,
--        justify_hours ( m.stay_duration )
    FROM api.moorages m, api.stays_at sa
    WHERE m.name is not null
        AND m.stay_code = sa.stay_code
   GROUP BY m.name,sa.description,m.stay_duration,m.reference_count,m.geog
--   ORDER BY 4 DESC;
   ORDER BY m.reference_count DESC;
-- Description
COMMENT ON VIEW
    api.moorages_view
    IS 'Moorages web view';

-- All moorage in 100 meters from the start of a logbook.
-- ST_DistanceSphere Returns minimum distance in meters between two lon/lat points.
--SELECT
--    m.name, ST_MakePoint(m._lng,m._lat),
--    l._from, ST_MakePoint(l._from_lng,l._from_lat),
--    ST_DistanceSphere(ST_MakePoint(m._lng,m._lat), ST_MakePoint(l._from_lng,l._from_lat))
--    FROM  api.moorages m , api.logbook l 
--    WHERE ST_DistanceSphere(ST_MakePoint(m._lng,m._lat), ST_MakePoint(l._from_lng,l._from_lat)) <= 100;

-- Stats web view
-- TODO....
-- first time entry from metrics
----> select * from api.metrics m ORDER BY m.time desc limit 1
-- last time entry from metrics
----> select * from api.metrics m ORDER BY m.time asc limit 1
-- max speed from logbook
-- max wind speed from logbook
----> select max(l.max_speed) as max_speed, max(l.max_wind_speed) as max_wind_speed from api.logbook l;
-- Total Distance from logbook
----> select sum(l.distance) as "Total Distance" from api.logbook l;
-- Total Time Underway from logbook
----> select sum(l.duration) as "Total Time Underway" from api.logbook l;
-- Longest Nonstop Sail from logbook, eg longest trip duration and distance
----> select max(l.duration),max(l.distance) from api.logbook l;
CREATE VIEW api.stats_logs_view AS -- todo
    WITH
        meta AS ( 
            SELECT m.name FROM api.metadata m ),
        last_metric AS ( 
            SELECT m.time FROM api.metrics m ORDER BY m.time DESC limit 1),
        first_metric AS (
            SELECT m.time FROM api.metrics m ORDER BY m.time ASC limit 1),
        logbook AS (
            SELECT
                count(*) AS "Number of Log Entries",
                max(l.max_speed) AS "Max Speed",
                max(l.max_wind_speed) AS "Max Wind Speed",
                sum(l.distance) AS "Total Distance",
                sum(l.duration) AS "Total Time Underway",
                concat( max(l.distance), ' NM, ', max(l.duration), ' hours') AS "Longest Nonstop Sail"
            FROM api.logbook l)
    SELECT
        m.name as Name,
        fm.time AS first,
        lm.time AS last,
        l.* 
    FROM first_metric fm, last_metric lm, logbook l, meta m;

-- Home Ports / Unique Moorages
----> select count(*) as "Home Ports" from api.moorages m where home_flag is true;
-- Unique Moorages
----> select count(*) as "Home Ports" from api.moorages m;
-- Time Spent at Home Port(s)
----> select sum(m.stay_duration) as "Time Spent at Home Port(s)" from api.moorages m where home_flag is true;
-- OR
----> select m.stay_duration as "Time Spent at Home Port(s)" from api.moorages m where home_flag is true;
-- Time Spent Away
----> select sum(m.stay_duration) as "Time Spent Away" from api.moorages m where home_flag is false;
-- Time Spent Away order by, group by stay_code (Dock, Anchor, Mooring Buoys, Unclassified)
----> select sa.description,sum(m.stay_duration) as "Time Spent Away" from api.moorages m, api.stays_at sa where home_flag is false AND m.stay_code = sa.stay_code group by m.stay_code,sa.description order by m.stay_code;
CREATE VIEW api.stats_moorages_view AS -- todo
    select *
        from api.moorages;

--CREATE VIEW api.stats_view AS -- todo
--    WITH
--        logs AS ( 
--            SELECT * FROM api.stats_logs_view ),
--        moorages AS ( 
--            SELECT * FROM api.stats_moorages_view)
--    SELECT
--        l.*,
--        m.* 
--    FROM logs l, moorages m;

-- global timelapse
-- TODO
CREATE VIEW timelapse AS -- todo
    SELECT latitude, longitude from api.metrics;

-- View main monitoring for grafana
-- LAST Monitoring data from json!
CREATE VIEW api.monitoring AS
    SELECT 
        time AS "time",
        metrics-> 'environment.water.temperature' AS waterTemperature,
        metrics-> 'environment.inside.temperature' AS insideTemperature,
        metrics-> 'environment.outside.temperature' AS outsideTemperature,
        metrics-> 'environment.wind.speedOverGround' AS windSpeedOverGround,
        metrics-> 'environment.wind.directionGround' AS windDirectionGround,
        metrics-> 'environment.inside.humidity' AS insideHumidity,
        metrics-> 'environment.outside.humidity' AS outsideHumidity,
        metrics-> 'environment.outside.pressure' AS outsidePressure,
        metrics-> 'environment.inside.pressure' AS insidePressure
    FROM api.metrics m 
    ORDER BY time DESC LIMIT 1;

CREATE VIEW api.monitoring_humidity AS
    SELECT 
        time AS "time",
        metrics-> 'environment.inside.humidity' AS insideHumidity,
        metrics-> 'environment.outside.humidity' AS outsideHumidity
    FROM api.metrics m 
    ORDER BY time DESC LIMIT 1;

-- View System RPI monitoring for grafana
-- View Electric monitoring for grafana

-- View main monitoring for grafana
-- LAST Monitoring data from json!
CREATE VIEW api.monitorin_temperatures AS
    SELECT 
        time AS "time",
        metrics-> 'environment.water.temperature' AS waterTemperature,
        metrics-> 'environment.inside.temperature' AS insideTemperature,
        metrics-> 'environment.outside.temperature' AS outsideTemperature
    FROM api.metrics m 
    ORDER BY time DESC LIMIT 1;

-- json key regexp
-- https://stackoverflow.com/questions/38204467/selecting-for-a-jsonb-array-contains-regex-match
-- Last voltage data from json!
CREATE VIEW api.voltage AS
    SELECT
        time AS "time",
        cast(metrics-> 'electrical.batteries.AUX2.voltage' AS numeric) AS AUX2,
        cast(metrics-> 'electrical.batteries.House.voltage' AS numeric) AS House,
        cast(metrics-> 'environment.rpi.pijuice.gpioVoltage' AS numeric) AS gpioVoltage,
        cast(metrics-> 'electrical.batteries.Seatalk.voltage' AS numeric) AS SeatalkVoltage,
        cast(metrics-> 'electrical.batteries.Starter.voltage' AS numeric) AS StarterVoltage,
        cast(metrics-> 'environment.rpi.pijuice.batteryVoltage' AS numeric) AS RPIBatteryVoltage,
        cast(metrics-> 'electrical.batteries.victronDevice.voltage' AS numeric) AS victronDeviceVoltage
    FROM api.metrics m 
    ORDER BY time DESC LIMIT 1;
