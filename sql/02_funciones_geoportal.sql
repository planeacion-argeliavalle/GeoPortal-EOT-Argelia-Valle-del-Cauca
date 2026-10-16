-- =====================================================================
-- GEOPORTAL EOT ARGELIA (VALLE) - SCRIPT 02: FUNCIONES DEL BACKEND
-- ---------------------------------------------------------------------
-- Reemplaza las 4 funciones RPC que consume el geoportal por versiones
-- robustas, con detección automática de columnas y reproyección.
--
-- ANTES DE EJECUTAR:
--   1. Ejecute 01_diagnostico.sql y exporte el resultado (respaldo).
--   2. Si la capa de catastro NO se llama catarg_va2025wgs84, cambie el
--      valor en la función _geoportal_tabla_catastro() (abajo).
--
-- Ejecutar completo en Supabase > SQL Editor > Run. Es idempotente:
-- puede ejecutarse varias veces sin efectos adicionales.
--
-- Funciones públicas (las llama la página con la llave anon):
--   list_tables()                                   -> capas disponibles
--   get_geojson(table_name)                         -> capa en GeoJSON
--   buscar_predios_pro(criterio)                    -> búsqueda catastral
--   analizar_predio_completo(tabla_predio, npn_buscado) -> cruces con zonas
--
-- PROTECCIÓN DE DATOS (Ley 1581 de 2012): las propiedades cuyo nombre
-- sugiere datos personales (propietario, cédula, documento, NIT,
-- teléfono, correo) se eliminan de toda respuesta pública y no son
-- buscables. Ajuste _geoportal_props() si necesita excluir otras.
-- =====================================================================

create extension if not exists postgis;

-- ---------------------------------------------------------------------
-- 0. Retiro de versiones anteriores (todas las sobrecargas)
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as firma
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('list_tables', 'get_geojson', 'buscar_predios_pro', 'analizar_predio_completo',
                        '_geoportal_capas', '_geoportal_campo', '_geoportal_props',
                        '_geoportal_geom_col', '_geoportal_tabla_catastro')
  loop
    execute format('drop function %s cascade', f.firma);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 1. Configuración: nombre de la capa de catastro
-- ---------------------------------------------------------------------
create function public._geoportal_tabla_catastro()
returns text language sql immutable
as $$ select 'catarg_va2025wgs84'::text $$;

-- ---------------------------------------------------------------------
-- 2. Inventario de capas espaciales del esquema public
--    (lee el catálogo de PostgreSQL; no depende de geometry_columns)
-- ---------------------------------------------------------------------
create function public._geoportal_capas()
returns table(tabla text, geom_col text, tipo text)
language sql stable
set search_path = public, extensions, pg_catalog
as $$
  select distinct on (c.relname)
         c.relname::text,
         a.attname::text,
         coalesce(postgis_typmod_type(a.atttypmod), 'Geometry')::text
  from pg_attribute a
  join pg_class c on c.oid = a.attrelid
  join pg_namespace n on n.oid = c.relnamespace
  join pg_type t on t.oid = a.atttypid
  where n.nspname = 'public'
    and t.typname = 'geometry'
    and c.relkind in ('r', 'v', 'm', 'p')
    and a.attnum > 0 and not a.attisdropped
    and c.relname not like '\_%'
  order by c.relname, a.attnum;
$$;

create function public._geoportal_geom_col(p_tabla text)
returns text language sql stable
set search_path = public, extensions, pg_catalog
as $$ select geom_col from public._geoportal_capas() where tabla = p_tabla limit 1 $$;

-- ---------------------------------------------------------------------
-- 3. Propiedades públicas: excluye campos con datos personales
-- ---------------------------------------------------------------------
create function public._geoportal_props(p jsonb)
returns jsonb language sql immutable
as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
  from jsonb_each(p)
  where key !~* '(propiet|c[eé]dula|documento|identificaci|^nit|_nit|nit_|tel[eé]fono|celular|correo|e?mail|nombre_?prop|titular)';
$$;

