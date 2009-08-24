--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET client_encoding = 'SQL_ASCII';
SET standard_conforming_strings = off;
SET check_function_bodies = false;
SET client_min_messages = warning;
SET escape_string_warning = off;


CREATE LANGUAGE plpgsql;

--
-- Name: cornea; Type: SCHEMA; Schema: -; Owner: cornea
--

CREATE SCHEMA cornea;


ALTER SCHEMA cornea OWNER TO cornea;

SET search_path = cornea, pg_catalog;

--
-- Name: get_asset_location(integer, bigint, integer); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE FUNCTION get_asset_location(in_serviceid integer, in_assetid bigint, in_repid integer) RETURNS integer[]
    LANGUAGE sql STABLE
    AS $$
  	select storage_location from asset where service_id=$1 and asset_id=$2 and representation_id=$3;
$$;


ALTER FUNCTION cornea.get_asset_location(in_serviceid integer, in_assetid bigint, in_repid integer) OWNER TO cornea;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: representation; Type: TABLE; Schema: cornea; Owner: cornea; Tablespace: 
--

CREATE TABLE representation (
    representation_id smallint NOT NULL,
    service_id smallint NOT NULL,
    representation_name text NOT NULL,
    distance integer NOT NULL,
    representation_count integer NOT NULL,
    by_product_of integer NOT NULL,
    transform_class text NOT NULL
);


ALTER TABLE cornea.representation OWNER TO cornea;

--
-- Name: get_representation(integer, integer); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE FUNCTION get_representation(in_service_id integer, in_repid integer) RETURNS SETOF representation
    LANGUAGE sql STABLE
    AS $$
  	select * from representations where service_id = $1 and repid = $2;
$$;


ALTER FUNCTION cornea.get_representation(in_service_id integer, in_repid integer) OWNER TO cornea;

--
-- Name: get_representation_dependents(integer, integer); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE FUNCTION get_representation_dependents(in_service_id integer, in_repid integer) RETURNS SETOF representation
    LANGUAGE sql STABLE
    AS $$
	select * from representations where service_id = $1 and byproduct_of = $2;
$$;


ALTER FUNCTION cornea.get_representation_dependents(in_service_id integer, in_repid integer) OWNER TO cornea;

--
-- Name: storage_node; Type: TABLE; Schema: cornea; Owner: cornea; Tablespace: 
--

CREATE TABLE storage_node (
    storage_node_id smallint NOT NULL,
    state text NOT NULL,
    total_storage bigint NOT NULL,
    used_storage bigint NOT NULL,
    fqdn text NOT NULL,
    location text NOT NULL,
    modified_at timestamp with time zone DEFAULT now(),
    CONSTRAINT check_storage_state CHECK ((state = ANY (ARRAY['open'::text, 'closed'::text, 'offline'::text, 'decommissioned'::text])))
);


ALTER TABLE cornea.storage_node OWNER TO cornea;

--
-- Name: get_storage_nodes_by_state(text); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE OR REPLACE FUNCTION get_storage_nodes_by_state(in_state text) RETURNS SETOF storage_node
    LANGUAGE sql STABLE
    AS $$
  	select * from storage_node where state=$1 or $1 is null;
$$;


ALTER FUNCTION cornea.get_storage_nodes_by_state(in_state text) OWNER TO cornea;

--
-- Name: make_asset(integer, bigint, integer, integer[]); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE FUNCTION make_asset(in_service_id integer, in_asset_id bigint, in_repid integer, in_storage_location integer[]) RETURNS void
    LANGUAGE sql
    AS $$
  insert into asset(service_id,asset_id,representation_id,storage_location) 
      values ( in_service_id, in_asset_id , in_repid ,in_storage_location);
$$;


ALTER FUNCTION cornea.make_asset(in_service_id integer, in_asset_id bigint, in_repid integer, in_storage_location integer[]) OWNER TO cornea;

