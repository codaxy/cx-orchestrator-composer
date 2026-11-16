-- Create get_pg_shadow_pass function in template1 and all application databases
-- This script uses dblink to connect to each database and create the function

DO
$$
DECLARE
    db_name text;
    conn_name text;
    databases text[] := ARRAY[
        'postgres',
        'template1',
        'admin_portal',
        'audit',
        'customer_management',
        'cxo_settings',
        'digital_identity',
        'event_management',
        'geographic_address_management',
        'geographic_location_management',
        'geographic_site_management',
        'locking_management',
        'party_management',
        'party_role_management',
        'resource_catalog_management',
        'resource_inventory_management',
        'resource_order_management',
        'resource_ordering_engine',
        'resource_pool_management',
        'service_activation_management',
        'service_catalog_management',
        'service_inventory_management',
        'service_order_management',
        'service_ordering_engine',
        'user_roles_and_permissions'
    ];
    function_sql text;
BEGIN
    -- SQL to create the function
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

    -- Create function in each database
    FOREACH db_name IN ARRAY databases
    LOOP
        BEGIN
            -- Check if database exists before trying to create function
            IF EXISTS (SELECT 1 FROM pg_database WHERE datname = db_name) THEN
                -- Create a named connection
                conn_name := 'conn_' || replace(db_name, '-', '_');
                
                -- Connect to the database
                PERFORM dblink_connect(conn_name, format('dbname=%s user=postgres password=postgres', db_name));
                
                -- Execute the function creation SQL
                PERFORM dblink_exec(conn_name, function_sql);
                
                -- Disconnect
                PERFORM dblink_disconnect(conn_name);
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                -- Try to disconnect if connection was made
                BEGIN
                    PERFORM dblink_disconnect(conn_name);
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
                -- Continue with next database if this one fails
                RAISE NOTICE 'Failed to create function in database %: %', db_name, SQLERRM;
        END;
    END LOOP;
END;
$$;

