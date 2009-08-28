package Cornea::RecallTable;
use strict;
use Cornea::Config;
use Cornea::Utils;
use DBI;

sub __connect {
  my $self = shift;
  my $config = Cornea::Config->new();
  my $dbh;
  my $failed_err = undef;
  my $dsns = $config->get_list("DB::dsn");
  Cornea::Utils::shuffle($dsns);
  foreach my $dsn (@$dsns) {
    eval {
      $dbh = DBI->connect($dsn,
                          $config->get("DB::user"),
                          $config->get("DB::pass"),
                          { PrintError => 0, RaiseError => 1 },
                         );
    };
    die "$dsn: $@\n" if $@;
    last unless $@;
  }
  print STDERR "$failed_err\n" if $failed_err;
  $self->{dbh} = $dbh;
}
sub __reconnect {
  my $self = shift;
  $self->{dbh} = undef;
  $self->__connect();
}
sub new {
  my $class = shift;
  my $self = bless { }, $class;
  $self;
}

sub insert {
  my $self = shift;
  my ($serviceId, $assetId, $repId, $snl) = @_;
  my $tried = 0;
  die 'bad parameters' unless UNIVERSAL::ISA($snl, 'Cornea::StorageNodeList');
  my $snl_arr = '{' . join(',', map { $_->storeagenodeid() }
                                    ($snl->items())) . '}'; 
 again:
  eval {
    my $sth = $self->{dbh}->prepare("select make_asset(?,?,?,?::int[])");
    $sth->execute($serviceId, $assetId, $repId, $snl_arr);
    $sth->finish();
  };
  if ($@) {
    unless ($tried++) { $self->__reconnect();  goto again; }
    die $@ if $@;
  }
  return 1;
}

sub find {
  my $self = shift;
  my ($serviceId, $assetId, $repId) = @_;
  my $sth = $self->{dbh}->prepare("select get_asset_location(?,?,?)");
  my $tried = 0;
  my $C;
 again:
  eval {
    $C = Cornea::StorageNodeList->new();
    $sth->execute($serviceId, $assetId, $repId);
    while(my $node = $sth->fetchrow_hashref()) {
      $C->add(Cornea::StorageNode->new_from_row($node));
    }
    $sth->finish();
  };
  if ($@) {
    unless ($tried++) { $self->__reconnect();  goto again; }
    die $@ if $@;
  }
  return $C;
}

sub getNodes {
  my $self = shift;
  my $type = shift;
  my $tried = 0;
  my $snl;
  my $bind = undef;
  if (defined($type)) {
    $bind = (ref $type eq 'ARRAY') ? ('{'.join(',', @$type).'}') : "{$type}";
  }
 again:
  eval {
    $snl = Cornea::StorageNodeList->new();
    my $sth = $self->{dbh}->prepare("select * from get_storage_nodes(?::storagestate[])");
    $sth->execute($bind);
    while(my $row = $sth->fetchrow_hashref()) {
      $snl->add(Cornea::StorageNode->new_from_row($row));
    }
    $sth->finish();
  };
  if ($@) {
    unless ($tried++) { $self->__reconnect();  goto again; }
    die $@ if $@;
  }
  return $snl;
}

sub _2pc_generic {
  my $self = shift;
  my $code = shift;
  my $config = Cornea::Config->new();
  my $dsns = $config->get_list("DB::dsn");
  my $rv = undef;
  my $named_txn = "cornea_$$";
  my @dbh = map {
    my $dbh = DBI->connect($_,
                 $config->get("DB::user"),
                 $config->get("DB::pass"),
                 { PrintError => 0, RaiseError => 1, AutoCommit => 1 }
                );
    $dbh->begin_work();
    [$_, $dbh];
  } @$dsns;
  eval {
    foreach (@dbh) {
      &$code($_->[0], $_->[1], \$rv);
    }
    foreach (@dbh) { $_->[1]->do("prepare transaction '$named_txn'"); }
    foreach (@dbh) { $_->[1]->do("commit prepared '$named_txn'"); }
  };
  if ($@) {
    my $real_error = $@;
    $rv = undef;
    eval { foreach (@dbh) { $_->[1]->do("rollback prepared 'cornea_node'"); } };
    die $real_error;
  }
  foreach (@dbh) { $_->[1]->disconnect; }
  return $rv;
}
      
