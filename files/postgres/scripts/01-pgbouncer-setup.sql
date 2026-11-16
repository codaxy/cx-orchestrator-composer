-- secure_pgbouncer_user.sql
-- Step 1: Create the PgBouncer user (non-superuser)
DO
$$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer'
    ) THEN
        CREATE ROLE pgbouncer LOGIN PASSWORD 'pgbouncer';
    END IF;
END
$$;

-- Step 2: Enable dblink extension to allow connecting to other databases
CREATE EXTENSION IF NOT EXISTS dblink;

-- Step 3: Create the function in template1 so new databases will inherit it
-- This must happen before databases are created in script 02
DO
$$
DECLARE
    function_sql text;
    conn_name text := 'conn_template1';
BEGIN
    function_sql := '
        DROP FUNCTION IF EXISTS public.get_pg_shadow_pass(text);
        DROP FUNCTION IF EXISTS public.get_pg_shadow_pass(name);
        CREATE OR REPLACE FUNCTION public.get_pg_shadow_pass(username text)
        RETURNS TABLE(usename name, passwd text)
        LANGUAGE sql
        SECURITY DEFINER
        STABLE
        AS $func$
            SELECT usename::name, passwd::text
            FROM pg_shadow
            WHERE usename = username::name;
        $func$;
        ALTER FUNCTION public.get_pg_shadow_pass(text) OWNER TO postgres;
        GRANT EXECUTE ON FUNCTION public.get_pg_shadow_pass(text) TO pgbouncer;
    ';

    BEGIN
        PERFORM dblink_connect(conn_name, 'dbname=template1 user=postgres password=postgres');
        PERFORM dblink_exec(conn_name, function_sql);
        PERFORM dblink_disconnect(conn_name);
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN
                PERFORM dblink_disconnect(conn_name);
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
            -- Continue even if this fails - script 03 will create it
            RAISE NOTICE 'Could not create function in template1: %', SQLERRM;
    END;
END;
$$;
