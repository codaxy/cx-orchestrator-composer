-- Create databases if they do not exist

-- Tier 1
CREATE DATABASE service_inventory_management;
CREATE DATABASE resource_inventory_management;
CREATE DATABASE service_order_management;
CREATE DATABASE resource_order_management;

-- Tier 2
CREATE DATABASE admin_portal;
CREATE DATABASE audit;
CREATE DATABASE event_management;
CREATE DATABASE geographic_address_management;
CREATE DATABASE geographic_location_management;
CREATE DATABASE geographic_site_management;
CREATE DATABASE resource_catalog_management;
CREATE DATABASE resource_ordering_engine;
CREATE DATABASE resource_pool_management;
CREATE DATABASE service_catalog_management;
CREATE DATABASE service_ordering_engine;
CREATE DATABASE service_activation_management;

-- Tier 3
CREATE DATABASE customer_management;
CREATE DATABASE cxo_settings;
CREATE DATABASE digital_identity;
CREATE DATABASE locking_management;
CREATE DATABASE party_management;
CREATE DATABASE party_role_management;
CREATE DATABASE user_roles_and_permissions;