sub _2pc_add_storage {
  my $ip = shift;
  my $attr = shift;
  my $storage_node_id;
  my $config = Cornea::Config->new();
  my $dsns = $config->get_list("DB::dsn");
  my @dbh = map {
    my $dbh = DBI->connect($_,
                 $config->get("DB::user"),
                 $config->get("DB::pass"),
                 { PrintError => 0, RaiseError => 1, AutoCommit => 1 }
                );
    $dbh->begin_work();
    $dbh;
  } @$dsns;
  eval {
    foreach (@dbh) {
      eval {
        my $sth = $_->prepare("select set_storage_node(?,?,?,?,?,?,?)");
        $sth->execute($attr->{state},
                      $attr->{total_storage}, $attr->{used_storage},
                      $attr->{location}, $attr->{fqdn}, $ip, $storage_node_id);
        my ($returned_storade_node_id) = $sth->fetchrow();
        $storage_node_id ||= $returned_storade_node_id;
        $sth->finish();
        die "Storage node trickery! (this should never happen).\n"
          if($storage_node_id != $returned_storade_node_id);
      };
      if ($@) {
        die "location must be specified for first-time update\n"
          if $@ =~ /null value in column "location"/;
        die $@ if $@;
      }
    }
    foreach (@dbh) { $_->do("prepare transaction 'cornea_node'"); }
    foreach (@dbh) { $_->do("commit prepared 'cornea_node'"); }
  };
  if ($@) {
    my $real_error = $@;
    $storage_node_id = undef;
    eval { foreach (@dbh) { $_->do("rollback prepared 'cornea_node'"); } };
    die $real_error;
  }
  foreach (@dbh) { $_->disconnect; }
  die $@ unless($storage_node_id);
  return $storage_node_id;
}
sub updateNode {
  my $self = shift;
  my $ip = shift;
  my $attr = shift;
  my $config = Cornea::Config->new();
  die "bad state"
    unless $attr->{state} =~ /^(?:open|closed|offline|decommissioned)$/;
  die "storage must be a number"
    unless $attr->{total_storage} =~ /^[1-9]\d*$/ and
           $attr->{used_storage} =~ /^[1-9]\d*$/;
  die "locaion must be dc/cage/row/rack/pdu"
    unless !defined($attr->{location}) or
           $attr->{location} =~ /^[^\/]+(?:\/[^\/]+){4}$/;
  die "fqdn must not be blank"
    unless !defined($attr->{fqdn}) or length($attr->{fqdn});

  if(defined($attr->{location}) || defined($attr->{fqdn})) {
    return return _2pc_add_storage($ip, $attr);
  }
  my $dsns = $config->get_list("DB::dsn");
  foreach (@$dsns) {
    my $dbh = DBI->connect($_,
                 $config->get("DB::user"),
                 $config->get("DB::pass"),
                 { PrintError => 0, RaiseError => 1, AutoCommit => 1 }
                );
    my $tried = 0;
   again:
    eval {
      my $sth = $self->{dbh}->prepare("select set_storage_node(?,?,?,?,?,?,?)");
      $sth->execute($attr->{state},
                    $attr->{total_storage}, $attr->{used_storage},
                    $attr->{location}, $attr->{fqdn}, $ip, undef);
      $sth->finish();
    };
    if ($@) {
      unless ($tried++) { $self->__reconnect();  goto again; }
      print STDERR $@;
    }
  }
  return 0;
}

sub repInfo {
  my $self = shift;
  my ($serviceId, $repId) = @_;
  my $tried = 0;
  my $row;
 again:
  eval {
    my $sth = $self->{dbh}->prepare("select * from get_representation(?,?)");
    $sth->execute($serviceId, $repId);
    $row = $sth->fetchrow_hashref();
    $sth->finish();
  };
  if ($@) {
    unless ($tried++) { $self->__reconnect();  goto again; }
    die $@ if $@;
  }
  return Cornea::RepresentationInfo->new_from_row($row);
}

