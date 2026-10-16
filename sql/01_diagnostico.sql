-- =====================================================================
-- GEOPORTAL EOT ARGELIA (VALLE) - SCRIPT 01: DIAGNÓSTICO (SOLO LECTURA)
-- ---------------------------------------------------------------------
-- Ejecutar en Supabase > SQL Editor > New query > Run.
-- NO modifica nada. Devuelve una sola tabla (seccion | elemento | detalle)
-- porque el editor de Supabase solo muestra el resultado de la última
-- consulta. Descargue el resultado (botón "Export > CSV") y consérvelo:
-- la sección "5_RESPALDO" contiene el código fuente de las funciones
-- actuales, útil para revertir si fuera necesario.
-- =====================================================================

-- En Supabase, PostGIS está instalado en el esquema "extensions"
set search_path = public, extensions;

with funciones as (
  select p.oid, p.proname::text as nombre
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('list_tables', 'get_geojson', 'buscar_predios_pro', 'analizar_predio_completo')
)

-- 1. Extensión PostGIS y esquema donde está instalada
select '1_POSTGIS'::text as seccion,
       e.extname::text as elemento,
       'versión ' || e.extversion || ' en esquema ' || n.nspname as detalle
from pg_extension e
join pg_namespace n on n.oid = e.extnamespace
where e.extname = 'postgis'

union all
-- 2. Capas espaciales registradas (columna geométrica, SRID y tipo)
select '2_CAPAS',
       c.relnamespace::regnamespace::text || '.' || c.relname,
       'geom=' || a.attname
         || ' | srid=' || coalesce(postgis_typmod_srid(a.atttypmod)::text, '?')
         || ' | tipo=' || coalesce(postgis_typmod_type(a.atttypmod), '?')
         || ' | filas≈' || greatest(c.reltuples, 0)::bigint
         || ' | rls=' || case when c.relrowsecurity then 'ACTIVO' else 'inactivo' end
from pg_attribute a
join pg_class c on c.oid = a.attrelid
join pg_type t on t.oid = a.atttypid
where t.typname = 'geometry'
  and a.attnum > 0 and not a.attisdropped
  and c.relkind in ('r', 'v', 'm', 'p')
  and c.relnamespace::regnamespace::text not in ('extensions', 'pg_catalog', 'information_schema')

union all
-- 3. Columnas de la capa de Catastro (para mapear NPN / dirección)
select '3_COLUMNAS_CATASTRO',
       column_name::text,
       data_type::text
from information_schema.columns
where table_schema = 'public' and table_name = 'catarg_va2025wgs84'

union all
-- 4. Funciones RPC que usa el geoportal: firma, retorno y permisos
select '4_FUNCIONES',
       f.nombre || '(' || pg_get_function_identity_arguments(f.oid) || ')',
       'retorna ' || pg_get_function_result(f.oid)
         || ' | security_definer=' || p.prosecdef
         || ' | anon_puede_ejecutar=' || has_function_privilege('anon', f.oid, 'execute')
from funciones f
join pg_proc p on p.oid = f.oid

union all
-- 4b. Funciones que el geoportal necesita y NO existen
select '4_FUNCIONES_FALTANTES', req.nombre, 'NO EXISTE en el esquema public'
from (values ('list_tables'), ('get_geojson'), ('buscar_predios_pro'), ('analizar_predio_completo')) req(nombre)
where not exists (select 1 from funciones f where f.nombre = req.nombre)

union all
-- 5. Respaldo del código fuente actual de las funciones
select '5_RESPALDO', f.nombre, pg_get_functiondef(f.oid)
from funciones f

union all
-- 6. Tiempo máximo de consulta de los roles de la API
select '6_ROLES', r.rolname::text, coalesce(array_to_string(r.rolconfig, '; '), '(sin configuración propia: 3s por defecto en anon)')
from pg_roles r
where r.rolname in ('anon', 'authenticated', 'authenticator')

order by 1, 2;
