package Cornea::StorageNode;
use strict;

=pod

=item location()

Described as DataCenter/Cage/Row/Rack/PDU

=item distance()

Distance between two nodes w.r.t. their location.

=cut

sub location() {
}

sub distance() {
  my $self = shift;
  my $other = shift;
  my @a = split /\//, $self->location();
  my @b = split /\//, $other->location();

  my $dist = 0;
  while(defined(my $a_v = shift @a) || defined(my $b_v = shift @b)) {
    $dist <<= 1;
    $dist |= 1 if($a_v != $b_v);
  }
  return $dist;
}

sub put {
  my $self = shift;
  my $source = shift;
  my ($serviceId,$assetId,$repId) = @_;

  if(ref $source eq 'Cornea::StorageNode' or
     ref $source eq 'Cornea::StorageNodeList') {
    # This is a storage node(list) from which to copy.
  }
  else {
    # This is an actual asset
  }
}

sub delete {
  my $self = shift;
  my ($serviceId,$assetId,$repId) = @_;
}

sub fetch {
  my $self = shift;
  my ($serviceId,$assetId,$repId) = @_;
}

1;
