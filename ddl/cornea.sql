--
-- *NOTE* This is not a PostgreSQL database dump. 
-- If you want to update the schema, you should edit this file manually
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


CREATE TYPE storagestate AS ENUM('open','closed','offline','decommissioned');


--
-- Name: get_asset_location(integer, bigint, integer); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE OR REPLACE FUNCTION get_asset_location(in_service_id integer, in_asset_id bigint, in_representation_id integer) 
RETURNS SETOF storage_node_info 
LANGUAGE sql STABLE
AS $$
	SELECT storage_node_info.* FROM storage_node_info JOIN asset ON (storage_node_id =ANY(storage_location)) 
		WHERE service_id=$1 and asset_id=$2 and representation_id=$3;
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
    replication_count integer NOT NULL,
    byproduct_of smallint,
    parallel_transform boolean NOT NULL,
    transform_class text NOT NULL
);


ALTER TABLE cornea.representation OWNER TO cornea;

--
-- Name: make_representation(smallint, smallint, text, integer, integer, smallint, text); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE OR REPLACE FUNCTION make_representation(in_service_id smallint, in_repid smallint, in_name text, in_distance integer, in_count integer, in_parent smallint, in_parallel boolean, in_transform text) RETURNS VOID
    LANGUAGE plpgsql
    AS $$
DECLARE
	v_rep representation%rowtype;
BEGIN
	SELECT * FROM representation WHERE service_id = $1 and representation_id = $2 INTO v_rep;
	IF NOT FOUND THEN
		INSERT INTO representation (representation_id, service_id, representation_name, distance, replication_count, byproduct_of, parallel_transform, transform_class)
		VALUES($2, $1, $3, $4, $5, $6, $7, $8);
	ELSE
		UPDATE representation SET
		representation_name = $3, distance = $4, replication_count = $5, byproduct_of = $6, parallel_transform = $7, transform_class = $8 WHERE representation_id = $2 and service_id = $1;
	END IF;
END
$$;


ALTER FUNCTION cornea.make_representation(in_service_id smallint, in_repid smallint, in_name text, in_distance integer, in_count integer, in_parent smallint, in_parallel boolean, in_transform text) OWNER TO cornea;

--
-- Name: get_representation(smallint, smallint); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE OR REPLACE FUNCTION get_representation(in_service_id smallint, in_repid smallint) RETURNS SETOF representation
    LANGUAGE sql STABLE
    AS $$
  	select * from representation where service_id = $1 and representation_id = $2;
$$;


ALTER FUNCTION cornea.get_representation(in_service_id smallint, in_repid smallint) OWNER TO cornea;

--
-- Name: get_representation_dependents(smallint, smallint); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE OR REPLACE FUNCTION get_representation_dependents(in_service_id smallint, in_repid smallint) RETURNS SETOF representation
    LANGUAGE sql STABLE
    AS $$
	select * from representation where service_id = $1 and byproduct_of = $2;
$$;


ALTER FUNCTION cornea.get_representation_dependents(in_service_id smallint, in_repid smallint) OWNER TO cornea;

--
-- Name: storage_node; Type: TABLE; Schema: cornea; Owner: cornea; Tablespace: 
--

CREATE TABLE storage_node (
    storage_node_id smallint NOT NULL,
    state storagestate NOT NULL,
    total_storage bigint NOT NULL,
    used_storage bigint NOT NULL,
    ip text NOT NULL, 
    fqdn text NOT NULL,
    location text NOT NULL,
    modified_at timestamp with time zone DEFAULT now()
);


ALTER TABLE cornea.storage_node OWNER TO cornea;

CREATE OR REPLACE VIEW storage_node_info AS SELECT storage_node_id, state as raw_state, case when state = 'open' and modified_at < current_timestamp - '60 seconds'::interval then 'truant' else state end as state, total_storage, used_storage, ip, fqdn, location, modified_at, (extract(epoch from current_timestamp) - extract(epoch from modified_at))::bigint as age from storage_node; 
--
-- Name: get_storage_nodes_by_state(text); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE OR REPLACE FUNCTION get_storage_nodes(in_state storagestate[]) RETURNS SETOF storage_node_info
    LANGUAGE sql STABLE
    AS $$
  	select * from storage_node_info where state=any($1) or $1 is null;
$$;

ALTER FUNCTION cornea.get_storage_nodes_by_state(in_state text) OWNER TO cornea;

--
-- Name: make_asset(integer, bigint, integer, integer[]); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE OR REPLACE FUNCTION make_asset(in_service_id integer, in_asset_id bigint, in_repid integer, in_storage_location smallint[]) RETURNS void
    LANGUAGE sql
    AS $$
	-- remove any existing copies, ensures that this node becomes "owner" of the asset 
	delete from asset where service_id = $1 and asset_id = $2 and representation_id = $3;
  	insert into asset(service_id,asset_id,representation_id,storage_location) values ($1, $2, $3, $4);
$$;


ALTER FUNCTION cornea.make_asset(in_service_id integer, in_asset_id bigint, in_repid integer, in_storage_location integer[]) OWNER TO cornea;

--
-- Name: make_storage_node(text, bigint, bigint, text, text); Type: FUNCTION; Schema: cornea; Owner: cornea
--

CREATE OR REPLACE FUNCTION set_storage_node(in_state storagestate, in_total_storage bigint, in_used_storage bigint, in_location text, in_fqdn text, in_ip text, in_storage_node_id storage_node.storage_node_id%type) RETURNS storage_node.storage_node_id%type 
    LANGUAGE plpgsql
    AS $$
DECLARE
	v_storage_node_id storage_node.storage_node_id%type;
BEGIN
    SELECT storage_node_id FROM storage_node WHERE ip=$6 INTO v_storage_node_id;
    IF NOT FOUND THEN
       insert into storage_node (storage_node_id, state, total_storage, used_storage, fqdn, location, ip) 
		values (coalesce($7,(select coalesce(max(storage_node_id),0) +1 from storage_node)),$1, $2, $3, $5, $4, $6)
			returning storage_node_id INTO v_storage_node_id;   
	-- used the passed in node id if we have one, otherwise we'll generate one ourselves 
	-- we don't use a sequence here, because then we would have to synchronize sequences across all nodes
    ELSE
       update storage_node set state=$1, total_storage=$2, used_storage=$3, 
                                       modified_at = current_timestamp, 
                                       location= ( CASE WHEN $4 IS NULL THEN location ELSE $4 END),
                                       fqdn= ( CASE WHEN $5 IS NULL THEN fqdn ELSE $4 END)
       where storage_node_id = v_storage_node_id;
    END IF;

    RETURN v_storage_node_id; 

END
$$;


ALTER FUNCTION cornea.set_storage_node(in_state storagestate, in_total_storage bigint, in_used_storage bigint, in_location text, in_fqdn text) OWNER TO cornea;

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

CREATE OR REPLACE FUNCTION asset_prevent_inserts() RETURNS trigger AS $$BEGIN RAISE EXCEPTION 'Cornea Application Error: Insert into parent asset table not allowed'; END$$ LANGUAGE plpgsql; 

CREATE TRIGGER asset_prevent_inserts BEFORE insert ON asset FOR EACH ROW EXECUTE PROCEDURE asset_prevent_inserts();                                                                                                                           
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
-- Name: asset_id; Type: DEFAULT; Schema: cornea; Owner: cornea
--

ALTER TABLE asset ALTER COLUMN asset_id SET DEFAULT nextval('asset_asset_id_seq'::regclass);


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
    ADD CONSTRAINT storage_node_ip_uidx UNIQUE (ip);


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

