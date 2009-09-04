#include <alloca.h>
#include <httpd.h>
#include <ap_config.h>
#include <http_config.h>
#include <http_request.h>
#include <http_log.h>
#include <apr_hooks.h>
#include <apr_strings.h>
#include <apr_thread_mutex.h>
#include <apr_reslist.h>
#include <apr_md5.h>
#include <libpq-fe.h>
#include <libmemcached/memcached.h>

module cornea_router_module;

typedef struct {
  char *doskey;
  int n_dsn;
  char **dsn;
  apr_reslist_t **reslist;
  int min;
  int smax;
  int hmax;
  int ttl;
} cornea_router_config_t;

typedef struct {
  apr_int64_t total_storage;
  apr_int64_t used_storage;
  int age;
  unsigned short storage_node_id;
  char ip[16];
  char fqdn[256];
  char state[32];
  char raw_state[32];
  char location[64];
  char modified_at[40];
} cornea_store_t;

static cornea_store_t *cornea_stores[65536] = { NULL }; /* order 1 lookup */

/* memcached connection pooling and on-the-fly reconfiguration */
static apr_thread_mutex_t *memcached_mutex = NULL;
static apr_thread_mutex_t *memcached_pool_mutex = NULL;
static int memcached_config_generation = 0;
static int memcached_server_count = 0;
static char **memcached_server_list = NULL;

typedef struct memcached_pool_handle {
  memcached_st st;
  int generation;
  struct memcached_pool_handle *next;
} memcache_pool_handle_t;
memcache_pool_handle_t *memcache_pool = NULL;