-- ---------------------------------------------------------------------
-- 4. Valor del primer campo existente de una lista de candidatos
--    (insensible a mayúsculas: NPN, npn, Npn...)
-- ---------------------------------------------------------------------
create function public._geoportal_campo(p jsonb, candidatos text[])
returns text language sql immutable
as $$
  select e.value #>> '{}'
  from unnest(candidatos) with ordinality as c(nombre, orden)
  join jsonb_each(p) e on lower(e.key) = lower(c.nombre)
  where nullif(trim(e.value #>> '{}'), '') is not null
  order by c.orden
  limit 1;
$$;

-- ---------------------------------------------------------------------
-- 5. list_tables(): capas disponibles para el visor
-- ---------------------------------------------------------------------
create function public.list_tables()
returns table(tabla text, tipo text)
language sql stable security definer
set search_path = public, extensions, pg_catalog
as $$
  select tabla, tipo from public._geoportal_capas() order by tabla;
$$;

-- ---------------------------------------------------------------------
-- 6. get_geojson(table_name): capa completa como FeatureCollection
--    EPSG:4326, 6 decimales (~10 cm), propiedades depuradas.
-- ---------------------------------------------------------------------
create function public.get_geojson(table_name text)
returns json
language plpgsql stable security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  g text := public._geoportal_geom_col(table_name);
  resultado json;
begin
  if g is null then
    raise exception 'La capa "%" no existe o no tiene geometría', table_name using errcode = '42P01';
  end if;

  execute format($f$
    select json_build_object(
             'type', 'FeatureCollection',
             'name', %3$L,
             'features', coalesce(json_agg(q.feat), '[]'::json))
    from (
      select json_build_object(
               'type', 'Feature',
               'geometry', ST_AsGeoJSON(
                   case when ST_SRID(t.%1$I) in (0, 4326) then ST_SetSRID(t.%1$I, 4326)
                        else ST_Transform(t.%1$I, 4326) end, 6)::json,
               'properties', public._geoportal_props(to_jsonb(t) - %2$L)
             ) as feat
      from public.%3$I t
      where t.%1$I is not null and not ST_IsEmpty(t.%1$I)
    ) q
  $f$, g, g, table_name) into resultado;

  return resultado;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. buscar_predios_pro(criterio): búsqueda por NPN, nombre o dirección
--    Mínimo 3 caracteres, máximo 25 resultados. El NPN también se
--    compara sin espacios ni guiones.
-- ---------------------------------------------------------------------
create function public.buscar_predios_pro(criterio text)
returns table(id_predio text, npn text, direccion text, origen text, geojson json)
language plpgsql stable security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  tabla text := public._geoportal_tabla_catastro();
  g text := public._geoportal_geom_col(public._geoportal_tabla_catastro());
  q text := trim(coalesce(criterio, ''));
  q_digitos text := regexp_replace(coalesce(criterio, ''), '\D', '', 'g');
  q_like text;
begin
  if g is null then
    raise exception 'La capa de catastro "%" no existe', tabla using errcode = '42P01';
  end if;
  if length(q) < 3 then
    return;
  end if;

  -- Escapa comodines de LIKE escritos por el usuario
  q_like := '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%';

  return query execute format($f$
    with base as (
      select public._geoportal_props(to_jsonb(t) - %2$L) as p,
             case when ST_SRID(t.%1$I) in (0, 4326) then ST_SetSRID(t.%1$I, 4326)
                  else ST_Transform(t.%1$I, 4326) end as geom
      from public.%3$I t
      where t.%1$I is not null
    )
    select
      coalesce(public._geoportal_campo(b.p, $1), 's/i'),
      coalesce(public._geoportal_campo(b.p, $2), 'Sin NPN'),
      coalesce(public._geoportal_campo(b.p, $3), 'Sin nombre / dirección'),
      'Catastro'::text,
      json_build_object(
        'type', 'FeatureCollection',
        'features', json_build_array(json_build_object(
          'type', 'Feature',
          'geometry', ST_AsGeoJSON(b.geom, 6)::json,
          'properties', b.p)))
    from base b
    where exists (
      select 1 from jsonb_each_text(b.p) e
      where e.value ilike $4
         or (length($5) >= 5 and regexp_replace(e.value, '\D', '', 'g') like '%%' || $5 || '%%')
    )
    limit 25
  $f$, g, g, tabla)
  using
    array['gid', 'id', 'objectid', 'fid', 'ogc_fid', 'id_predio'],
    array['npn', 'numero_predial', 'codigo_predial', 'cod_predial', 'numero_pre', 'codigo_pre',
          'cod_catast', 'codigo_catastral', 'codigo', 'predial'],
    array['direccion', 'dir_predio', 'nombre_predio', 'nom_predio', 'nombre', 'predio', 'vereda'],
    q_like,
    q_digitos;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. analizar_predio_completo(tabla_predio, npn_buscado)
--    Área (m², geodésica sobre el elipsoide WGS84) y porcentaje del
--    predio que se cruza con cada capa poligonal. Las capas lineales o
--    puntuales y los cruces < 1 m² se omiten. Una capa con error no
--    detiene el análisis de las demás.
-- ---------------------------------------------------------------------
create function public.analizar_predio_completo(tabla_predio text, npn_buscado text)
returns table(capa_zona text, area_cruce_m2 double precision, porcentaje double precision)
language plpgsql stable security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  g text := public._geoportal_geom_col(tabla_predio);
  geom_predio geometry;
  area_predio double precision;
  area_cruce double precision;
  capa record;
begin
  if g is null then
    raise exception 'La capa "%" no existe o no tiene geometría', tabla_predio using errcode = '42P01';
  end if;
  if nullif(trim(coalesce(npn_buscado, '')), '') is null then
    return;
  end if;

  execute format($f$
    select ST_Union(ST_CollectionExtract(ST_MakeValid(
             case when ST_SRID(t.%1$I) in (0, 4326) then ST_SetSRID(t.%1$I, 4326)
                  else ST_Transform(t.%1$I, 4326) end), 3))
    from public.%2$I t
    where public._geoportal_campo(to_jsonb(t) - %3$L, $1) = $3
       or public._geoportal_campo(to_jsonb(t) - %3$L, $2) = $3
  $f$, g, tabla_predio, g)
  into geom_predio
  using
    array['npn', 'numero_predial', 'codigo_predial', 'cod_predial', 'numero_pre', 'codigo_pre',
          'cod_catast', 'codigo_catastral', 'codigo', 'predial'],
    array['gid', 'id', 'objectid', 'fid', 'ogc_fid', 'id_predio'],
    trim(npn_buscado);

  if geom_predio is null or ST_IsEmpty(geom_predio) then
    return;
  end if;

  area_predio := ST_Area(geom_predio::geography);
  if area_predio is null or area_predio <= 0 then
    return;
  end if;

  for capa in
    select c.tabla, c.geom_col from public._geoportal_capas() c
    where c.tabla <> tabla_predio
      and (c.tipo ilike '%polygon%' or c.tipo ilike 'geometry%')
    order by c.tabla
  loop
    begin
      execute format($f$
        select ST_Area(ST_CollectionExtract(ST_Intersection(ST_Union(z.gz), $1), 3)::geography)
        from (
          select ST_CollectionExtract(ST_MakeValid(
                   case when ST_SRID(t.%1$I) in (0, 4326) then ST_SetSRID(t.%1$I, 4326)
                        else ST_Transform(t.%1$I, 4326) end), 3) as gz
          from public.%2$I t
          where t.%1$I is not null
        ) z
        where ST_Intersects(z.gz, $1)
      $f$, capa.geom_col, capa.tabla)
      into area_cruce
      using geom_predio;
    exception when others then
      raise notice 'Capa % omitida en el análisis: %', capa.tabla, sqlerrm;
      area_cruce := null;
    end;

    if area_cruce is not null and area_cruce >= 1 then
      capa_zona := capa.tabla;
      area_cruce_m2 := round(area_cruce::numeric, 2)::double precision;
      porcentaje := round(least(100, area_cruce / area_predio * 100)::numeric, 2)::double precision;
      return next;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Permisos: solo las 4 funciones públicas quedan expuestas en la API
-- ---------------------------------------------------------------------
revoke all on function public._geoportal_tabla_catastro() from public;
revoke all on function public._geoportal_capas() from public;
revoke all on function public._geoportal_geom_col(text) from public;
revoke all on function public._geoportal_props(jsonb) from public;
revoke all on function public._geoportal_campo(jsonb, text[]) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public._geoportal_tabla_catastro() from anon, authenticated';
    execute 'revoke all on function public._geoportal_capas() from anon, authenticated';
    execute 'revoke all on function public._geoportal_geom_col(text) from anon, authenticated';
    execute 'revoke all on function public._geoportal_props(jsonb) from anon, authenticated';
    execute 'revoke all on function public._geoportal_campo(jsonb, text[]) from anon, authenticated';

    execute 'grant execute on function public.list_tables() to anon, authenticated';
    execute 'grant execute on function public.get_geojson(text) to anon, authenticated';
    execute 'grant execute on function public.buscar_predios_pro(text) to anon, authenticated';
    execute 'grant execute on function public.analizar_predio_completo(text, text) to anon, authenticated';

    -- Supabase limita a 3 s las consultas del rol anon; la capa de
    -- catastro completa y el análisis de cruces pueden tardar más.
    execute 'alter role anon set statement_timeout = ''30s''';
    execute 'alter role authenticated set statement_timeout = ''30s''';
  end if;
end $$;

-- Recarga el caché de esquema y configuración de la API (PostgREST)
notify pgrst, 'reload schema';
notify pgrst, 'reload config';
