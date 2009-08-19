package Cornea::RecallTable;
use strict;
use Cornea::Config;
use Cornea::Utils;
use DBI;

sub __connect {
  my $self = shift;
  my $config = Cornea::Config->new();
  my $dbh;
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
    last unless ($@);
  }
  $self->{dbh} = shift;
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
    unless ($tried++) { $self->{dbh}->__reconnect();  goto again; }
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
    unless ($tried++) { $self->{dbh}->__reconnect();  goto again; }
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
    unless ($tried++) { $self->{dbh}->__reconnect();  goto again; }
    die $@ if $@;
  }
  return $snl;
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
    unless ($tried++) { $self->{dbh}->__reconnect();  goto again; }
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
    unless ($tried++) { $self->{dbh}->__reconnect();  goto again; }
    die $@ if $@;
  }
  return @deps;
}

1;
