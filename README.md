# cornea
Large-scale, distributed HTTP-based asset storage system.

## Setup Instructions ##

### Perl ###

  * YAML
  * Net::Stomp
  * DBI
  * DBD::Pg
  * WWW::Curl::Easy
  * Memcached::libmemcached

  Checkout the source and setup an `/etc/cornea.conf` file.

### PostgreSQL ###

  Note that postgres 8.4 ships with named transactions disabled.  We use that for a little bit of two-phase commit action across the database cluster.  The 2PC stuff isn't in the critical performance path -- it is just for administrative functions (adding new storage nodes and adding new asset representations).  You'll need to allow a few of those, so add the following to your postgresql.conf:

  ```
  max_prepared_transactions = 5
  ```

  Setting up a few dedicated nodes... db1 and db2.

  ```
  db1# createdb cornea && createuser cornea && createlang cornea plpgsql && psql cornea cornea < cornea.sql
  db2# createdb cornea && createuser cornea && createlang cornea plpgsql && psql cornea cornea < cornea.sql
  db1# corneactl init-metanode
  db1# corneactl init-peer-metanode db2
  db2# corneactl init-metanode
  db2# corneactl init-peer-metanode db1
  db1# corneactl first-sync-peer-metanode db2
  db2# corneactl first-sync-peer-metanode db1
  db1# cd /cornea/etc/smf && mk-mirror-smf.sh db2
  db1# svccfg import /cornea/etc/smf/cornea-mirror-db2.xml
  db1# svcadm enable mirror-db2
  db2# cd /cornea/etc/smf && mk-mirror-smf.sh db1
  db2# svccfg import /cornea/etc/smf/cornea-mirror-db1.xml
  db2# svcadm enable mirror-db1
  ```


### RabbitMQ (with stomp) ###

   `/etc/rabbitmq/rabbitmq.conf` (the keys must match):
   ```
SERVER_START_ARGS='
      -setcookie MAKEUPALONGSTRINGHERE
      -rabbit
         stomp_listeners [{"0.0.0.0",61613}]
         extra_startup_steps [{"STOMP-listeners",rabbit_stomp,kickstart,[]}]'

CTL_ERL_ARGS="-setcookie MAKEUPALONGSTRINGHERE"
   ```

 ```
 # rabbitmqctl add_user cornea cornea
 # rabbitmqctl delete_user guest
 # rabbitmqctl set_permissions cornea "^cornea.*" ".*" ".*"
 ```
 
 ## See Also ##
 
  * [Architecture](docs/cornea-arch.png)
  * [Deployment](docs/cornea-deploy.png) 
  
  
