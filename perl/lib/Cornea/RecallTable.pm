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
 again:
  eval {
    my $sth = $self->{dbh}->prepare("select storeAsset(?,?,?,?)");
    $sth->execute($serviceId, $assetId, $repId, $snl);
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
  my $sth = $self->{dbh}->prepare("select findAsset(?,?,?)");
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
    my $sth = $self->{dbh}->prepare("select * from getCorneaNodes(?)");
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

sub updateNode {
  my $self = shift;
  my $fqdn = shift;
  my $attr = shift;
  die "bad state"
    unless $attr->{state} =~ /^(?:open|closed|offline|decommissioned)$/;
  die "storage must be a number"
    unless $attr->{total_storage} =~ /^[1-9]\d*$/ and
           $attr->{used_storage} =~ /^[1-9]\d*$/;
  die "locaion must be dc/cage/row/rack/pdu"
    unless !defined($attr->{location}) or
           $attr->{location} =~ /^[^\/]+(?:\/[^\/]+){4}$/;

  my $tried = 0;
 again:
  eval {
    my $sth = $self->{dbh}->prepare("select storeCorneaNode(?,?,?,?,?)");
    $sth->execute($attr->{state},
                  $attr->{total_storage}, $attr->{used_storage},
                  $attr->{location}, $fqdn);
    $sth->finish();
  };
  if ($@) {
    die "location must be specified for first-time update\n"
      if $@ =~ /null value in column "location"/;
    unless ($tried++) { $self->__reconnect();  goto again; }
    die $@ if $@;
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
    my $sth = $self->{dbh}->prepare("select * from getRepInfo(?,?)");
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
    my $sth = $self->{dbh}->prepare("select * from getRepInfoDependents(?,?)");
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
