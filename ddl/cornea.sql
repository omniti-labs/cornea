--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = off;
SET check_function_bodies = false;
SET client_min_messages = warning;
SET escape_string_warning = off;

--
-- Name: cornea; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA cornea;


ALTER SCHEMA cornea OWNER TO postgres;

--
-- Name: plpgsql; Type: PROCEDURAL LANGUAGE; Schema: -; Owner: postgres
--

CREATE PROCEDURAL LANGUAGE plpgsql;


ALTER PROCEDURAL LANGUAGE plpgsql OWNER TO postgres;

SET search_path = cornea, pg_catalog;

--
-- Name: findasset(integer, bigint, integer); Type: FUNCTION; Schema: cornea; Owner: postgres
--

CREATE FUNCTION findasset(in_serviceid integer, in_assetid bigint, in_repid integer) RETURNS integer[]
    LANGUAGE plpgsql
    AS $$
declare
v_out int[];
begin
  select storagelocation into v_out from cornea.assetlocations
    where serviceid=in_serviceid and assetid=in_assetid and repid=in_repid;
   return v_out;
end
$$;


ALTER FUNCTION cornea.findasset(in_serviceid integer, in_assetid bigint, in_repid integer) OWNER TO postgres;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: storagenodes; Type: TABLE; Schema: cornea; Owner: postgres; Tablespace: 
--

CREATE TABLE storagenodes (
    storagenodeid smallint NOT NULL,
    state text NOT NULL,
    total_storage bigint not null,
    used_storage bigint not null,
    fqdn text not null,
    location text not null,
    lastupdatetime timestamp with time zone DEFAULT now(),
    CONSTRAINT check_storagestate CHECK ((state = ANY (ARRAY['open'::text, 'closed'::text, 'offline'::text, 'decommissioned'::text])))
);


ALTER TABLE cornea.storagenodes OWNER TO postgres;

--
-- Name: getcorneanodes(text); Type: FUNCTION; Schema: cornea; Owner: postgres
--

CREATE FUNCTION getcorneanodes(in_state text) RETURNS SETOF storagenodes
    LANGUAGE plpgsql
    AS $$
declare
v_rec cornea.storagenodes%rowtype;
begin
  for v_rec in select * from cornea.storagenodes
    where state=in_state or in_state is null
loop
   return next v_rec;
 end loop;
end
$$;


ALTER FUNCTION cornea.getcorneanodes(in_state text) OWNER TO postgres;

--
-- Name: representations; Type: TABLE; Schema: cornea; Owner: postgres; Tablespace: 
--

CREATE TABLE representations (
    repid smallint,
    serviceid smallint,
    repname text,
    distance integer,
    repcount integer,
    byproductof integer,
    transformclass text
);


ALTER TABLE cornea.representations OWNER TO postgres;

--
-- Name: getrepinfo(integer, integer); Type: FUNCTION; Schema: cornea; Owner: postgres
--

CREATE FUNCTION getrepinfo(in_serviceid integer, in_repid integer) RETURNS SETOF representations
    LANGUAGE plpgsql
    AS $$
declare
v_rec cornea.representations%rowtype;
begin
  for v_rec in select * from cornea.representations
    where serviceid= in_serviceid  and repid= in_repid
loop
   return next v_rec;
 end loop;
end
$$;


ALTER FUNCTION cornea.getrepinfo(in_serviceid integer, in_repid integer) OWNER TO postgres;

--
-- Name: getrepinfodependents(integer, integer); Type: FUNCTION; Schema: cornea; Owner: postgres
--

CREATE FUNCTION getrepinfodependents(in_serviceid integer, in_repid integer) RETURNS SETOF representations
    LANGUAGE plpgsql
    AS $$
declare
v_rec cornea.representations%rowtype;
begin
  for v_rec in select * from cornea.representations
    where serviceid =in_serviceid and byproductof = in_repid
loop
   return next v_rec;
 end loop;
end
$$;


ALTER FUNCTION cornea.getrepinfodependents(in_serviceid integer, in_repid integer) OWNER TO postgres;

--
-- Name: storeasset(integer, bigint, integer, integer[]); Type: FUNCTION; Schema: cornea; Owner: postgres
--

CREATE FUNCTION storeasset(in_serviceid integer, in_assetid bigint, in_repid integer, in_storagelocation integer[]) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  insert into cornea. assetlocations(serviceid,assetid,repid,storagelocation) 
                    values ( in_serviceid, in_assetid , in_repid ,in_storagelocation);
end
$$;


ALTER FUNCTION cornea.storeasset(in_serviceid integer, in_assetid bigint, in_repid integer, in_storagelocation integer[]) OWNER TO postgres;

