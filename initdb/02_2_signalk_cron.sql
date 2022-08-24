---------------------------------------------------------------------------
-- cron job function helpers on public schema
--

-- List current database
select current_database();

-- connect to the DB
\c signalk

-- Check for new logbook pending update
CREATE FUNCTION cron_process_new_logbook_fn() RETURNS void AS $$
declare
    process_rec record;
begin
    -- Check for new logbook pending update
    RAISE NOTICE 'cron_process_new_logbook_fn';
    FOR process_rec in 
        SELECT * FROM process_queue 
            WHERE channel = 'new_logbook' AND processed IS NULL
            ORDER BY stored ASC
    LOOP
        RAISE NOTICE '-> cron_process_new_logbook_fn [%]', process_rec.payload;
        -- update logbook
        PERFORM process_logbook_queue_fn(process_rec.payload::INTEGER);
        -- update process_queue table , processed
        UPDATE process_queue 
            SET 
                processed = NOW()
            WHERE id = process_rec.id;
        RAISE NOTICE '-> updated process_queue table [%]', process_rec.id;
    END LOOP;
END;
$$ language plpgsql;
-- Description
COMMENT ON FUNCTION
    public.cron_process_new_logbook_fn
    IS 'init by pg_cron to check for new logbook pending update, if so perform process_logbook_queue_fn';

-- Check for new stay pending update
CREATE FUNCTION cron_process_new_stay_fn() RETURNS void AS $$
declare
    process_rec record;
begin
    -- Check for new stay pending update
    RAISE NOTICE 'cron_process_new_stay_fn';
    FOR process_rec in 
        SELECT * FROM process_queue 
            WHERE channel = 'new_stay' AND processed IS NULL
            ORDER BY stored ASC
    LOOP
        RAISE NOTICE '-> cron_process_new_stay_fn [%]', process_rec.payload;
        -- update stay
        PERFORM process_stay_queue_fn(process_rec.payload::INTEGER);
        -- update process_queue table , processed
        UPDATE process_queue 
            SET 
                processed = NOW()
            WHERE id = process_rec.id;
        RAISE NOTICE '-> updated process_queue table [%]', process_rec.id;
    END LOOP;
END;
$$ language plpgsql;
-- Description
COMMENT ON FUNCTION
    public.cron_process_new_stay_fn
    IS 'init by pg_cron to check for new stay pending update, if so perform process_stay_queue_fn';

-- Check for new moorage pending update
DROP FUNCTION IF EXISTS cron_process_new_moorage_fn;
CREATE OR REPLACE FUNCTION cron_process_new_moorage_fn() RETURNS void AS $$
declare
    process_rec record;
begin
    -- Check for new moorage pending update
    RAISE NOTICE 'cron_process_new_moorage_fn';
    FOR process_rec in 
        SELECT * FROM process_queue 
            WHERE channel = 'new_moorage' AND processed IS NULL
            ORDER BY stored ASC
    LOOP
        RAISE NOTICE '-> cron_process_new_moorage_fn [%]', process_rec.payload;
        -- update moorage
        PERFORM process_moorage_queue_fn(process_rec.payload::INTEGER);
        -- update process_queue table , processed
        UPDATE process_queue 
            SET 
                processed = NOW()
            WHERE id = process_rec.id;
        RAISE NOTICE '-> updated process_queue table [%]', process_rec.id;
    END LOOP;
END;
$$ language plpgsql;
-- Description
COMMENT ON FUNCTION
    public.cron_process_new_moorage_fn
    IS 'init by pg_cron to check for new moorage pending update, if so perform process_moorage_queue_fn';

-- CRON Monitor offline pending notification
create function cron_process_monitor_offline_fn() RETURNS void AS $$
declare
    metadata_rec record;
    process_id integer;
    user_settings jsonb;
    app_settings jsonb;
begin
    -- Check metadata last_update > 1h + cron_time(10m)
    RAISE NOTICE 'cron_process_monitor_offline_fn';
    FOR metadata_rec in 
        SELECT
            *, 
            NOW() AT TIME ZONE 'UTC' as now, 
            NOW() AT TIME ZONE 'UTC' - INTERVAL '70 MINUTES' as interval
        FROM api.metadata m
        WHERE 
            m.time < NOW() AT TIME ZONE 'UTC' - INTERVAL '70 MINUTES'
            AND active = True
        ORDER BY m.time desc
    LOOP
        RAISE NOTICE '-> cron_process_monitor_offline_fn metadata_id [%]', metadata_rec.id;
        -- update api.metadata table, set active to bool false
        UPDATE api.metadata
            SET 
                active = False
            WHERE id = metadata_rec.id;
        RAISE NOTICE '-> updated api.metadata table to inactive for [%]', metadata_rec.id;
        -- Gather email and pushover app settings
        app_settings = get_app_settings_fn();
        -- Gather user settings
        user_settings := get_user_settings_from_metadata_fn(metadata_rec.id::INTEGER);
        --user_settings := get_user_settings_from_clientid_fn(metadata_rec.id::INTEGER);
        RAISE DEBUG '-> debug monitor_offline get_user_settings_from_metadata_fn [%]', user_settings;
        -- Send notification
        --PERFORM send_notification_fn('monitor_offline'::TEXT, metadata_rec::RECORD);
        PERFORM send_email_py_fn('monitor_offline'::TEXT, user_settings::JSONB, app_settings::JSONB);
        --PERFORM send_pushover_py_fn('monitor_offline'::TEXT, user_settings::JSONB, app_settings::JSONB);
        -- log/insert/update process_queue table with processed
        INSERT INTO process_queue
            (channel, payload, stored, processed) 
            VALUES 
                ('monitoring_offline', metadata_rec.id, metadata_rec.interval, now())
            RETURNING id INTO process_id;
        RAISE NOTICE '-> updated process_queue table [%]', process_id;
    END LOOP;