static memcache_pool_handle_t *
fetch_memcached_handle() {
  int i;
  memcache_pool_handle_t *handle;
  apr_thread_mutex_lock(memcached_pool_mutex);
  handle = memcache_pool;
  if(memcache_pool) memcache_pool = memcache_pool->next;
  apr_thread_mutex_unlock(memcached_pool_mutex);
  if(handle && handle->generation == memcached_config_generation) return handle;
  if(handle) {
    memcached_quit(&handle->st);
    memcached_free(&handle->st);
    free(handle);
  }
  handle = calloc(1, sizeof(*handle));
  handle->generation = memcached_config_generation;
  if(memcached_create(&handle->st) == NULL) { free(handle); return NULL; }
  memcached_behavior_set(&handle->st, MEMCACHED_BEHAVIOR_DISTRIBUTION,
                         MEMCACHED_DISTRIBUTION_CONSISTENT);
  apr_thread_mutex_lock(memcached_mutex);
  for(i=0; i<memcached_server_count; i++)
    memcached_server_add(&handle->st, memcached_server_list[i], 11211);
  apr_thread_mutex_unlock(memcached_mutex);
  return handle;
}
static void
release_memcached_handle(memcache_pool_handle_t *handle) {
  apr_thread_mutex_lock(memcached_pool_mutex);
  handle->next = memcache_pool;
  memcache_pool = handle;
  apr_thread_mutex_unlock(memcached_pool_mutex);
}
static char *
fetch_storage_nodes_from_pg(server_rec *s, const char *asset_tag) {
  int   start, i;
  char *result = NULL;
  char *acopy;
  int   lengths[3] = { 0 };
  int   formats[3] = { 0 };
  char *params[3];
  cornea_router_config_t *s_cfg = ap_get_module_config(
    s->module_config, &cornea_router_module);
  start = rand();
  acopy = alloca(strlen(asset_tag)+1);
  if(!acopy) return NULL;
  memcpy(acopy, asset_tag, strlen(asset_tag)+1);

  ap_log_error(APLOG_MARK, APLOG_DEBUG, 0, s,
               "Cornea: going to postgres for %s", asset_tag);

  params[0] = acopy;
  params[1] = strchr(params[0], '-');
  if(!params[1]) return NULL;
  (*params[1]++) = '\0';
  params[2] = strchr(params[1], '-');
  if(!params[2]) return NULL;
  (*params[2]++) = '\0';
  for(i=0; i<3; i++) lengths[i] = strlen(params[i]);

  for(i=0; i<s_cfg->n_dsn && !result; i++) {
    void *vdbh;
    PGconn *dbh;
    apr_reslist_t *rl = s_cfg->reslist[(start+i) % s_cfg->n_dsn];
    if(apr_reslist_acquire(rl, &vdbh) == APR_SUCCESS) {
      PGresult *res;
      dbh = vdbh;
      res = PQexecParams(dbh, "select array_to_string(storage_location,',') from cornea.asset where service_id = $1 and asset_id = $2 and representation_id = $3",
                         3, NULL, (const char * const *)params,
                         lengths, formats, 0);
      if(PQresultStatus(res) == PGRES_TUPLES_OK &&
         PQntuples(res) > 0) {
        result = PQgetvalue(res, 0, 0);
        if(result) result = strdup(result);
      }
      else {
        ap_log_error(APLOG_MARK, APLOG_ERR, 0, NULL,
                     "Cornea: DB error: '%s'", PQresultErrorMessage(res));
      }
      PQclear(res);
      apr_reslist_release(rl, vdbh);
    }
  }
  return result;
}
static int
fetch_storage_nodes(server_rec *s, const char *asset_tag, unsigned short *ids, int max) {
  int count = 0;
  char *data;
  size_t len;
  uint32_t flags;
  memcached_return err;
  memcache_pool_handle_t *h;
  h = fetch_memcached_handle();
  if(!h) return 0;
  data = memcached_get(&h->st, asset_tag, strlen(asset_tag),
                       &len, &flags, &err);
  release_memcached_handle(h);
  ap_log_error(APLOG_MARK, APLOG_DEBUG, 0, s,
               "Cornea: memcached %s", data ? "hit" : "miss");
  if(!data) {
    char *errstr = memcached_strerror(&h->st, err);
    if(errstr) ap_log_error(APLOG_MARK, APLOG_WARNING, 0, s,
                            "Cornea: cache %s", errstr);
    data = fetch_storage_nodes_from_pg(s, asset_tag);
    if(data) {
      h = fetch_memcached_handle();
      if(!h) return 0;
      memcached_set(&h->st, asset_tag, strlen(asset_tag),
                    data, strlen(data), 0, 0);
      release_memcached_handle(h);
    }
  }
  if(data) {
    char *part, *brkt;
    for(part = strtok_r(data, ",", &brkt);
        part;
        part = strtok_r(NULL, ",", &brkt)) {
      ids[count++] = atoi(part);
      if(count > max) break;
    }
    free(data);
  }
  return count;
}
static int
is_list_the_same(int an, char **a, int bn, char **b) {
  int i;
  if(an != bn) return 0;
  for(i=0; i<an; i++) {
    if(strcmp(a[i], b[i])) return 0;
  }
  return 1;
}
static void
configure_memcached(int cnt, char **ips) {
  if(!is_list_the_same(cnt, ips,
                       memcached_server_count, memcached_server_list)) {
    int old_n;
    char **old;
    apr_thread_mutex_lock(memcached_mutex);
    old_n = memcached_server_count;
    old = memcached_server_list;
    memcached_server_count = cnt;
    memcached_server_list = ips;
    apr_thread_mutex_unlock(memcached_mutex);
    /* free the old list */
    while(old_n > 0)
      free(old[old_n-1]);
    free(old);
    memcached_config_generation++;
    ap_log_error(APLOG_MARK, APLOG_NOTICE, 0, NULL,
                 "Cornea: reconfiguring memcached across %d nodes",
                 memcached_server_count);
  }
}
static void *
make_cornea_router_server_config(apr_pool_t *p, server_rec *s) {
  cornea_router_config_t *newcfg;
  newcfg = (cornea_router_config_t *) apr_pcalloc(p, sizeof(*newcfg));
  newcfg->min = 0;
  newcfg->smax = 1;
  newcfg->hmax = 16;
  newcfg->ttl = 3;
  return (void *) newcfg;
}
static void *
merge_cornea_router_server_config(apr_pool_t *p, void *s1, void *s2) {
  cornea_router_config_t *newcfg;
  abort();
  newcfg = (cornea_router_config_t *) apr_pcalloc(p, sizeof(*newcfg));
  return newcfg;
}

static int
ensure_pg_connection(server_rec *s, PGconn **dbh, const char *dsn) {
  if(*dbh) {
    if(PQstatus(*dbh) == CONNECTION_OK) return 0;
    PQreset(*dbh);
    if(PQstatus(*dbh) == CONNECTION_OK) return 0;
    ap_log_error(APLOG_MARK, APLOG_ERR, 0, s,
                 "Cornea: DB connect error to %s: '%s'", dsn, PQerrorMessage(*dbh));
    return -1;
  }
  *dbh = PQconnectdb(dsn);
  if(!*dbh) return 0;
  if(PQstatus(*dbh) == CONNECTION_OK) return 0;
  ap_log_error(APLOG_MARK, APLOG_ERR, 0, s,
               "Cornea: DB connect error to %s: '%s'", dsn, PQerrorMessage(*dbh));
  return -1;
}

