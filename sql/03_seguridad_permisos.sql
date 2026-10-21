-- =====================================================================
-- GEOPORTAL EOT ARGELIA (VALLE) - SCRIPT 03: SEGURIDAD DE PERMISOS
-- ---------------------------------------------------------------------
-- Responde al aviso de Supabase del 20/10/2026 ("new tables in public
-- need grants from October 30") y cierra el acceso público directo a
-- las tablas.
--
-- QUÉ HACE:
--   1. Quita a los roles públicos (anon, authenticated) la lectura
--      DIRECTA de todas las tablas del esquema public. Hoy cualquiera
--      con la llave pública puede descargar las tablas completas por la
--      API, incluidos campos con datos personales (Ley 1581 de 2012).
--   2. Deja ese mismo comportamiento para las tablas que se creen en el
--      futuro (lo que Supabase hará por defecto desde el 30/10/2026).
--   3. Confirma el permiso de ejecución de las 4 funciones del visor.
--
-- POR QUÉ EL GEOPORTAL SIGUE FUNCIONANDO:
--   El visor nunca lee las tablas directamente: solo llama a las 4
--   funciones del script 02, que se ejecutan con los permisos de su
--   propietario (SECURITY DEFINER), filtran datos personales y siguen
--   viendo todas las capas, incluidas las que se carguen después.
--
-- NO afecta al rol service_role ni al panel de Supabase.
-- Requisito: haber ejecutado antes 02_funciones_geoportal.sql.
-- Es idempotente: puede ejecutarse varias veces.
--
-- REVERSIÓN (solo si otra aplicación necesitaba leer tablas):
--   grant select on all tables in schema public to anon, authenticated;
--   (y si se necesitaba el permiso general: ... to public;)
-- =====================================================================

-- 1. Retira el acceso directo a tablas, vistas y secuencias existentes.
--    Incluye PUBLIC ("todo el mundo"): algunas herramientas de carga de
--    capas (p. ej. QGIS) otorgan lectura a PUBLIC, que anon hereda.
revoke all on all tables in schema public from anon, authenticated, public;
revoke all on all sequences in schema public from anon, authenticated, public;

-- 2. Mismo comportamiento para objetos que se creen en el futuro
--    (aplica a los creados por el usuario postgres: panel, SQL Editor,
--    QGIS u ogr2ogr con la conexión principal)
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated, public;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated, public;

-- 3. Las funciones del visor siguen disponibles para el público
grant usage on schema public to anon, authenticated;
grant execute on function public.list_tables() to anon, authenticated;
grant execute on function public.get_geojson(text) to anon, authenticated;
grant execute on function public.buscar_predios_pro(text) to anon, authenticated;
grant execute on function public.analizar_predio_completo(text, text) to anon, authenticated;

-- 4. Recarga la API
notify pgrst, 'reload schema';

-- 5. Verificación: debe devolver "acceso_directo_anon = false" en todas
--    las tablas y "anon_ejecuta = true" en las 4 funciones.
select 'TABLA' as tipo,
       c.relname::text as objeto,
       has_table_privilege('anon', c.oid, 'select') as acceso_directo_anon,
       null::boolean as anon_ejecuta
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p')
union all
select 'FUNCION', p.proname::text, null, has_function_privilege('anon', p.oid, 'execute')
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('list_tables', 'get_geojson', 'buscar_predios_pro', 'analizar_predio_completo')
order by 1 desc, 2;
