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
  $self->__connect;
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
 again:
  eval {
    $snl = Cornea::StorageNodeList->new();
    my $sth = $self->{dbh}->prepare("select * from get_storage_nodes_by_state(?)");
    $sth->execute($type);
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

1;