--
-- Name: make_storage_node(text, bigint, bigint, text, text); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE FUNCTION set_storage_node(in_state text, in_total_storage bigint, in_used_storage bigint, in_location text, in_fqdn text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
	v_storage_node_id storage_node%storage_node_id;
BEGIN
    SELECT storage_node_id FROM storage_node WHERE fqdn=$5 INTO v_storage_node_id;
    IF NOT FOUND THEN
       insert into storage_node (state, total_storage , used_storage ,fqdn, location) values 
                                        ($1, $2, $3, $5, $4);   
    ELSE
       update storage_node set state=$1, total_storage=$2, used_storage=$3,
                                       modified_at = current_timestamp,
                                       location= ( CASE WHEN $4 IS NULL THEN location ELSE $4 END)
       where storage_node_id = v_storage_node_id;
    END IF;
END
$$;


ALTER FUNCTION cornea.set_storage_node(in_state text, in_total_storage bigint, in_used_storage bigint, in_location text, in_fqdn text) OWNER TO cornea;

--
-- Name: asset; Type: TABLE; Schema: cornea; Owner: cornea; Tablespace: 
--

CREATE TABLE asset (
    asset_id bigint NOT NULL,
    service_id smallint NOT NULL,
    representation_id smallint NOT NULL,
    storage_location smallint[]
);


ALTER TABLE cornea.asset OWNER TO cornea;

--
-- Name: asset_asset_id_seq; Type: SEQUENCE; Schema: cornea; Owner: cornea
--

CREATE SEQUENCE asset_asset_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MAXVALUE
    NO MINVALUE
    CACHE 1;


ALTER TABLE cornea.asset_asset_id_seq OWNER TO cornea;

--
-- Name: asset_asset_id_seq; Type: SEQUENCE OWNED BY; Schema: cornea; Owner: cornea
--

ALTER SEQUENCE asset_asset_id_seq OWNED BY asset.asset_id;


--
-- Name: storage_node_storage_node_id_seq; Type: SEQUENCE; Schema: cornea; Owner: cornea
--

CREATE SEQUENCE storage_node_storage_node_id_seq
    START WITH 1
    INCREMENT BY 1
    MAXVALUE 32767
    NO MINVALUE
    CACHE 1;


ALTER TABLE cornea.storage_node_storage_node_id_seq OWNER TO cornea;

--
-- Name: storage_node_storage_node_id_seq; Type: SEQUENCE OWNED BY; Schema: cornea; Owner: cornea
--

ALTER SEQUENCE storage_node_storage_node_id_seq OWNED BY storage_node.storage_node_id;


--
-- Name: asset_id; Type: DEFAULT; Schema: cornea; Owner: cornea
--

ALTER TABLE asset ALTER COLUMN asset_id SET DEFAULT nextval('asset_asset_id_seq'::regclass);


--
-- Name: storage_node_id; Type: DEFAULT; Schema: cornea; Owner: cornea
--

ALTER TABLE storage_node ALTER COLUMN storage_node_id SET DEFAULT nextval('storage_node_storage_node_id_seq'::regclass);


--
-- Name: asset_pkey; Type: CONSTRAINT; Schema: cornea; Owner: cornea; Tablespace: 
--

ALTER TABLE ONLY asset
    ADD CONSTRAINT asset_pkey PRIMARY KEY (service_id, asset_id, representation_id);


--
-- Name: representation_pkey; Type: CONSTRAINT; Schema: cornea; Owner: cornea; Tablespace: 
--

ALTER TABLE ONLY representation
    ADD CONSTRAINT representation_pkey PRIMARY KEY (representation_id, service_id);


--
-- Name: storage_node_fqdn_uidx; Type: CONSTRAINT; Schema: cornea; Owner: cornea; Tablespace: 
--

ALTER TABLE ONLY storage_node
    ADD CONSTRAINT storage_node_fqdn_uidx UNIQUE (fqdn);


--
-- Name: storage_node_pkey; Type: CONSTRAINT; Schema: cornea; Owner: cornea; Tablespace: 
--

ALTER TABLE ONLY storage_node
    ADD CONSTRAINT storage_node_pkey PRIMARY KEY (storage_node_id);


--
-- PostgreSQL database dump complete
--