static apr_status_t
pg_conn_con(void **resource, void *params, apr_pool_t *pool) {
  PGconn *newdbh = NULL;
  if(ensure_pg_connection(NULL, &newdbh, (char *)params)) {
    return APR_ECONNREFUSED;
  }
  *resource = newdbh;
  return APR_SUCCESS;
}
static apr_status_t
pg_conn_des(void *resource, void *params, apr_pool_t *pool) {
  PQfinish((PGconn *)resource);
  return APR_SUCCESS;
}

static const char *
set_dsn_string(cmd_parms *parms, void *mconfig,
               int argc, const char **argv) {
  int i;
  cornea_router_config_t *s_cfg = ap_get_module_config(
    parms->server->module_config, &cornea_router_module);
  s_cfg->n_dsn = argc;
  s_cfg->dsn = apr_pcalloc(parms->server->process->pconf, sizeof(char *) * argc);
  for(i=0;i<argc;i++)
    s_cfg->dsn[i] = apr_pstrdup(parms->server->process->pconf, argv[i]);
  s_cfg->reslist = apr_pcalloc(parms->server->process->pconf, sizeof(*(s_cfg->reslist)) * argc);
  for(i=0;i<argc;i++) {
    apr_reslist_create(&s_cfg->reslist[i], s_cfg->min, s_cfg->smax, s_cfg->hmax, s_cfg->ttl,
                       pg_conn_con, pg_conn_des, s_cfg->dsn[i],
                       parms->server->process->pconf);
    apr_reslist_timeout_set(s_cfg->reslist[i], 2000000); /* 2 seconds */
  }
  return NULL;
}
static const char *
set_dosprotect_key(cmd_parms *parms, void *mconfig, const char *val) {
  cornea_router_config_t *s_cfg = ap_get_module_config(
    parms->server->module_config, &cornea_router_module);
  s_cfg->doskey = apr_pstrdup(parms->server->process->pconf, val);
  return NULL;
}
static const char *
set_params_string(cmd_parms *parms, void *mconfig,
                  int argc, const char **argv) {
  cornea_router_config_t *s_cfg = ap_get_module_config(
    parms->server->module_config, &cornea_router_module);
  if(argc != 4) return "CorneaPoolParams <min> <smax> <hmax> <ttl>";
  s_cfg->min = atoi(argv[0]);
  s_cfg->smax = atoi(argv[1]);
  s_cfg->hmax = atoi(argv[2]);
  s_cfg->ttl = atoi(argv[3]);
  if(s_cfg->min < 0) return "<min> cannot be less than 0";
  if(s_cfg->smax < s_cfg->min) "<smax> must be equal to or greater than <min>";
  if(s_cfg->hmax < s_cfg->smax) "<hmax> must be equal to or greater than <smax>";
  if(s_cfg->ttl < 0) return "<ttl> cannot be less than 0";
  return NULL;
}

static const command_rec cornea_router_cmds[] =
{
  AP_INIT_TAKE1( "CorneaDoSKey", set_dosprotect_key, NULL, RSRC_CONF, "Key for DoS prevention" ),
  AP_INIT_TAKE_ARGV( "CorneaDSN", set_dsn_string, NULL, RSRC_CONF, "DSNs for postgres." ),
  AP_INIT_TAKE_ARGV( "CorneaPoolParams", set_params_string, NULL, RSRC_CONF,
                      "Resource pool for postgres <min> <smax> <hmax> <ttl>." ),
  {NULL}
};