--
-- Name: storecorneanode(text, bigint, bigint, text, text); Type: FUNCTION; Schema: cornea; Owner: postgres
--

CREATE FUNCTION storecorneanode(in_state text, in_total_storage bigint, in_used_storage bigint, in_location text, in_fqdn text) RETURNS void
    LANGUAGE plpgsql
    AS $$
declare
v_storagenodeid int;
begin
SELECT storagenodeid FROM cornea.storagenodes  WHERE fqdn=in_fqdn
          INTO v_storagenodeid;
 IF NOT FOUND THEN
           insert into  cornea.storagenodes (storagenodeid, state, total_storage , used_storage ,fqdn, location) values 
                                        (nextval('seq_storagenodeid'), in_state, in_total_storage, in_used_storage, in_fqdn, in_location);   
    ELSE
       update  cornea.storagenodes set state=in_state, total_storage=in_total_storage, used_storage=in_used_storage,
                                       lastupdatetime = current_timestamp,
                                       location= ( CASE WHEN in_location IS NULL THEN location ELSE in_location END)
       where storagenodeid = v_storagenodeid;
 END IF;
end
$$;


ALTER FUNCTION cornea.storecorneanode(in_state text, in_total_storage bigint, in_used_storage bigint, in_fqdn text, in_location text) OWNER TO postgres;

--
-- Name: assetlocations; Type: TABLE; Schema: cornea; Owner: postgres; Tablespace: 
--

CREATE TABLE assetlocations (
    assetid bigint NOT NULL,
    serviceid smallint NOT NULL,
    repid smallint NOT NULL,
    storagelocation smallint[]
);


ALTER TABLE cornea.assetlocations OWNER TO postgres;

--
-- Name: seq_assetid; Type: SEQUENCE; Schema: cornea; Owner: postgres
--

CREATE SEQUENCE seq_assetid
    START WITH 1
    INCREMENT BY 1
    NO MAXVALUE
    NO MINVALUE
    CACHE 1;


ALTER TABLE cornea.seq_assetid OWNER TO postgres;

--
-- Name: seq_assetid; Type: SEQUENCE SET; Schema: cornea; Owner: postgres
--

SELECT pg_catalog.setval('seq_assetid', 1, false);


--
-- Name: seq_storagenodeid; Type: SEQUENCE; Schema: cornea; Owner: postgres
--

CREATE SEQUENCE seq_storagenodeid
    START WITH 1
    INCREMENT BY 1
    NO MAXVALUE
    NO MINVALUE
    CACHE 1;


ALTER TABLE cornea.seq_storagenodeid OWNER TO postgres;

--
-- Name: seq_storagenodeid; Type: SEQUENCE SET; Schema: cornea; Owner: postgres
--

SELECT pg_catalog.setval('seq_storagenodeid', 1, false);


--
-- Data for Name: assetlocations; Type: TABLE DATA; Schema: cornea; Owner: postgres
--

COPY assetlocations (assetid, serviceid, repid, storagelocation) FROM stdin;
\.


--
-- Data for Name: representations; Type: TABLE DATA; Schema: cornea; Owner: postgres
--

COPY representations (repid, serviceid, repname, distance, repcount, byproductof, transformclass) FROM stdin;
\.


--
-- Data for Name: storagenodes; Type: TABLE DATA; Schema: cornea; Owner: postgres
--

COPY storagenodes (storagenodeid, state, total_storage, used_storage, fqdn, location, lastupdatetime) FROM stdin;
\.


--
-- Name: pk_tuples; Type: CONSTRAINT; Schema: cornea; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY assetlocations
    ADD CONSTRAINT pk_tuples PRIMARY KEY (serviceid, assetid, repid);


--
-- Name: representations_repid_key; Type: CONSTRAINT; Schema: cornea; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY representations
    ADD CONSTRAINT representations_repid_key UNIQUE (repid, serviceid);


--
-- Name: storagenodes_name_key; Type: CONSTRAINT; Schema: cornea; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY storagenodes
    ADD CONSTRAINT storagenodes_name_key UNIQUE (fqdn);


--
-- Name: storagenodes_pkey; Type: CONSTRAINT; Schema: cornea; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY storagenodes
    ADD CONSTRAINT storagenodes_pkey PRIMARY KEY (storagenodeid);


--
-- Name: public; Type: ACL; Schema: -; Owner: postgres
--

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM postgres;
GRANT ALL ON SCHEMA public TO postgres;
GRANT ALL ON SCHEMA public TO PUBLIC;


--
-- PostgreSQL database dump complete
--

