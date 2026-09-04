-- Las dos bases del dominio en un unico servidor.
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

-- El esquema de mto-configuration ------------------------------------------------------------
--
-- Flyway esta configurado con default-schema y schemas y sabe crearlo, pero necesita privilegios
-- sobre la base entera para ello. Se crea aqui con el dueño correcto para no tener que darselos.
-- mto-stock usa el esquema public de su propia base y no necesita nada equivalente.

\connect :configuration_db

SELECT format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', :'configuration_schema', :'configuration_user')
\gexec