END;
$$ language plpgsql;
-- Description
COMMENT ON FUNCTION 
    public.cron_process_monitor_offline_fn
    IS 'init by pg_cron to monitor offline pending notification, if so perform send_email o send_pushover base on user preferences';

-- CRON for monitor back online pending notification
DROP FUNCTION IF EXISTS cron_process_monitor_online_fn;
CREATE FUNCTION cron_process_monitor_online_fn() RETURNS void AS $$
declare
    process_rec record;
    metadata_rec record;
    user_settings jsonb;
    app_settings jsonb;
begin
    -- Check for monitor online pending notification
    RAISE NOTICE 'cron_process_monitor_online_fn';
    FOR process_rec in 
        SELECT * from process_queue 
            where channel = 'monitoring_online' and processed is null
            order by stored asc
    LOOP
        RAISE NOTICE '-> cron_process_monitor_online_fn metadata_id [%]', process_rec.payload;
        SELECT * INTO metadata_rec 
            FROM api.metadata
            WHERE id = process_rec.payload::INTEGER;
        -- Gather email and pushover app settings
        app_settings = get_app_settings_fn();
        -- Gather user settings
        user_settings := get_user_settings_from_metadata_fn(metadata_rec.id::INTEGER);
        --user_settings := get_user_settings_from_clientid_fn((metadata_rec.client_id::INTEGER, );
        RAISE NOTICE '-> debug monitor_online get_user_settings_from_metadata_fn [%]', user_settings;
        -- Send notification
        --PERFORM send_notification_fn('monitor_online'::TEXT, metadata_rec::RECORD);
        PERFORM send_email_py_fn('monitor_online'::TEXT, user_settings::JSONB, app_settings::JSONB);
        --PERFORM send_pushover_py_fn('monitor_online'::TEXT, user_settings::JSONB, app_settings::JSONB);
        -- update process_queue entry as processed
        UPDATE process_queue 
            SET 
                processed = NOW()
            WHERE id = process_rec.id;
        RAISE NOTICE '-> updated process_queue table [%]', process_rec.id;
    END LOOP;
END;
$$ language plpgsql;
-- Description
COMMENT ON FUNCTION 
    public.cron_process_monitor_online_fn 
    IS 'init by pg_cron to monitor back online pending notification, if so perform send_email or send_pushover base on user preferences';

-- CRON for new account pending notification
CREATE FUNCTION cron_process_new_account_fn() RETURNS void AS $$
declare
    process_rec record;
begin
    -- Check for new account pending update
    RAISE NOTICE 'cron_process_new_account_fn';
    FOR process_rec in 
        SELECT * from process_queue 
            where channel = 'new_account' and processed is null
            order by stored asc
    LOOP
        RAISE NOTICE '-> cron_process_new_account_fn [%]', process_rec.payload;
        -- update account
        PERFORM process_account_queue_fn(process_rec.payload::TEXT);
        -- update process_queue entry as processed
        UPDATE process_queue 
            SET 
                processed = NOW()
            WHERE id = process_rec.id;
        RAISE NOTICE '-> updated process_queue table [%]', process_rec.id;
    END LOOP;
END;
$$ language plpgsql;
-- Description
COMMENT ON FUNCTION 
    public.cron_process_new_account_fn 
    IS 'init by pg_cron to check for new account pending update, if so perform process_account_queue_fn';

-- CRON for new vessel pending notification
CREATE FUNCTION cron_process_new_vessel_fn() RETURNS void AS $$
declare
    process_rec record;
begin
    -- Check for new vessel pending update
    RAISE NOTICE 'cron_process_new_vessel_fn';
    FOR process_rec in 
        SELECT * from process_queue 
            where channel = 'new_vessel' and processed is null
            order by stored asc
    LOOP
        RAISE NOTICE '-> cron_process_new_vessel_fn [%]', process_rec.payload;
        -- update vessel
        PERFORM process_vessel_queue_fn(process_rec.payload::TEXT);
        -- update process_queue entry as processed
        UPDATE process_queue 
            SET 
                processed = NOW()
            WHERE id = process_rec.id;
        RAISE NOTICE '-> updated process_queue table [%]', process_rec.id;
    END LOOP;
END;
$$ language plpgsql;
-- Description
COMMENT ON FUNCTION 
    public.cron_process_new_vessel_fn 
    IS 'init by pg_cron to check for new vessel pending update, if so perform process_vessel_queue_fn';

-- CRON for Vacuum database
CREATE FUNCTION cron_vaccum_fn() RETURNS void AS $$
declare
begin
    -- Vacuum
    RAISE NOTICE 'cron_vaccum_fn';
    VACUUM (FULL, VERBOSE, ANALYZE, INDEX_CLEANUP) api.logbook;
    VACUUM (FULL, VERBOSE, ANALYZE, INDEX_CLEANUP) api.stays;
    VACUUM (FULL, VERBOSE, ANALYZE, INDEX_CLEANUP) api.moorages;
    VACUUM (FULL, VERBOSE, ANALYZE, INDEX_CLEANUP) api.metrics;
    VACUUM (FULL, VERBOSE, ANALYZE, INDEX_CLEANUP) api.metadata;
END;
$$ language plpgsql;
-- Description
COMMENT ON FUNCTION 
    public.cron_vaccum_fn
    IS 'init by pg_cron to full vaccum tables on schema api';
