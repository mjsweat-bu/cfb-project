-- =====================================================
-- Shared helper functions used by the core and mart scripts.
-- Run first. Safe to re-run.
-- =====================================================
CREATE SCHEMA IF NOT EXISTS core;

-- Safe casters: return NULL instead of erroring on junk like '--' or ''
CREATE OR REPLACE FUNCTION core.to_int(t text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN btrim(t) ~ '^-?\d+$' THEN btrim(t)::integer END
$$;

-- decimal strings (stats like SACKS, TFL, YPC)
CREATE OR REPLACE FUNCTION core.to_num(t text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN btrim(t) ~ '^-?\d+(\.\d+)?$' THEN btrim(t)::numeric END
$$;

-- 'MM:SS' clock strings (e.g. possession time '31:22') to seconds
CREATE OR REPLACE FUNCTION core.to_seconds(t text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN btrim(t) ~ '^\d+:\d{2}$'
            THEN split_part(btrim(t), ':', 1)::int * 60 + split_part(btrim(t), ':', 2)::int
        WHEN btrim(t) ~ '^\d+(\.\d+)?$'
            THEN round(btrim(t)::numeric)::int
    END
$$;