static int
hex_val(char cp) {
  if(cp >= '0' && cp <= '9') return cp - '0';
  if(cp >= 'a' && cp <= 'f') return cp - 'a' + 10;
  if(cp >= 'A' && cp <= 'F') return cp - 'A' + 10;
  return -1;
}
static int
cornea_translate(request_rec *r) {
  int ncnt, i, leading_zero;
  unsigned short ids[16];
  char *uri_copy, *cp, *ocp, *fpcp;
  char asset_tag[32];
  char assetid[24];
  unsigned char md5[APR_MD5_DIGESTSIZE];
  cornea_router_config_t *s_cfg = ap_get_module_config(
    r->server->module_config, &cornea_router_module);

  ap_log_error(APLOG_MARK, APLOG_DEBUG, 0, r->server, "Cornea: gonna go look for: %s", r->uri);
  uri_copy = apr_pstrdup(r->pool, r->uri+1);

  /* This should be an md5 / service / ( et / ass ) / rep */
  /* first the md5 hash */
  for(i=0; i<32; i++) {
    int half_byte_val;
    if((half_byte_val = hex_val(uri_copy[i])) == -1) return DECLINED;
    md5[i/2] = ((md5[i/2] & 0xf) << 4) | (half_byte_val & 0xf);
  }
  if(uri_copy[32] != '/') return DECLINED;

  cp = uri_copy + 33;
  /* asset tag has to fit in < 32 bytes */
  if(!(strlen(cp) < 32)) return DECLINED;
  /* next the service.. it is the first in the tag, so we read it right in */
  ocp = asset_tag;
  while(*cp >= '0' && *cp <= '9') *ocp++ = *cp++;
  *ocp++ = '-';
  /* next the asset, which is split and trickier */
  if(*cp++ != '/') return DECLINED;
  if(strlen(cp) < 7) return DECLINED;
  fpcp = cp + 4;
  /* 001/0/5
     ^   ^   
     |  fpcp
    cp
   */
  leading_zero = 1;
  if(*(fpcp-1) != '/') return DECLINED;
  while(*fpcp >= '0' && *fpcp <= '9') {
    if(leading_zero && *fpcp == '0') fpcp++;
    else { leading_zero = 0; *ocp++ = *fpcp++; }
  }
  if(*fpcp++ != '/') return DECLINED;
  for(i=0; i<3; i++) {
    if(cp[i] < '0' || cp[i] > '9') return DECLINED;
    if(!(leading_zero && cp[i] == '0')) {
      leading_zero = 0; *ocp++ = cp[i];
    }
  }
  cp = fpcp;
  *ocp++ = '-';
  /* representation is simple */
  while(*cp >= '0' && *cp <= '9')
    *ocp++ = *cp++;
  if(*cp) return DECLINED;
  *ocp = '\0';

  /* enforce DoS if specified */
  if(s_cfg->doskey) {
    unsigned char expected[APR_MD5_DIGESTSIZE];
    apr_md5_ctx_t ctx;
    apr_md5_init(&ctx);
    apr_md5_update(&ctx, s_cfg->doskey, strlen(s_cfg->doskey));
    apr_md5_update(&ctx, asset_tag, strlen(asset_tag));
    apr_md5_final(expected, &ctx);
    if(memcmp(md5, expected, APR_MD5_DIGESTSIZE)) {
      const char *referrer;
      referrer = apr_table_get(r->headers_in, "Referer");
      ap_log_error(APLOG_MARK, APLOG_NOTICE, 0, r->server, "Cornea: DoS %s from %s",
                   r->uri, referrer ? referrer : "-");
      return HTTP_FORBIDDEN;
    }
  }

  ncnt = fetch_storage_nodes(r->server, asset_tag, ids, 16);
  if(ncnt == 0) {
    ap_log_error(APLOG_MARK, APLOG_ERR, 0, r->server, "Cornea: no nodes found for %s", asset_tag);
    return HTTP_NOT_FOUND;
  }
  for(i=0; i<ncnt; i++) {
    ap_log_error(APLOG_MARK, APLOG_DEBUG, 0, r->server, "Cornea: lookin' at node %d: %s", ids[i], cornea_stores[ids[i]]->ip);
    if(cornea_stores[ids[i]] &&
       (!strcmp(cornea_stores[ids[i]]->state, "open") ||
        !strcmp(cornea_stores[ids[i]]->state, "closed"))) {
      r->uri = apr_psprintf(r->pool, "http://%s%s", cornea_stores[ids[i]]->ip, r->uri + 33);
      r->filename = apr_psprintf(r->pool, "proxy:%s", r->uri);
      r->handler = "proxy-server";
      r->proxyreq = 2;
      return OK;
    }
  }
  return HTTP_NOT_FOUND;
}

