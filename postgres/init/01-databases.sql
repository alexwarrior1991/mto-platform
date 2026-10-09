-- Las cinco bases del dominio en un unico servidor.
--
-- El contenedor de PostgreSQL ejecuta los ficheros de /docker-entrypoint-initdb.d SOLO en la
-- primera inicializacion, cuando el directorio de datos esta vacio. Si se cambia algo de aqui
-- despues de haber levantado el stack, hay que borrar el volumen para que vuelva a aplicarse:
--
--   docker compose down -v
--
-- El entrypoint no pasa el entorno del contenedor a psql como variables, asi que se leen con
-- \getenv. Y CREATE DATABASE / CREATE ROLE no admiten parametros ni IF NOT EXISTS, de ahi el
-- rodeo con format() + \gexec: la consulta no devuelve ninguna fila si el objeto ya existe, con
-- lo que \gexec no ejecuta nada y el script es reejecutable.

\set ON_ERROR_STOP on

\getenv configuration_db    MTO_CONFIGURATION_DB
\getenv configuration_user  MTO_CONFIGURATION_USER
\getenv configuration_pass  MTO_CONFIGURATION_PASSWORD
\getenv configuration_schema MTO_CONFIGURATION_SCHEMA
\getenv stock_db            MTO_STOCK_DB
\getenv stock_user          MTO_STOCK_USER
\getenv stock_pass          MTO_STOCK_PASSWORD
\getenv maintenance_db      MTO_MAINTENANCE_DB
\getenv maintenance_user    MTO_MAINTENANCE_USER
\getenv maintenance_pass    MTO_MAINTENANCE_PASSWORD
\getenv notification_db     MTO_NOTIFICATION_DB
\getenv notification_user   MTO_NOTIFICATION_USER
\getenv notification_pass   MTO_NOTIFICATION_PASSWORD
\getenv field_db            MTO_FIELD_DB
\getenv field_user          MTO_FIELD_USER
\getenv field_pass          MTO_FIELD_PASSWORD

-- mto-configuration ------------------------------------------------------------------------------

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'configuration_user', :'configuration_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'configuration_user')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'configuration_db', :'configuration_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'configuration_db')
\gexec

-- mto-stock --------------------------------------------------------------------------------------

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'stock_user', :'stock_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'stock_user')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'stock_db', :'stock_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'stock_db')
\gexec

-- mto-maintenance --------------------------------------------------------------------------------

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'maintenance_user', :'maintenance_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'maintenance_user')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'maintenance_db', :'maintenance_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'maintenance_db')
\gexec

-- mto-notification -------------------------------------------------------------------------------
--
-- Anadida despues de las otras tres. Sobre un volumen ya inicializado este fichero no vuelve a
-- ejecutarse solo; es reejecutable, asi que basta con pasarselo a psql dentro del contenedor una
-- vez recreado 'postgres' con las variables nuevas (vease README.md, "Una base nueva en un stack
-- ya levantado").

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'notification_user', :'notification_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'notification_user')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'notification_db', :'notification_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'notification_db')
\gexec

-- mto-field --------------------------------------------------------------------------------------
--
-- Anadida despues de las otras cuatro, como la de mto-notification: sobre un volumen ya inicializado
-- hay que pasarle este fichero a psql dentro del contenedor (vease README.md).

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'field_user', :'field_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'field_user')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'field_db', :'field_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'field_db')
\gexec

-- El esquema de mto-configuration ------------------------------------------------------------
--
-- Flyway esta configurado con default-schema y schemas y sabe crearlo, pero necesita privilegios
-- sobre la base entera para ello. Se crea aqui con el dueño correcto para no tener que darselos.
-- mto-stock, mto-maintenance, mto-notification y mto-field usan el esquema public de su propia base
-- y no necesitan nada equivalente.

\connect :configuration_db

SELECT format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', :'configuration_schema', :'configuration_user')
\gexec