sub repInfoDependents {
  my $self = shift;
  my ($serviceId, $repId) = @_;
  my $tried = 0;
  my @deps;
 again:
  eval {
    @deps = ();
    my $sth = $self->{dbh}->prepare("select * from get_representation_dependents(?,?)");
    $sth->execute($serviceId, $repId);
    while(my $row = $sth->fetchrow_hashref()) {
      push @deps, Cornea::RepresentationInfo->new_from_row($row);
    }
    $sth->finish();
  };
  if ($@) {
    unless ($tried++) { $self->__reconnect();  goto again; }
    die $@ if $@;
  }
  return @deps;
}

sub initAssetTable {
  my $self = shift;
  my $config = Cornea::Config->new();
  my $host = $config->get('sysinfo::nodename');
  (my $tbl = $host) =~ s/\-/_/g;
  $tbl =~ s/\..*//;
  my $dbh = DBI->connect("dbi:Pg:host=localhost;dbname=cornea",
                         $config->get("DB::user"),
                         $config->get("DB::pass"),
                         { PrintError => 0, RaiseError => 1, AutoCommit => 1 },
                        );
  $dbh->do("set client_min_messages = 'WARNING'");
  $dbh->begin_work();
  eval {
    $dbh->do("CREATE TABLE cornea.asset_$tbl
                    (CONSTRAINT asset_${tbl}_pkey
                        PRIMARY KEY (service_id, asset_id, representation_id))
                     INHERITS (cornea.asset)");
    $dbh->do("CREATE OR REPLACE FUNCTION cornea.make_asset(in_service_id integer, in_asset_id bigint, in_repid integer, in_storage_location smallint[]) RETURNS void AS 'delete from asset where service_id = \$1 and asset_id = \$2 and representation_id = \$3; insert into asset_${tbl} (service_id, asset_id, representation_id, storage_location) VALUES (\$1, \$2, \$3, \$4);' LANGUAGE sql");
    $dbh->commit();
  };
  if($@) {
    my $err = $@;
    eval { $dbh->rollback; };
    return (-1, "already initialized") if $err =~ /already exists/;
    return (-1, $err);
  }
  return 0;
}

sub setupAssetQueue {
  my $self = shift;
  my $config = Cornea::Config->new();
  my $host = shift;
  gethostbyname($host) || die "could not resolve $host\n";;
  (my $tbl = $host) =~ s/\-/_/g;
  $tbl =~ s/\..*//;
  my $phost = $config->get('sysinfo::nodename');
  (my $ptbl = $phost) =~ s/\-/_/g;
  $ptbl =~ s/\..*//;
  my $dbh = DBI->connect("dbi:Pg:host=localhost;dbname=cornea",
                         $config->get("DB::user"),
                         $config->get("DB::pass"),
                         { PrintError => 0, RaiseError => 1, AutoCommit => 1 },
                        );
  $dbh->do("set client_min_messages = 'WARNING'");
  $dbh->begin_work();
  eval {
    $dbh->do("CREATE TABLE cornea.asset_$tbl
                    (CONSTRAINT asset_${tbl}_uc
                        PRIMARY KEY (service_id, asset_id, representation_id))
                     INHERITS (cornea.asset)");
    $dbh->do("CREATE TABLE cornea.asset_${tbl}_queue
                     (LIKE cornea.asset
                      EXCLUDING CONSTRAINTS
                      EXCLUDING INDEXES)");
    $dbh->do(<<SQL);
CREATE FUNCTION cornea.populate_asset_${tbl}_queue() RETURNS TRIGGER
  AS '
DECLARE
BEGIN
  INSERT INTO cornea.asset_${tbl}_queue
              (asset_id, service_id, representation_id, storage_location)
       VALUES (NEW.asset_id, NEW.service_id, NEW.representation_id,
               NEW.storage_location);
  RETURN NEW;
END
' LANGUAGE plpgsql
SQL
    $dbh->do("CREATE TRIGGER asset_${tbl}_queue_trigger
                AFTER INSERT OR UPDATE ON cornea.asset_${ptbl}
                FOR EACH ROW
                EXECUTE PROCEDURE cornea.populate_asset_${tbl}_queue()");
    $dbh->commit();
  };
  if($@) {
    my $err = $@;
    eval { $dbh->rollback; };
    return (-1, "init-metanode first")
      if $err =~ /"cornea.asset_$ptbl" does not exist/;
    return (-1, "already initialized") if $err =~ /already exists/;
    die $err;
  }
  return 0;
}

sub destroyAssetQueue {
  my $self = shift;
  my $config = Cornea::Config->new();
  my $host = shift;
  gethostbyname($host) || die "could not resolve $host\n";;
  (my $tbl = $host) =~ s/\-/_/g;
  $tbl =~ s/\..*//;
  my $phost = $config->get('sysinfo::nodename');
  (my $ptbl = $phost) =~ s/\-/_/g;
  $ptbl =~ s/\..*//;
  my $dbh = DBI->connect("dbi:Pg:host=localhost;dbname=cornea",
                         $config->get("DB::user"),
                         $config->get("DB::pass"),
                         { PrintError => 0, RaiseError => 1, AutoCommit => 1 },
                        );
  $dbh->begin_work();
  eval {
    $dbh->do("DROP TRIGGER asset_${tbl}_queue_trigger ON cornea.asset_${ptbl}");
    $dbh->do("DROP FUNCTION cornea.populate_asset_${tbl}_queue()");
    $dbh->do("DROP TABLE cornea.asset_${tbl}_queue");
    $dbh->do("DROP TABLE cornea.asset_$tbl");
    $dbh->commit();
  };
  if($@) {
    my $err = $@;
    eval { $dbh->rollback; };
    return (-1, "already perfomed") if $err =~ /does not exist/;
    return (-1, $err);
  }
  return 0;
}

sub initialAssetSynch {
  my $self = shift;
  my $config = Cornea::Config->new();
  my $host = shift;
  gethostbyname($host) || die "could not resolve $host\n";;
  (my $tbl = $host) =~ s/\-/_/g;
  $tbl =~ s/\..*//;
  my $phost = $config->get('sysinfo::nodename');
  (my $ptbl = $phost) =~ s/\-/_/g;
  $ptbl =~ s/\..*//;
  my $total_rows = 0;
  my $dbh = DBI->connect("dbi:Pg:host=$host;dbname=cornea",
                         $config->get("DB::user"),
                         $config->get("DB::pass"),
                         { PrintError => 0, RaiseError => 1, AutoCommit => 1 },
                        );
  my $ldbh = DBI->connect("dbi:Pg:host=localhost;dbname=cornea",
                         $config->get("DB::user"),
                         $config->get("DB::pass"),
                         { PrintError => 0, RaiseError => 1, AutoCommit => 1 },
                        );
  $dbh->begin_work();
  $ldbh->begin_work();
  my $problem;
  eval {
    $problem = "peer not locally initialized";
    my $isth = $ldbh->prepare(
        "INSERT INTO cornea.asset_${tbl}
                    (asset_id, service_id,
                     representation_id, storage_location)
              VALUES (?,?,?,?::smallint[])");
    $problem = "remote not initialized";
    $dbh->do("DECLARE initpull CURSOR FOR
               SELECT asset_id, service_id,
                      representation_id, storage_location
                 FROM cornea.asset_${tbl}");
    $problem = "remote peer not initialized";
    $dbh->do("TRUNCATE cornea.asset_${ptbl}_queue");
    $problem = "error pulling remote data";
    my $sth = $dbh->prepare("FETCH FORWARD 10000 FROM initpull");
    my $internal_rows_moved;
    do {
      $internal_rows_moved = 0;
      $sth->execute();
      while(my @row = $sth->fetchrow()) {
        $problem = "error insert local data";
        $isth->execute(@row);
        $internal_rows_moved++;
        $problem = "error pulling remote data";
      }
      $total_rows += $internal_rows_moved;
    } while($internal_rows_moved);
    $dbh->do("CLOSE initpull");
    $dbh->commit();
    $ldbh->commit();
  };
  if($@) {
    my $err = $@;
    eval { $ldbh->rollback; };
    eval { $dbh->rollback; };
    return (-1, "$problem:\n$err");
  }
  return (0, "$total_rows copied");
}
sub pullAssetTable {
  my $self = shift;
  my $config = Cornea::Config->new();
  my $host = shift;
  my $timeout = shift || 1;
  gethostbyname($host) || die "could not resolve $host\n";;
  (my $tbl = $host) =~ s/\-/_/g;
  $tbl =~ s/\..*//;
  my $phost = $config->get('sysinfo::nodename');
  (my $ptbl = $phost) =~ s/\-/_/g;
  $ptbl =~ s/\..*//;
  my $total_rows = 0;
  my $dbh = DBI->connect("dbi:Pg:host=$host;dbname=cornea",
                         $config->get("DB::user"),
                         $config->get("DB::pass"),
                         { PrintError => 0, RaiseError => 1, AutoCommit => 1 },
                        );
  my $ldbh = DBI->connect("dbi:Pg:host=localhost;dbname=cornea",
                         $config->get("DB::user"),
                         $config->get("DB::pass"),
                         { PrintError => 0, RaiseError => 1, AutoCommit => 1 },
                        );
  while(1) {
    $dbh->begin_work();
    $ldbh->begin_work();
    eval {
      my $from = $dbh->prepare("DELETE FROM cornea.asset_${ptbl}_queue RETURNING *");
      my $todel = $ldbh->prepare("DELETE FROM cornea.asset
                 WHERE asset_id = ? and service_id = ? and representation_id = ?");
      my $toins = $ldbh->prepare(
          "INSERT INTO cornea.asset_${tbl}
                      (asset_id, service_id,
                       representation_id, storage_location)
                VALUES (?,?,?,?::smallint[])");
      $from->execute();
      while(my @row = $from->fetchrow()) {
        $todel->execute(@row[0..2]);
        $toins->execute(@row);
        $total_rows++;
      }
      $ldbh->commit;
      $dbh->commit;
    };
    if($@) {
      my $err = $@;
      eval { $ldbh->rollback; };
      eval { $dbh->rollback; };
      return (-1, "$total_rows compied.\n$err");
    }
    sleep($timeout);
  }
  return (0, "$total_rows copied");
}

sub listAssetTables {
  my $self = shift;
  $self->_2pc_generic(sub {
    my $dsn = shift;
    my $dbh = shift;
    my $rv = shift;
    $$rv ||= {};
    my $sth = $dbh->prepare(<<SQL);

    select relname, (case when pg_trigger.oid is null
                          then 'remote'
                          else 'master' end) as partition_type
      from pg_class
      join (select inhrelid
              from pg_inherits
             where inhparent in (select oid
                                   from pg_class
                                  where relname='asset'
                                    and relnamespace in (select oid
                                                           from pg_namespace
                                                          where nspname = 'cornea'))) as c
        on (pg_class.oid = inhrelid)
 left join pg_trigger
        on (c.inhrelid = pg_trigger.tgrelid)

SQL
    $sth->execute();
    my $master;
    my $slaves = {};
    while(my @row = $sth->fetchrow()) {
      if ($row[1] eq 'master') {
        $master = $row[0];
      }
      else {
        my $qsize = $dbh->prepare("select count(*)
                                    from cornea.$row[0]_queue");
        $qsize->execute();
        my ($qsize_result) = $qsize->fetchrow();
        $qsize->finish;
        $slaves->{$row[0]} = "$qsize_result rows behind";
      }
    }
    ${$rv}->{$dsn} = { master => $master, slaves => $slaves };
  });
}
1;