struct cs_free_list {
  cornea_store_t *trash;
  struct cs_free_list *next;
};
static void *
node_watcher(apr_thread_t *thread, void *data) {
  cornea_router_config_t *cfg = data;
  unsigned int i = 0;
  PGconn **handles;
  handles = calloc(cfg->n_dsn, sizeof(*handles));
  struct cs_free_list *active = NULL, *waiting = NULL;
  struct timeval now, last_free = { 0, 0 };
  while(1) {
    PGresult *res;
    int which = (i++) % cfg->n_dsn;
    if(ensure_pg_connection(NULL, &handles[which], cfg->dsn[which])) {
      sleep(1);
      continue;
    }
    res = PQexec(handles[which], "select * from get_storage_nodes(NULL)");
    if(!res) {
      ap_log_error(APLOG_MARK, APLOG_ERR, 0, NULL, "Cornea: PQexec failure");
      continue;
    }
    if(PQresultStatus(res) == PGRES_TUPLES_OK) {
      int nrows, ncols, i, j, acnt = 0;
      char **ips;
      nrows = PQntuples(res);
      ncols = PQnfields(res);

      /* This tracks nodes eligible for memcache */
      ips = calloc(nrows, sizeof(*ips));

      for (i=0; i<nrows; i++) {
        cornea_store_t tmp = { 0 };
        for (j=0; j<ncols; j++) {
          const char *fname = PQfname(res, j);
          const char *val = PQgetvalue(res, i, j);
          if(val == NULL) {
            continue; /* No null columns */
          }
#define COPY_SHORT_FIELD(a) if(!strcmp(fname, #a)) tmp.a = atoi(val)
#define COPY_INT64_FIELD(a) if(!strcmp(fname, #a)) tmp.a = apr_strtoi64(val, NULL, 10)
#define COPY_STR_FIELD(a) if(!strcmp(fname, #a)) strlcpy(tmp.a, val, sizeof(tmp.a))
          COPY_SHORT_FIELD(storage_node_id);
          else COPY_SHORT_FIELD(age);
          else COPY_STR_FIELD(ip);
          else COPY_STR_FIELD(fqdn);
          else COPY_STR_FIELD(state);
          else COPY_STR_FIELD(raw_state);
          else COPY_STR_FIELD(modified_at);
          else COPY_STR_FIELD(location);
          else COPY_INT64_FIELD(total_storage);
          else COPY_INT64_FIELD(used_storage);
        }
        if(tmp.storage_node_id) {
          cornea_store_t *ncs;

          ncs = malloc(sizeof(*ncs));
          memcpy(ncs, &tmp, sizeof(*ncs));

          if(strcmp(ncs->state, "decommissioned") && strcmp(ncs->state, "offline")) {
            ips[acnt++] = strdup(ncs->ip);
          }

          if(cornea_stores[tmp.storage_node_id]) {
            struct cs_free_list *lt;
            lt = malloc(sizeof(*lt));
            lt->next = active;
            lt->trash = cornea_stores[tmp.storage_node_id];
            active = lt;
          }
          cornea_stores[tmp.storage_node_id] = ncs;
        }
      }

      /* calculate the memcached vector */
      qsort(ips, acnt, sizeof(*ips), (int (*)(const void *,const void*))strcmp);
      configure_memcached(acnt, ips);
    }
    PQclear(res);


    /* we don't need to do this often */
    sleep(10);

    /* Cleanup the lock-free trash */
    gettimeofday(&now, NULL);
    if(now.tv_sec - last_free.tv_sec > 60) {
      while (waiting) {
        struct cs_free_list *tofree = waiting;
        waiting = waiting->next;
        free(tofree->trash);
        free(tofree);
      }
      waiting = active;
      active = NULL;
      memcpy(&last_free, &now, sizeof(now));
    }
  }
}

static void
cornea_child_init(apr_pool_t *p, server_rec *s) {
  apr_thread_t *thread;
  apr_threadattr_t *ta;
  cornea_router_config_t *s_cfg = ap_get_module_config(
    s->module_config, &cornea_router_module);
  ap_log_error(APLOG_MARK, APLOG_NOTICE, 0, s,
               "Cornea: initializing storage poller for process %d", getpid());
  apr_thread_mutex_create(&memcached_mutex, 0, s->process->pool);
  apr_thread_mutex_create(&memcached_pool_mutex, 0, s->process->pool);
  apr_threadattr_create(&ta, s->process->pool);
  apr_threadattr_detach_set(ta, 1);
  apr_thread_create(&thread, ta, node_watcher, s_cfg, s->process->pool);
}

static void
cornea_router_register(void) {
  static const char * const aszPre[]={ "http_core.c",NULL };
  ap_hook_translate_name(cornea_translate,aszPre,NULL,APR_HOOK_FIRST);
  ap_hook_child_init(cornea_child_init,aszPre,NULL,APR_HOOK_FIRST);
}

module cornea_router_module = {
  STANDARD20_MODULE_STUFF,
  NULL,
  NULL,
  make_cornea_router_server_config,
  merge_cornea_router_server_config,
  cornea_router_cmds,
  cornea_router_register
};

