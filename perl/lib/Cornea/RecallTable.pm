package Cornea::RecallTable;
use strict;
use Cornea::Config;
use DBI;

sub new {
  my $class = shift;
  $class = ref($class) ? ref $class : $class;

  my $config = Cornea::Config->new();
  my $dbh = DBI->connect($config->dsn(),
                         $config->dbuser(),
                         $config->dbpass(),
                         { PrintError => 0, RaiseError => 1 },
                        );

  bless {}, $class;
}

sub insert {
  my $self = shift;
  my ($serviceId, $assetId, $repId, $snl) = @_;
  die 'bad parameters' unless UNIVERSAL::ISA($snl, 'Cornea::StorageNodeList');
  my $sth = $self->{dbh}->prepare("select storeAsset(?,?,?,?)");
  $sth->execute($serviceId, $assetId, $repId, $snl);
  $sth->finish();
}

sub getOpenNodes {
  my $self = shift;
  my $snl = Cornea::StorageNodeList->new();
  my $sth = $self->{dbh}->prepare("select * from getOpenNodes()");
  $sth->execute();
  while(my $row = $sth->fetchrow_hashref()) {
    $snl->add(Cornea::StorageNode->new_from_row($row));
  }
  $sth->finish();
  return $snl;
}

sub repInfo {
  my $self = shift;
  my ($serviceId, $repId) = @_;
  my $sth = $self->{dbh}->prepare("select * from getRepInfo(?,?)");
  $sth->execute($serviceId, $repId);
  my $row = $sth->fetchrow_hashref();
  $sth->finish();
  return Cornea::RepresentationInfo->new_from_row($row);
}

sub repInfoDependents {
  my $self = shift;
  my ($serviceId, $repId) = @_;
  my @deps;

  my $sth = $self->{dbh}->prepare("select * from getRepInfoDependents(?,?)");
  $sth->execute($serviceId, $repId);
  while(my $row = $sth->fetchrow_hashref()) {
    push @deps, Cornea::RepresentationInfo->new_from_row($row);
  }
  $sth->finish();
  return @deps;
}

1;
